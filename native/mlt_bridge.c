/* native/mlt_bridge.c */

#include "mlt_bridge.h"

#include <flutter_linux/flutter_linux.h>
#include <epoxy/gl.h>
#include <framework/mlt.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * Deinterlacer used for interlaced sources.
 *
 * This is now applied on MLT's render threads rather than on the
 * consumer's timing thread, so a higher quality method than
 * "onefield" is affordable. Valid values include:
 *
 *   onefield, linearblend, weave, bob, greedy,
 *   yadif-nospatial, yadif, bwdif, estdif
 */
#define MLT_BRIDGE_DEINTERLACER "onefield"

/*
 * Number of buffers in the video frame rotation.
 *
 * Three is the minimum that lets the producing thread and the
 * consuming thread each own a buffer outright while a third
 * waits in the middle.
 */
#define MLT_BRIDGE_SLOT_COUNT 3

/* ------------------------------------------------------------------------- */
/* Engine state                                                              */
/* ------------------------------------------------------------------------- */

/*
 * engine_mutex guards every field in this block, and every call
 * into MLT that mutates the producer or the consumer.
 *
 * The frame callback never takes this lock. It runs on MLT's own
 * thread while transport calls run on a Dart thread, and taking
 * both locks in the two directions would be a deadlock waiting to
 * happen. Everything the callback needs is published as an atomic
 * instead (see target_width / target_height).
 */
static GMutex engine_mutex;

static mlt_repository repository = NULL;
static mlt_profile profile = NULL;
static mlt_producer producer = NULL;
static mlt_consumer consumer = NULL;

static int has_video = 0;
static int has_audio = 0;
static int is_still = 0;

static double requested_volume = 1.0;

static char last_error[512] = "";

/* Published for the frame callback without taking engine_mutex. */
static gint target_width = 0;
static gint target_height = 0;

/* ------------------------------------------------------------------------- */
/* Video frame state                                                         */
/* ------------------------------------------------------------------------- */

typedef struct _FrameSlot {
    uint8_t *data;
    size_t capacity;
    int width;
    int height;
} FrameSlot;

/*
 * frame_mutex guards the slot indices below, and nothing else.
 *
 * Each of the three slots is owned outright by exactly one party at
 * any moment: the MLT frame callback owns slot_write, the Flutter
 * raster thread owns slot_display, and slot_ready is the handoff
 * point. Because ownership is exclusive, the expensive work (the
 * copy out of MLT, and the upload into OpenGL) happens with no lock
 * held. Only the index swap is contended.
 */
static GMutex frame_mutex;

static FrameSlot slots[MLT_BRIDGE_SLOT_COUNT];

static int slot_write = 0;
static int slot_ready = 1;
static int slot_display = 2;

static int slot_ready_valid = 0;

static int64_t last_frame_position = -1;

/* ------------------------------------------------------------------------- */
/* Flutter texture state                                                     */
/* ------------------------------------------------------------------------- */

/*
 * texture_mutex guards the registrar and texture pointers, which are
 * written from the platform thread during registration and read from
 * the MLT thread on every frame.
 */
static GMutex texture_mutex;

static FlTextureRegistrar *texture_registrar = NULL;

static gint frame_notification_pending = 0;

typedef struct _MltVideoTexture {
    FlTextureGL parent_instance;

    GLuint gl_texture_id;

    int uploaded_width;
    int uploaded_height;
} MltVideoTexture;

typedef struct _MltVideoTextureClass {
    FlTextureGLClass parent_class;
} MltVideoTextureClass;

static MltVideoTexture *video_texture = NULL;

G_DEFINE_TYPE(
    MltVideoTexture,
    mlt_video_texture,
    fl_texture_gl_get_type()
)

/* ------------------------------------------------------------------------- */
/* One-time initialization                                                   */
/* ------------------------------------------------------------------------- */

static gsize locks_initialized = 0;

static void ensure_locks(void)
{
    if (g_once_init_enter(&locks_initialized)) {
        g_mutex_init(&engine_mutex);
        g_mutex_init(&frame_mutex);
        g_mutex_init(&texture_mutex);

        g_once_init_leave(&locks_initialized, 1);
    }
}

/* ------------------------------------------------------------------------- */
/* Errors                                                                    */
/* ------------------------------------------------------------------------- */

/* Call with engine_mutex held. */
static void set_error(
    const char *message)
{
    if (message == NULL) {
        last_error[0] = '\0';
        return;
    }

    snprintf(
        last_error,
        sizeof(last_error),
        "%s",
        message
    );
}

/* ------------------------------------------------------------------------- */
/* Frame slots                                                               */
/* ------------------------------------------------------------------------- */

static void release_slots(void)
{
    ensure_locks();

    g_mutex_lock(&frame_mutex);

    for (int index = 0;
         index < MLT_BRIDGE_SLOT_COUNT;
         index++) {
        free(slots[index].data);

        slots[index].data = NULL;
        slots[index].capacity = 0;
        slots[index].width = 0;
        slots[index].height = 0;
    }

    slot_write = 0;
    slot_ready = 1;
    slot_display = 2;

    slot_ready_valid = 0;

    last_frame_position = -1;

    g_mutex_unlock(&frame_mutex);
}

/*
 * Marks every buffered frame stale without freeing the allocations,
 * so that a seek or a pause forces the next decoded frame to be
 * uploaded even if it carries a position we have already seen.
 */
static void invalidate_frames(void)
{
    ensure_locks();

    g_mutex_lock(&frame_mutex);

    last_frame_position = -1;

    g_mutex_unlock(&frame_mutex);
}

/* ------------------------------------------------------------------------- */
/* Flutter texture implementation                                            */
/* ------------------------------------------------------------------------- */

static gboolean mlt_video_texture_populate(
    FlTextureGL *texture,
    uint32_t *target,
    uint32_t *name,
    uint32_t *width,
    uint32_t *height,
    GError **error)
{
    (void)error;

    MltVideoTexture *self =
        (MltVideoTexture *)texture;

    ensure_locks();

    /*
     * Claim the newest completed frame. The swap is the only part
     * that needs the lock: after it returns, slot_display belongs
     * to this thread alone until the next call.
     */
    g_mutex_lock(&frame_mutex);

    if (slot_ready_valid) {
        const int previous_display =
            slot_display;

        slot_display = slot_ready;
        slot_ready = previous_display;

        slot_ready_valid = 0;
    }

    const int display_index =
        slot_display;

    g_mutex_unlock(&frame_mutex);

    FrameSlot *slot =
        &slots[display_index];

    if (slot->data == NULL ||
        slot->width <= 0 ||
        slot->height <= 0) {
        return FALSE;
    }

    if (self->gl_texture_id == 0) {
        glGenTextures(
            1,
            &self->gl_texture_id
        );

        glBindTexture(
            GL_TEXTURE_2D,
            self->gl_texture_id
        );

        glTexParameteri(
            GL_TEXTURE_2D,
            GL_TEXTURE_MIN_FILTER,
            GL_LINEAR
        );

        glTexParameteri(
            GL_TEXTURE_2D,
            GL_TEXTURE_MAG_FILTER,
            GL_LINEAR
        );

        glTexParameteri(
            GL_TEXTURE_2D,
            GL_TEXTURE_WRAP_S,
            GL_CLAMP_TO_EDGE
        );

        glTexParameteri(
            GL_TEXTURE_2D,
            GL_TEXTURE_WRAP_T,
            GL_CLAMP_TO_EDGE
        );
    } else {
        glBindTexture(
            GL_TEXTURE_2D,
            self->gl_texture_id
        );
    }

    glPixelStorei(
        GL_UNPACK_ALIGNMENT,
        1
    );

    if (self->uploaded_width != slot->width ||
        self->uploaded_height != slot->height) {
        glTexImage2D(
            GL_TEXTURE_2D,
            0,
            GL_RGBA8,
            slot->width,
            slot->height,
            0,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            slot->data
        );

        self->uploaded_width =
            slot->width;

        self->uploaded_height =
            slot->height;
    } else {
        glTexSubImage2D(
            GL_TEXTURE_2D,
            0,
            0,
            0,
            slot->width,
            slot->height,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            slot->data
        );
    }

    *target = GL_TEXTURE_2D;
    *name = self->gl_texture_id;
    *width = (uint32_t)slot->width;
    *height = (uint32_t)slot->height;

    return TRUE;
}

static void mlt_video_texture_class_init(
    MltVideoTextureClass *klass)
{
    FL_TEXTURE_GL_CLASS(klass)->populate =
        mlt_video_texture_populate;
}

static void mlt_video_texture_init(
    MltVideoTexture *self)
{
    self->gl_texture_id = 0;
    self->uploaded_width = 0;
    self->uploaded_height = 0;
}

/* ------------------------------------------------------------------------- */
/* Frame notification                                                        */
/* ------------------------------------------------------------------------- */

static gboolean mark_flutter_texture_frame(
    gpointer user_data)
{
    (void)user_data;

    ensure_locks();

    g_mutex_lock(&texture_mutex);

    FlTextureRegistrar *registrar =
        texture_registrar;

    MltVideoTexture *texture =
        video_texture;

    if (registrar != NULL &&
        texture != NULL) {
        g_object_ref(registrar);
        g_object_ref(texture);
    } else {
        registrar = NULL;
        texture = NULL;
    }

    g_mutex_unlock(&texture_mutex);

    if (registrar != NULL) {
        fl_texture_registrar_mark_texture_frame_available(
            registrar,
            FL_TEXTURE(texture)
        );

        g_object_unref(texture);
        g_object_unref(registrar);
    }

    g_atomic_int_set(
        &frame_notification_pending,
        0
    );

    return G_SOURCE_REMOVE;
}

static void notify_flutter_frame_available(void)
{
    /*
     * Coalesce: if a notification is already queued it will pick up
     * whatever the newest frame turns out to be by the time it runs.
     */
    if (g_atomic_int_compare_and_exchange(
            &frame_notification_pending,
            0,
            1)) {
        g_main_context_invoke(
            NULL,
            mark_flutter_texture_frame,
            NULL
        );
    }
}

/* ------------------------------------------------------------------------- */
/* MLT frame callback                                                        */
/* ------------------------------------------------------------------------- */

/*
 * Runs on MLT's consumer thread, which is also the thread that
 * paces audio. Everything here is either a cache hit or a memcpy.
 *
 * The image itself is rendered ahead of time on MLT's render
 * threads, because the consumer carries "mlt_image_format=rgba"
 * and "video_off=0". By the time this fires, mlt_frame_get_image
 * with a matching format is a lookup rather than a decode.
 */
static void on_consumer_frame_show(
    mlt_properties owner,
    void *listener_data,
    mlt_event_data event_data)
{
    (void)owner;
    (void)listener_data;

    mlt_frame frame =
        mlt_event_data_to_frame(
            event_data
        );

    if (frame == NULL) {
        return;
    }

    const int64_t position =
        (int64_t)mlt_frame_get_position(
            frame
        );

    ensure_locks();

    g_mutex_lock(&frame_mutex);

    const int already_have_frame =
        position == last_frame_position;

    g_mutex_unlock(&frame_mutex);

    if (already_have_frame) {
        return;
    }

    mlt_image_format format =
        mlt_image_rgba;

    uint8_t *image = NULL;

    int width =
        g_atomic_int_get(&target_width);

    int height =
        g_atomic_int_get(&target_height);

    const int image_error =
        mlt_frame_get_image(
            frame,
            &image,
            &format,
            &width,
            &height,
            0
        );

    if (image_error != 0 ||
        image == NULL ||
        format != mlt_image_rgba ||
        width <= 0 ||
        height <= 0) {
        return;
    }

    /*
     * Ask MLT how large the image actually is rather than assuming
     * four packed bytes per pixel, so that a future change to
     * alignment or stride does not turn into a silent overread.
     */
    const int measured_size =
        mlt_image_format_size(
            format,
            width,
            height,
            NULL
        );

    if (measured_size <= 0) {
        return;
    }

    const size_t required_size =
        (size_t)measured_size;

    /*
     * slot_write belongs to this thread, so the copy needs no lock.
     */
    FrameSlot *slot =
        &slots[slot_write];

    if (required_size > slot->capacity) {
        uint8_t *new_buffer =
            realloc(
                slot->data,
                required_size
            );

        if (new_buffer == NULL) {
            return;
        }

        slot->data = new_buffer;
        slot->capacity = required_size;
    }

    memcpy(
        slot->data,
        image,
        required_size
    );

    slot->width = width;
    slot->height = height;

    /* Publish. */
    g_mutex_lock(&frame_mutex);

    const int previous_ready =
        slot_ready;

    slot_ready = slot_write;
    slot_write = previous_ready;

    slot_ready_valid = 1;

    last_frame_position = position;

    g_mutex_unlock(&frame_mutex);

    notify_flutter_frame_available();
}

/* ------------------------------------------------------------------------- */
/* Flutter texture registration                                              */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_register_flutter_texture(
    FlTextureRegistrar *registrar)
{
    if (registrar == NULL) {
        return -1;
    }

    ensure_locks();

    g_mutex_lock(&texture_mutex);

    if (video_texture != NULL &&
        texture_registrar != NULL) {
        const int64_t existing =
            fl_texture_get_id(
                FL_TEXTURE(video_texture)
            );

        g_mutex_unlock(&texture_mutex);

        return existing;
    }

    FlTextureRegistrar *local_registrar =
        FL_TEXTURE_REGISTRAR(
            g_object_ref(registrar)
        );

    MltVideoTexture *local_texture =
        (MltVideoTexture *)
            g_object_new(
                mlt_video_texture_get_type(),
                NULL
            );

    if (local_texture == NULL) {
        g_object_unref(local_registrar);

        g_mutex_unlock(&texture_mutex);

        return -1;
    }

    if (!fl_texture_registrar_register_texture(
            local_registrar,
            FL_TEXTURE(local_texture))) {
        g_object_unref(local_texture);
        g_object_unref(local_registrar);

        g_mutex_unlock(&texture_mutex);

        return -1;
    }

    texture_registrar = local_registrar;
    video_texture = local_texture;

    const int64_t texture_id =
        fl_texture_get_id(
            FL_TEXTURE(video_texture)
        );

    g_mutex_unlock(&texture_mutex);

    return texture_id;
}

MLT_BRIDGE_EXPORT
void mlt_bridge_unregister_flutter_texture(void)
{
    ensure_locks();

    g_mutex_lock(&texture_mutex);

    FlTextureRegistrar *local_registrar =
        texture_registrar;

    MltVideoTexture *local_texture =
        video_texture;

    texture_registrar = NULL;
    video_texture = NULL;

    g_mutex_unlock(&texture_mutex);

    if (local_registrar != NULL &&
        local_texture != NULL) {
        fl_texture_registrar_unregister_texture(
            local_registrar,
            FL_TEXTURE(local_texture)
        );
    }

    if (local_texture != NULL) {
        g_object_unref(local_texture);
    }

    if (local_registrar != NULL) {
        g_object_unref(local_registrar);
    }

    release_slots();
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_texture_id(void)
{
    ensure_locks();

    g_mutex_lock(&texture_mutex);

    const int64_t texture_id =
        video_texture != NULL
            ? fl_texture_get_id(
                  FL_TEXTURE(video_texture)
              )
            : -1;

    g_mutex_unlock(&texture_mutex);

    return texture_id;
}

/* ------------------------------------------------------------------------- */
/* Producer and consumer, all called with engine_mutex held                  */
/* ------------------------------------------------------------------------- */

static void close_consumer_locked(void)
{
    if (consumer != NULL) {
        mlt_consumer_stop(consumer);
        mlt_consumer_close(consumer);

        consumer = NULL;
    }
}

static void close_producer_locked(void)
{
    close_consumer_locked();

    if (producer != NULL) {
        mlt_producer_close(producer);

        producer = NULL;
    }

    has_video = 0;
    has_audio = 0;
    is_still = 0;

    g_atomic_int_set(&target_width, 0);
    g_atomic_int_set(&target_height, 0);
}

/*
 * MLT's loader will happily produce something for almost any path.
 * A .txt file comes back as a "pango" producer: a text renderer with
 * a default length of 15000 frames. Left alone, that is a ten minute
 * title card masquerading as a movie. So the service name decides
 * what we are actually holding.
 */
typedef enum _MediaKind {
    MEDIA_TIMED,       /* real duration, real timeline   */
    MEDIA_STILL,       /* one picture, synthetic length  */
    MEDIA_UNSUPPORTED  /* opened, but not playable media */
} MediaKind;

static MediaKind classify_producer_locked(
    mlt_producer candidate)
{
    mlt_properties properties =
        MLT_PRODUCER_PROPERTIES(candidate);

    const char *service =
        mlt_properties_get(
            properties,
            "mlt_service"
        );

    if (service == NULL) {
        return MEDIA_UNSUPPORTED;
    }

    static const char *timed_services[] = {
        "avformat",
        "avformat-novalidate",
        "chain",
        "xml",
        "xml-string",
        "melt",
        "melt_file",
        NULL
    };

    static const char *still_services[] = {
        "pixbuf",
        "qimage",
        "svg",
        "color",
        "colour",
        NULL
    };

    for (int index = 0;
         timed_services[index] != NULL;
         index++) {
        if (strcmp(
                service,
                timed_services[index]) == 0) {
            /*
             * avformat reports its stream count once probed. Zero
             * streams means the demuxer opened the container and
             * found nothing to play.
             */
            if (mlt_properties_get(
                    properties,
                    "meta.media.nb_streams") != NULL &&
                mlt_properties_get_int(
                    properties,
                    "meta.media.nb_streams") <= 0) {
                return MEDIA_UNSUPPORTED;
            }

            return MEDIA_TIMED;
        }
    }

    for (int index = 0;
         still_services[index] != NULL;
         index++) {
        if (strcmp(
                service,
                still_services[index]) == 0) {
            return MEDIA_STILL;
        }
    }

    return MEDIA_UNSUPPORTED;
}

static int create_consumer_locked(void)
{
    if (producer == NULL ||
        profile == NULL) {
        set_error("No producer is loaded.");

        return 0;
    }

    if (consumer != NULL) {
        return 1;
    }

    consumer =
        mlt_factory_consumer(
            profile,
            "sdl2_audio",
            NULL
        );

    if (consumer == NULL) {
        set_error(
            "Could not create the MLT "
            "sdl2_audio consumer."
        );

        return 0;
    }

    mlt_properties properties =
        MLT_CONSUMER_PROPERTIES(consumer);

    /*
     * Asynchronous with frame dropping. Use -1 to forbid dropping,
     * or a value above 1 to spread rendering over that many threads.
     */
    mlt_properties_set_int(
        properties,
        "real_time",
        1
    );

    /*
     * The consumer must stay alive while the producer sits at speed
     * zero, otherwise pausing would tear down playback.
     */
    mlt_properties_set_int(
        properties,
        "terminate_on_pause",
        0
    );

    mlt_properties_set_int(
        properties,
        "scrub_audio",
        0
    );

    mlt_properties_set_double(
        properties,
        "volume",
        requested_volume
    );

    /*
     * These four are read by the framework when it hands a frame to
     * a render thread, and copied onto the frame as "consumer.*".
     * Setting them here rather than inside the frame-show callback
     * is what makes the pre-render correct: by the time the callback
     * runs, the image has already been scaled and deinterlaced.
     */
    mlt_properties_set(
        properties,
        "rescale",
        "bilinear"
    );

    mlt_properties_set(
        properties,
        "deinterlacer",
        MLT_BRIDGE_DEINTERLACER
    );

    mlt_properties_set_int(
        properties,
        "top_field_first",
        -1
    );

    /*
     * A texture is progressive by definition. Without this, naming a
     * deinterlacer has no effect and interlaced sources pass through
     * combed.
     */
    mlt_properties_set_int(
        properties,
        "progressive",
        1
    );

    /*
     * Render video ahead of the timing thread, in the exact format
     * the texture upload wants.
     */
    mlt_properties_set_int(
        properties,
        "video_off",
        0
    );

    mlt_properties_set(
        properties,
        "mlt_image_format",
        "rgba"
    );

    mlt_events_listen(
        properties,
        NULL,
        "consumer-frame-show",
        (mlt_listener)on_consumer_frame_show
    );

    const int connect_result =
        mlt_consumer_connect(
            consumer,
            MLT_PRODUCER_SERVICE(producer)
        );

    if (connect_result != 0) {
        mlt_consumer_close(consumer);

        consumer = NULL;

        set_error(
            "MLT could not connect the "
            "audio consumer to the producer."
        );

        return 0;
    }

    return 1;
}

/* Restarts the consumer only when it has actually stopped. */
static int ensure_consumer_running_locked(void)
{
    if (consumer == NULL) {
        return 0;
    }

    if (!mlt_consumer_is_stopped(consumer)) {
        return 1;
    }

    /*
     * The consumer stops itself at end of file. Stopping again is
     * what joins its threads, and skipping it leaks one thread per
     * replay.
     */
    mlt_consumer_stop(consumer);

    if (mlt_consumer_start(consumer) != 0) {
        set_error("MLT could not start playback.");

        return 0;
    }

    return 1;
}

static void refresh_locked(void)
{
    if (consumer == NULL) {
        return;
    }

    mlt_properties_set_int(
        MLT_CONSUMER_PROPERTIES(consumer),
        "refresh",
        1
    );
}

/* ------------------------------------------------------------------------- */
/* Lifecycle                                                                 */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT
int mlt_bridge_init(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    if (repository != NULL &&
        profile != NULL) {
        g_mutex_unlock(&engine_mutex);

        return 1;
    }

    if (repository == NULL) {
        repository = mlt_factory_init(NULL);
    }

    if (repository == NULL) {
        set_error("Failed to initialize MLT.");

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    if (profile == NULL) {
        profile = mlt_profile_init(NULL);
    }

    if (profile == NULL) {
        set_error(
            "Failed to create the MLT profile."
        );

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    set_error(NULL);

    g_mutex_unlock(&engine_mutex);

    return 1;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_version(void)
{
    return mlt_version_get_string();
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_last_error(void)
{
    return last_error;
}

MLT_BRIDGE_EXPORT
void mlt_bridge_shutdown(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    close_producer_locked();

    if (profile != NULL) {
        mlt_profile_close(profile);

        profile = NULL;
    }

    if (repository != NULL) {
        mlt_factory_close();

        repository = NULL;
    }

    g_mutex_unlock(&engine_mutex);

    release_slots();
}

/* ------------------------------------------------------------------------- */
/* Media                                                                     */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT
int mlt_bridge_open(
    const char *path)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    if (repository == NULL ||
        path == NULL ||
        path[0] == '\0') {
        set_error(
            "MLT is not initialized "
            "or the path is invalid."
        );

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    close_producer_locked();

    if (profile != NULL) {
        mlt_profile_close(profile);

        profile = NULL;
    }

    profile = mlt_profile_init(NULL);

    if (profile == NULL) {
        set_error(
            "Could not create an MLT profile."
        );

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    /*
     * First open discovers the geometry, second open runs against a
     * profile that matches it. Doing this in one pass would leave
     * the producer configured for whatever the default profile was.
     */
    mlt_producer probe_producer =
        mlt_factory_producer(
            profile,
            NULL,
            path
        );

    if (probe_producer == NULL) {
        set_error(
            "MLT could not open the selected media."
        );

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    mlt_producer_probe(probe_producer);
    mlt_profile_from_producer(profile, probe_producer);
    mlt_producer_close(probe_producer);

    producer =
        mlt_factory_producer(
            profile,
            NULL,
            path
        );

    if (producer == NULL) {
        set_error(
            "MLT could not reopen the media "
            "with the detected profile."
        );

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    mlt_producer_probe(producer);

    mlt_properties producer_properties =
        MLT_PRODUCER_PROPERTIES(producer);

    const MediaKind kind =
        classify_producer_locked(producer);

    if (kind == MEDIA_UNSUPPORTED) {
        char message[512];

        const char *service =
            mlt_properties_get(
                producer_properties,
                "mlt_service"
            );

        snprintf(
            message,
            sizeof(message),
            "MLT opened this as a '%s' resource, "
            "which is not playable media.",
            service != NULL ? service : "unknown"
        );

        set_error(message);

        close_producer_locked();

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    is_still = (kind == MEDIA_STILL);

    if (is_still) {
        has_video = 1;
        has_audio = 0;
    } else {
        /*
         * avformat sets these indices to -1 when the corresponding
         * stream is absent. When a property is missing entirely we
         * have no evidence either way, so assume the stream exists
         * and let the consumer produce silence or a test card.
         */
        has_video =
            mlt_properties_get(
                producer_properties,
                "video_index") == NULL ||
            mlt_properties_get_int(
                producer_properties,
                "video_index") >= 0;

        has_audio =
            mlt_properties_get(
                producer_properties,
                "audio_index") == NULL ||
            mlt_properties_get_int(
                producer_properties,
                "audio_index") >= 0;
    }

    if (mlt_producer_get_length(producer) <= 0) {
        set_error("The media reports no duration.");

        close_producer_locked();

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    g_atomic_int_set(
        &target_width,
        profile->width
    );

    g_atomic_int_set(
        &target_height,
        profile->height
    );

    mlt_producer_set_speed(producer, 0.0);
    mlt_producer_seek(producer, 0);

    if (!create_consumer_locked()) {
        close_producer_locked();

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    if (mlt_consumer_start(consumer) != 0) {
        set_error(
            "MLT could not start the "
            "audio and preview consumer."
        );

        close_producer_locked();

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    refresh_locked();

    set_error(NULL);

    g_mutex_unlock(&engine_mutex);

    /*
     * Drop any frame left over from the previous file so the first
     * frame of this one is not rejected as a duplicate position.
     */
    invalidate_frames();

    return 1;
}

MLT_BRIDGE_EXPORT
void mlt_bridge_close_media(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    close_producer_locked();

    g_mutex_unlock(&engine_mutex);

    release_slots();
}

/* ------------------------------------------------------------------------- */
/* Transport                                                                 */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT
int mlt_bridge_play(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    if (producer == NULL) {
        set_error("No media is loaded.");

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    if (!create_consumer_locked()) {
        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    const mlt_position length =
        mlt_producer_get_length(producer);

    const mlt_position position =
        mlt_producer_position(producer);

    int rewound = 0;

    if (length > 0 &&
        position >= length - 1) {
        mlt_consumer_purge(consumer);
        mlt_producer_seek(producer, 0);

        rewound = 1;
    }

    mlt_producer_set_speed(producer, 1.0);

    if (!ensure_consumer_running_locked()) {
        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    refresh_locked();

    set_error(NULL);

    g_mutex_unlock(&engine_mutex);

    if (rewound) {
        invalidate_frames();
    }

    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_pause(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    if (producer == NULL) {
        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    if (consumer == NULL) {
        mlt_producer_set_speed(producer, 0.0);

        g_mutex_unlock(&engine_mutex);

        return 1;
    }

    /*
     * The consumer has already shown the frame it reports, so the
     * paused position is the next one.
     */
    mlt_position position =
        mlt_consumer_position(consumer) + 1;

    const mlt_position length =
        mlt_producer_get_length(producer);

    if (position < 0) {
        position = 0;
    }

    if (length > 0 &&
        position >= length) {
        position = length - 1;
    }

    mlt_producer_set_speed(producer, 0.0);
    mlt_consumer_purge(consumer);
    mlt_producer_seek(producer, position);

    refresh_locked();

    set_error(NULL);

    g_mutex_unlock(&engine_mutex);

    invalidate_frames();

    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_seek_ms(
    int64_t milliseconds)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    if (producer == NULL) {
        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    const double fps =
        mlt_producer_get_fps(producer);

    if (fps <= 0.0) {
        set_error(
            "Producer has an invalid frame rate."
        );

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    mlt_position frame =
        (mlt_position)(
            ((double)milliseconds / 1000.0) * fps
        );

    const mlt_position length =
        mlt_producer_get_length(producer);

    if (frame < 0) {
        frame = 0;
    }

    if (length > 0 &&
        frame >= length) {
        frame = length - 1;
    }

    if (consumer != NULL) {
        mlt_consumer_purge(consumer);
    }

    if (mlt_producer_seek(producer, frame) != 0) {
        set_error("MLT seek failed.");

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    /*
     * A seek does not restart the consumer. Purge plus refresh is
     * the supported way to make a running or paused consumer show
     * the new position.
     */
    refresh_locked();

    set_error(NULL);

    g_mutex_unlock(&engine_mutex);

    invalidate_frames();

    return 1;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_position_ms(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    if (producer == NULL) {
        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    const double fps =
        mlt_producer_get_fps(producer);

    if (fps <= 0.0) {
        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    /*
     * While playing, the consumer knows what the viewer is actually
     * looking at. While paused or seeking, the producer holds the
     * position we just asked for and the consumer is stale.
     */
    const int playing =
        consumer != NULL &&
        !mlt_consumer_is_stopped(consumer) &&
        mlt_producer_get_speed(producer) != 0.0;

    mlt_position position =
        playing
            ? mlt_consumer_position(consumer)
            : mlt_producer_position(producer);

    if (position < 0) {
        position = 0;
    }

    g_mutex_unlock(&engine_mutex);

    return (int64_t)(
        ((double)position / fps) * 1000.0
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_is_playing(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const int playing =
        producer != NULL &&
        consumer != NULL &&
        !mlt_consumer_is_stopped(consumer) &&
        mlt_producer_get_speed(producer) != 0.0;

    g_mutex_unlock(&engine_mutex);

    return playing;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_is_eof(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    int at_end = 0;

    if (producer != NULL && !is_still) {
        const mlt_position length =
            mlt_producer_get_length(producer);

        mlt_position position =
            mlt_producer_position(producer);

        if (consumer != NULL &&
            !mlt_consumer_is_stopped(consumer) &&
            mlt_producer_get_speed(producer) != 0.0) {
            position =
                mlt_consumer_position(consumer);
        }

        at_end =
            length > 0 &&
            position >= length - 1;
    }

    g_mutex_unlock(&engine_mutex);

    return at_end;
}

/* ------------------------------------------------------------------------- */
/* Audio                                                                     */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT
void mlt_bridge_set_volume(
    double volume)
{
    ensure_locks();

    if (volume < 0.0) {
        volume = 0.0;
    }

    if (volume > 1.0) {
        volume = 1.0;
    }

    g_mutex_lock(&engine_mutex);

    requested_volume = volume;

    if (consumer != NULL) {
        mlt_properties_set_double(
            MLT_CONSUMER_PROPERTIES(consumer),
            "volume",
            volume
        );
    }

    g_mutex_unlock(&engine_mutex);
}

MLT_BRIDGE_EXPORT
double mlt_bridge_volume(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const double volume = requested_volume;

    g_mutex_unlock(&engine_mutex);

    return volume;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_has_audio(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const int result =
        producer != NULL && has_audio;

    g_mutex_unlock(&engine_mutex);

    return result;
}

/* ------------------------------------------------------------------------- */
/* Media properties                                                          */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_duration_frames(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const int64_t frames =
        producer != NULL && !is_still
            ? (int64_t)mlt_producer_get_length(producer)
            : 0;

    g_mutex_unlock(&engine_mutex);

    return frames;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_fps(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const double fps =
        producer != NULL
            ? mlt_producer_get_fps(producer)
            : 0.0;

    g_mutex_unlock(&engine_mutex);

    return fps;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_duration_ms(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    int64_t duration = 0;

    if (producer != NULL && !is_still) {
        const double fps =
            mlt_producer_get_fps(producer);

        if (fps > 0.0) {
            const int64_t frames =
                (int64_t)mlt_producer_get_length(producer);

            duration =
                (int64_t)(((double)frames / fps) * 1000.0);
        }
    }

    g_mutex_unlock(&engine_mutex);

    return duration;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_width(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const int width =
        producer != NULL && has_video && profile != NULL
            ? profile->width
            : 0;

    g_mutex_unlock(&engine_mutex);

    return width;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_height(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const int height =
        producer != NULL && has_video && profile != NULL
            ? profile->height
            : 0;

    g_mutex_unlock(&engine_mutex);

    return height;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_display_aspect(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    double aspect = 0.0;

    if (producer != NULL &&
        has_video &&
        profile != NULL) {
        if (profile->display_aspect_num > 0 &&
            profile->display_aspect_den > 0) {
            aspect =
                (double)profile->display_aspect_num /
                (double)profile->display_aspect_den;
        } else if (profile->height > 0) {
            aspect =
                (double)profile->width /
                (double)profile->height;
        }
    }

    g_mutex_unlock(&engine_mutex);

    return aspect;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_is_still(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const int result =
        producer != NULL && is_still;

    g_mutex_unlock(&engine_mutex);

    return result;
}
