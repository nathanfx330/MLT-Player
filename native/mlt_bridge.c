/* native/mlt_bridge.c */

#include "mlt_bridge.h"

#include <flutter_linux/flutter_linux.h>
#include <epoxy/gl.h>
#include <framework/mlt.h>
#include <glib.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

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
static int requested_play_all_frames = 0;

/* Read-only stream inspection captured when a producer is opened. */
static int stream_count = 0;
static int selected_video_stream_index = -1;
static int selected_audio_stream_index = -1;

static char video_codec_name[128] = "";
static char video_codec_long_name[256] = "";
static char audio_codec_name[128] = "";
static char audio_codec_long_name[256] = "";

static char video_pixel_format[128] = "";
static int video_colorspace = -1;
static int video_color_trc = -1;
static char video_color_range[32] = "";

typedef struct _StreamInspection {
    char type[32];
    char codec_name[128];
    char codec_long_name[256];
    char language[64];
    int channels;
    int sample_rate;
    int width;
    int height;
    int64_t bit_rate;
} StreamInspection;

static StreamInspection *stream_inspection = NULL;
static int stream_inspection_count = 0;

static char last_error[512] = "";
static char source_timecode[128] = "";

/* Published for the frame callback without taking engine_mutex. */
static gint target_width = 0;
static gint target_height = 0;

/* ------------------------------------------------------------------------- */
/* Export state                                                              */
/* ------------------------------------------------------------------------- */

/*
 * Export owns a completely separate producer/profile/consumer graph from
 * preview playback. Only these small status fields cross thread boundaries.
 */
static GMutex export_mutex;
static GThread *export_thread = NULL;
static int export_running = 0;
static int export_success = 0;
static int export_cancel_requested = 0;
static double export_progress = 0.0;
static char export_error[512] = "";

typedef enum _ExportKind {
    EXPORT_KIND_MP4 = 0,
    EXPORT_KIND_PNG_FRAME = 1,
    EXPORT_KIND_PNG_SEQUENCE = 2,
    EXPORT_KIND_WAV_AUDIO = 3
} ExportKind;

typedef struct _ExportJob {
    char *source_path;
    char *output_path;
    int64_t in_frame;
    int64_t out_frame;
    ExportKind kind;
} ExportJob;

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
static GCond frame_idle_cond;
static int active_frame_readers = 0;

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
        g_cond_init(&frame_idle_cond);
        g_mutex_init(&texture_mutex);
        g_mutex_init(&export_mutex);

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

/*
 * Free the shared frame buffers only after the MLT consumer has stopped.
 * The producer callback can then no longer own slot_write. A Flutter raster
 * callback may still be finishing an upload, so wait for every active reader
 * to leave before invalidating any slot storage.
 */
static void release_slots(void)
{
    ensure_locks();

    g_mutex_lock(&frame_mutex);

    while (active_frame_readers > 0) {
        g_cond_wait(
            &frame_idle_cond,
            &frame_mutex
        );
    }

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

    active_frame_readers += 1;

    g_mutex_unlock(&frame_mutex);

    FrameSlot *slot =
        &slots[display_index];

    if (slot->data == NULL ||
        slot->width <= 0 ||
        slot->height <= 0) {
        g_mutex_lock(&frame_mutex);

        active_frame_readers -= 1;

        if (active_frame_readers == 0) {
            g_cond_broadcast(&frame_idle_cond);
        }

        g_mutex_unlock(&frame_mutex);

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

    g_mutex_lock(&frame_mutex);

    active_frame_readers -= 1;

    if (active_frame_readers == 0) {
        g_cond_broadcast(&frame_idle_cond);
    }

    g_mutex_unlock(&frame_mutex);

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

/* close_consumer_locked() is defined with the producer helpers below. */
static void close_consumer_locked(void);

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

    /*
     * Slot storage is shared with the MLT frame callback. Stop and join the
     * consumer before detaching the Flutter texture so the writer cannot be
     * inside realloc()/memcpy() when release_slots() frees the buffers.
     *
     * This is intentionally safe to call after mlt_bridge_shutdown(): in that
     * case the consumer is already NULL and close_consumer_locked() is a no-op.
     */
    g_mutex_lock(&engine_mutex);
    close_consumer_locked();
    g_mutex_unlock(&engine_mutex);

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

    stream_count = 0;
    selected_video_stream_index = -1;
    selected_audio_stream_index = -1;

    video_codec_name[0] = '\0';
    video_codec_long_name[0] = '\0';
    audio_codec_name[0] = '\0';
    audio_codec_long_name[0] = '\0';

    video_pixel_format[0] = '\0';
    video_colorspace = -1;
    video_color_trc = -1;
    video_color_range[0] = '\0';

    free(stream_inspection);
    stream_inspection = NULL;
    stream_inspection_count = 0;

    source_timecode[0] = '\0';

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

/*
 * Copy the codec metadata for one absolute stream index into bridge-owned
 * storage. avformat publishes both a short decoder name (for example
 * "h264") and a human-readable long name. Keeping our own copy means Dart
 * never holds a pointer into producer properties after the engine lock is
 * released.
 */
static void read_codec_metadata_locked(
    mlt_properties properties,
    int stream_index,
    char *short_name,
    size_t short_name_size,
    char *long_name,
    size_t long_name_size)
{
    short_name[0] = '\0';
    long_name[0] = '\0';

    if (properties == NULL || stream_index < 0) {
        return;
    }

    char key[128];

    snprintf(
        key,
        sizeof(key),
        "meta.media.%d.codec.name",
        stream_index
    );

    const char *value =
        mlt_properties_get(properties, key);

    if (value != NULL && value[0] != '\0') {
        snprintf(
            short_name,
            short_name_size,
            "%s",
            value
        );
    }

    snprintf(
        key,
        sizeof(key),
        "meta.media.%d.codec.long_name",
        stream_index
    );

    value = mlt_properties_get(properties, key);

    if (value != NULL && value[0] != '\0') {
        snprintf(
            long_name,
            long_name_size,
            "%s",
            value
        );
    }
}

/*
 * Capture the selected video stream's source pixel/color description.
 * MLT's avformat producer publishes the source pixel format, an MLT
 * colorspace identifier, and (when the source declares it) a transfer
 * characteristic. Color range is copied when MLT exposes it; otherwise we
 * only infer full range for pixel formats whose naming makes that explicit.
 */
static void read_video_color_metadata_locked(
    mlt_properties properties,
    int stream_index)
{
    video_pixel_format[0] = '\0';
    video_colorspace = -1;
    video_color_trc = -1;
    video_color_range[0] = '\0';

    if (properties == NULL || stream_index < 0) {
        return;
    }

    char key[128];

    snprintf(
        key,
        sizeof(key),
        "meta.media.%d.codec.pix_fmt",
        stream_index
    );

    const char *value =
        mlt_properties_get(properties, key);

    if (value != NULL && value[0] != '\0') {
        snprintf(
            video_pixel_format,
            sizeof(video_pixel_format),
            "%s",
            value
        );
    }

    snprintf(
        key,
        sizeof(key),
        "meta.media.%d.codec.colorspace",
        stream_index
    );

    if (mlt_properties_get(properties, key) != NULL) {
        video_colorspace =
            mlt_properties_get_int(properties, key);
    }

    snprintf(
        key,
        sizeof(key),
        "meta.media.%d.codec.color_trc",
        stream_index
    );

    if (mlt_properties_get(properties, key) != NULL) {
        video_color_trc =
            mlt_properties_get_int(properties, key);
    }

    value =
        mlt_properties_get(
            properties,
            "meta.media.color_range"
        );

    if (value != NULL && value[0] != '\0') {
        if (strcmp(value, "full") == 0 ||
            strcmp(value, "jpeg") == 0) {
            snprintf(
                video_color_range,
                sizeof(video_color_range),
                "%s",
                "Full"
            );
        } else if (strcmp(value, "limited") == 0 ||
                   strcmp(value, "mpeg") == 0) {
            snprintf(
                video_color_range,
                sizeof(video_color_range),
                "%s",
                "Limited"
            );
        } else {
            snprintf(
                video_color_range,
                sizeof(video_color_range),
                "%s",
                value
            );
        }
    } else if (video_pixel_format[0] != '\0' &&
               (strncmp(video_pixel_format, "yuvj", 4) == 0 ||
                strstr(video_pixel_format, "rgb") != NULL ||
                strstr(video_pixel_format, "gbr") != NULL)) {
        snprintf(
            video_color_range,
            sizeof(video_color_range),
            "%s",
            "Full"
        );
    }
}

/*
 * Snapshot every avformat stream into bridge-owned storage. Dart reads this
 * once when MediaInfo is constructed, so the inspector never polls producer
 * properties during playback.
 */
static void read_stream_inspection_locked(
    mlt_properties properties)
{
    free(stream_inspection);
    stream_inspection = NULL;
    stream_inspection_count = 0;

    if (properties == NULL || stream_count <= 0) {
        return;
    }

    stream_inspection =
        calloc((size_t)stream_count, sizeof(StreamInspection));

    if (stream_inspection == NULL) {
        return;
    }

    stream_inspection_count = stream_count;

    for (int inspection_index = 0;
         inspection_index < stream_inspection_count;
         inspection_index++) {
        StreamInspection *info = &stream_inspection[inspection_index];
        char key[160];
        const char *value = NULL;

        snprintf(
            key,
            sizeof(key),
            "meta.media.%d.stream.type",
            inspection_index
        );
        value = mlt_properties_get(properties, key);
        snprintf(
            info->type,
            sizeof(info->type),
            "%s",
            value != NULL && value[0] != '\0' ? value : "other"
        );

        snprintf(
            key,
            sizeof(key),
            "meta.media.%d.codec.name",
            inspection_index
        );
        value = mlt_properties_get(properties, key);
        if (value != NULL && value[0] != '\0') {
            snprintf(info->codec_name, sizeof(info->codec_name), "%s", value);
        }

        snprintf(
            key,
            sizeof(key),
            "meta.media.%d.codec.long_name",
            inspection_index
        );
        value = mlt_properties_get(properties, key);
        if (value != NULL && value[0] != '\0') {
            snprintf(
                info->codec_long_name,
                sizeof(info->codec_long_name),
                "%s",
                value
            );
        }

        snprintf(
            key,
            sizeof(key),
            "meta.attr.%d.stream.language.markup",
            inspection_index
        );
        value = mlt_properties_get(properties, key);
        if (value != NULL && value[0] != '\0') {
            snprintf(info->language, sizeof(info->language), "%s", value);
        }

        snprintf(
            key,
            sizeof(key),
            "meta.media.%d.codec.channels",
            inspection_index
        );
        if (mlt_properties_get(properties, key) != NULL) {
            info->channels = mlt_properties_get_int(properties, key);
        }

        snprintf(
            key,
            sizeof(key),
            "meta.media.%d.codec.sample_rate",
            inspection_index
        );
        if (mlt_properties_get(properties, key) != NULL) {
            info->sample_rate = mlt_properties_get_int(properties, key);
        }

        snprintf(
            key,
            sizeof(key),
            "meta.media.%d.codec.width",
            inspection_index
        );
        if (mlt_properties_get(properties, key) != NULL) {
            info->width = mlt_properties_get_int(properties, key);
        }

        snprintf(
            key,
            sizeof(key),
            "meta.media.%d.codec.height",
            inspection_index
        );
        if (mlt_properties_get(properties, key) != NULL) {
            info->height = mlt_properties_get_int(properties, key);
        }

        snprintf(
            key,
            sizeof(key),
            "meta.media.%d.codec.bit_rate",
            inspection_index
        );
        if (mlt_properties_get(properties, key) != NULL) {
            info->bit_rate = mlt_properties_get_int64(properties, key);
        }
    }
}

static const StreamInspection *stream_inspection_at_locked(int index)
{
    if (producer == NULL ||
        stream_inspection == NULL ||
        index < 0 ||
        index >= stream_inspection_count) {
        return NULL;
    }

    return &stream_inspection[index];
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
     * Normal playback is asynchronous and may drop video frames to keep
     * real time. QuickTime-style Play All Frames flips MLT to -1, which
     * disables frame dropping; if rendering cannot keep up, playback slows
     * instead of skipping pictures.
     */
    mlt_properties_set_int(
        properties,
        "real_time",
        requested_play_all_frames ? -1 : 1
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
/* Background export                                                        */
/* ------------------------------------------------------------------------- */

static void export_set_error_locked(const char *message)
{
    if (message == NULL) {
        export_error[0] = '\0';
        return;
    }

    snprintf(
        export_error,
        sizeof(export_error),
        "%s",
        message
    );
}

static int export_cancel_was_requested(void)
{
    ensure_locks();

    g_mutex_lock(&export_mutex);
    const int requested = export_cancel_requested;
    g_mutex_unlock(&export_mutex);

    return requested;
}

static void export_publish_progress(double value)
{
    if (value < 0.0) {
        value = 0.0;
    } else if (value > 1.0) {
        value = 1.0;
    }

    ensure_locks();

    g_mutex_lock(&export_mutex);
    export_progress = value;
    g_mutex_unlock(&export_mutex);
}

static int output_file_has_data(const char *path)
{
    struct stat info;

    return path != NULL &&
        stat(path, &info) == 0 &&
        info.st_size > 0;
}

/*
 * image2 treats percent signs in its target as filename-pattern syntax.
 * Escape any literal percent signs in the chosen directory before appending
 * the one pattern token that belongs to this export.
 */
static char *export_sequence_consumer_target(
    const char *directory)
{
    if (directory == NULL ||
        directory[0] == '\0') {
        return NULL;
    }

    GString *escaped =
        g_string_sized_new(strlen(directory) + 32);

    if (escaped == NULL) {
        return NULL;
    }

    for (const char *cursor = directory;
         *cursor != '\0';
         cursor++) {
        if (*cursor == '%') {
            g_string_append(escaped, "%%");
        } else {
            g_string_append_c(escaped, *cursor);
        }
    }

    char *target =
        g_build_filename(
            escaped->str,
            "frame_%06d.png",
            NULL
        );

    g_string_free(escaped, TRUE);

    return target;
}

static int64_t export_sequence_frame_number(
    const char *name)
{
    static const char prefix[] = "frame_";
    static const char suffix[] = ".png";

    if (name == NULL ||
        !g_str_has_prefix(name, prefix) ||
        !g_str_has_suffix(name, suffix)) {
        return -1;
    }

    const size_t name_length = strlen(name);
    const size_t prefix_length = strlen(prefix);
    const size_t suffix_length = strlen(suffix);

    if (name_length <= prefix_length + suffix_length) {
        return -1;
    }

    const size_t digits_length =
        name_length - prefix_length - suffix_length;

    if (digits_length < 6) {
        return -1;
    }

    int64_t value = 0;

    for (size_t index = 0;
         index < digits_length;
         index++) {
        const char digit =
            name[prefix_length + index];

        if (digit < '0' || digit > '9') {
            return -1;
        }

        const int next_digit = digit - '0';

        if (value > (G_MAXINT64 - next_digit) / 10) {
            return -1;
        }

        value = (value * 10) + next_digit;
    }

    return value > 0 ? value : -1;
}

static int export_sequence_filename_is_owned(
    const char *name)
{
    return export_sequence_frame_number(name) > 0;
}

static int export_directory_is_empty(
    const char *directory)
{
    if (directory == NULL ||
        directory[0] == '\0') {
        return 0;
    }

    GDir *dir =
        g_dir_open(directory, 0, NULL);

    if (dir == NULL) {
        return 0;
    }

    const char *name =
        g_dir_read_name(dir);

    const int is_empty =
        name == NULL;

    g_dir_close(dir);

    return is_empty;
}

/*
 * Sequence exports always target a dedicated directory created by the Dart
 * UI. On cancellation or failure, delete only filenames owned by this export
 * and then remove the directory if it is empty. This preserves the same
 * "no partial output" contract used by movie and still exports.
 */
static void export_remove_sequence_outputs(
    const char *directory)
{
    if (directory == NULL ||
        directory[0] == '\0') {
        return;
    }

    GDir *dir =
        g_dir_open(directory, 0, NULL);

    if (dir != NULL) {
        const char *name = NULL;

        while ((name = g_dir_read_name(dir)) != NULL) {
            if (!export_sequence_filename_is_owned(name)) {
                continue;
            }

            char *path =
                g_build_filename(
                    directory,
                    name,
                    NULL
                );

            if (path != NULL) {
                remove(path);
                g_free(path);
            }
        }

        g_dir_close(dir);
    }

    /*
     * remove() also removes an empty directory on POSIX. If a caller placed
     * unrelated files there, it safely fails and leaves the directory alone.
     */
    remove(directory);
}

static void export_remove_partial_output(
    const ExportJob *job)
{
    if (job == NULL) {
        return;
    }

    if (job->kind == EXPORT_KIND_PNG_SEQUENCE) {
        export_remove_sequence_outputs(job->output_path);
        return;
    }

    remove(job->output_path);
}

static void export_job_free(ExportJob *job)
{
    if (job == NULL) {
        return;
    }

    g_free(job->source_path);
    g_free(job->output_path);
    g_free(job);
}

static void export_set_failure(
    char *failure,
    size_t failure_size,
    const char *message)
{
    if (failure == NULL ||
        failure_size == 0) {
        return;
    }

    snprintf(
        failure,
        failure_size,
        "%s",
        message != NULL ? message : "Export failed."
    );
}

static int export_prepare_destination(
    const ExportJob *job,
    char *failure,
    size_t failure_size)
{
    if (job->kind == EXPORT_KIND_PNG_SEQUENCE) {
        if (!g_file_test(
                job->output_path,
                G_FILE_TEST_IS_DIR)) {
            export_set_failure(
                failure,
                failure_size,
                "The image-sequence destination directory is unavailable."
            );
            return 0;
        }

        /*
         * Native code enforces the same ownership contract as the Dart UI:
         * a sequence export only starts in a fresh, empty directory. This
         * makes cancellation cleanup safe even for callers outside Flutter.
         */
        if (!export_directory_is_empty(job->output_path)) {
            export_set_failure(
                failure,
                failure_size,
                "The image-sequence destination directory must be empty."
            );
            return 0;
        }

        return 1;
    }

    /*
     * Save dialogs handle overwrite confirmation for single-file exports.
     * Remove the destination immediately before encoding so avformat always
     * receives a fresh target.
     */
    remove(job->output_path);

    return 1;
}

/*
 * Build the independent source graph shared by every export kind.
 *
 * The source is probed once to derive its native profile, reopened against
 * that profile, constrained to the requested absolute source-frame range,
 * then rebased so producer position zero is the first export frame.
 */
static int export_prepare_source_graph(
    const ExportJob *job,
    mlt_profile *profile_out,
    mlt_producer *producer_out,
    int64_t *in_frame_out,
    int64_t *out_frame_out,
    char *failure,
    size_t failure_size)
{
    mlt_profile source_profile = NULL;
    mlt_producer probe_producer = NULL;
    mlt_producer source_producer = NULL;

    source_profile = mlt_profile_init(NULL);

    if (source_profile == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "Could not create an MLT export profile."
        );
        goto fail;
    }

    probe_producer =
        mlt_factory_producer(
            source_profile,
            NULL,
            job->source_path
        );

    if (probe_producer == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "MLT could not open the source for export."
        );
        goto fail;
    }

    mlt_producer_probe(probe_producer);
    mlt_profile_from_producer(source_profile, probe_producer);
    mlt_producer_close(probe_producer);
    probe_producer = NULL;

    source_producer =
        mlt_factory_producer(
            source_profile,
            NULL,
            job->source_path
        );

    if (source_producer == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "MLT could not reopen the source for export."
        );
        goto fail;
    }

    mlt_producer_probe(source_producer);

    const int64_t source_length =
        (int64_t)mlt_producer_get_length(source_producer);

    int64_t in_frame = job->in_frame;
    int64_t out_frame = job->out_frame;

    if (in_frame < 0) {
        in_frame = 0;
    }

    if (out_frame >= source_length) {
        out_frame = source_length - 1;
    }

    if (source_length <= 0 ||
        out_frame < in_frame) {
        export_set_failure(
            failure,
            failure_size,
            "The requested export range is invalid."
        );
        goto fail;
    }

    if (mlt_producer_set_in_and_out(
            source_producer,
            (mlt_position)in_frame,
            (mlt_position)out_frame) != 0) {
        export_set_failure(
            failure,
            failure_size,
            "MLT could not set the export In/Out range."
        );
        goto fail;
    }

    /*
     * Producer position is relative to its In point after set_in_and_out(),
     * so position zero is exactly the first requested export frame.
     */
    if (mlt_producer_seek(source_producer, 0) != 0 ||
        mlt_producer_set_speed(source_producer, 1.0) != 0) {
        export_set_failure(
            failure,
            failure_size,
            "MLT could not initialize the export transport."
        );
        goto fail;
    }

    *profile_out = source_profile;
    *producer_out = source_producer;
    *in_frame_out = in_frame;
    *out_frame_out = out_frame;

    return 1;

fail:
    if (probe_producer != NULL) {
        mlt_producer_close(probe_producer);
    }

    if (source_producer != NULL) {
        mlt_producer_close(source_producer);
    }

    if (source_profile != NULL) {
        mlt_profile_close(source_profile);
    }

    return 0;
}

/*
 * Most exports consume the source profile directly. PNG image exports differ:
 * it needs square pixels at display geometry so anamorphic storage dimensions
 * are not written as a squeezed image. The cloned profile belongs to the
 * caller; source_profile always remains owned by the source graph.
 */
static int export_prepare_consumer_profile(
    ExportKind kind,
    mlt_profile source_profile,
    mlt_profile *owned_profile_out,
    mlt_profile *consumer_profile_out,
    char *failure,
    size_t failure_size)
{
    *owned_profile_out = NULL;
    *consumer_profile_out = source_profile;

    if (kind == EXPORT_KIND_MP4 ||
        kind == EXPORT_KIND_WAV_AUDIO) {
        return 1;
    }

    if (kind != EXPORT_KIND_PNG_FRAME &&
        kind != EXPORT_KIND_PNG_SEQUENCE) {
        export_set_failure(
            failure,
            failure_size,
            "The requested export type is unsupported."
        );
        return 0;
    }

    mlt_profile image_profile =
        mlt_profile_clone(source_profile);

    if (image_profile == NULL) {
        export_set_failure(
            failure,
            failure_size,
            "Could not create the PNG export profile."
        );
        return 0;
    }

    const double display_aspect =
        mlt_profile_dar(source_profile);

    if (image_profile->height <= 0 ||
        display_aspect <= 0.0) {
        mlt_profile_close(image_profile);

        export_set_failure(
            failure,
            failure_size,
            "The source has invalid display geometry."
        );
        return 0;
    }

    const int display_width =
        (int)(
            ((double)image_profile->height * display_aspect) +
            0.5
        );

    if (display_width <= 0) {
        mlt_profile_close(image_profile);

        export_set_failure(
            failure,
            failure_size,
            "The source has invalid display geometry."
        );
        return 0;
    }

    image_profile->width = display_width;
    image_profile->sample_aspect_num = 1;
    image_profile->sample_aspect_den = 1;
    image_profile->display_aspect_num = display_width;
    image_profile->display_aspect_den = image_profile->height;
    image_profile->progressive = 1;

    *owned_profile_out = image_profile;
    *consumer_profile_out = image_profile;

    return 1;
}

static int export_source_has_audio(
    mlt_producer source_producer)
{
    if (source_producer == NULL) {
        return 0;
    }

    mlt_properties properties =
        MLT_PRODUCER_PROPERTIES(source_producer);

    if (properties == NULL) {
        return 0;
    }

    const char *audio_index_value =
        mlt_properties_get(
            properties,
            "audio_index"
        );

    if (audio_index_value != NULL) {
        return mlt_properties_get_int(
            properties,
            "audio_index"
        ) >= 0;
    }

    /*
     * Some producer types do not publish audio_index. If stream metadata is
     * available, scan it before falling back to the historic "audio may be
     * present" behavior.
     */
    if (mlt_properties_get(
            properties,
            "meta.media.nb_streams") != NULL) {
        const int stream_total =
            mlt_properties_get_int(
                properties,
                "meta.media.nb_streams"
            );

        for (int index = 0;
             index < stream_total;
             index++) {
            char key[128];

            snprintf(
                key,
                sizeof(key),
                "meta.media.%d.stream.type",
                index
            );

            const char *type =
                mlt_properties_get(
                    properties,
                    key
                );

            if (type != NULL &&
                strcmp(type, "audio") == 0) {
                return 1;
            }
        }

        return 0;
    }

    return 1;
}

static void export_configure_mp4_consumer(
    mlt_properties properties,
    mlt_producer source_producer)
{
    /*
     * Fixed POC 9 delivery preset. Match the progressive/deinterlaced image
     * policy used by the viewer and PNG exports, and do not manufacture an
     * AAC stream when the source has no audio.
     */
    mlt_properties_set(properties, "f", "mp4");
    mlt_properties_set(properties, "vcodec", "libx264");
    mlt_properties_set(properties, "pix_fmt", "yuv420p");
    mlt_properties_set(properties, "preset", "medium");
    mlt_properties_set_int(properties, "crf", 18);
    mlt_properties_set(properties, "movflags", "+faststart");

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
    mlt_properties_set_int(
        properties,
        "progressive",
        1
    );

    if (export_source_has_audio(source_producer)) {
        mlt_properties_set(
            properties,
            "acodec",
            "aac"
        );
    } else {
        mlt_properties_set_int(
            properties,
            "an",
            1
        );
    }
}

static void export_configure_wav_audio_consumer(
    mlt_properties properties,
    mlt_producer source_producer)
{
    /*
     * POC 9.4 uses one dependable professional interchange preset:
     * uncompressed 24-bit PCM in a WAV container. MLT renders 32-bit integer
     * samples internally because it has no 24-bit render-buffer format;
     * FFmpeg's pcm_s24le encoder writes the final 24-bit samples.
     */
    mlt_properties_set(properties, "f", "wav");
    mlt_properties_set(properties, "acodec", "pcm_s24le");
    mlt_properties_set(properties, "mlt_audio_format", "s32le");
    mlt_properties_set_int(properties, "vn", 1);

    /*
     * Preserve the selected source stream's sample rate and channel count
     * when avformat exposes them. Otherwise leave MLT's consumer defaults
     * alone rather than inventing metadata.
     */
    if (source_producer != NULL) {
        mlt_properties source_properties =
            MLT_PRODUCER_PROPERTIES(source_producer);

        const char *audio_index_value =
            mlt_properties_get(
                source_properties,
                "audio_index"
            );

        if (audio_index_value != NULL) {
            const int audio_index =
                mlt_properties_get_int(
                    source_properties,
                    "audio_index"
                );

            if (audio_index >= 0) {
                char key[128];

                snprintf(
                    key,
                    sizeof(key),
                    "meta.media.%d.codec.sample_rate",
                    audio_index
                );

                if (mlt_properties_get(source_properties, key) != NULL) {
                    const int sample_rate =
                        mlt_properties_get_int(
                            source_properties,
                            key
                        );

                    if (sample_rate > 0) {
                        mlt_properties_set_int(
                            properties,
                            "frequency",
                            sample_rate
                        );
                    }
                }

                snprintf(
                    key,
                    sizeof(key),
                    "meta.media.%d.codec.channels",
                    audio_index
                );

                if (mlt_properties_get(source_properties, key) != NULL) {
                    const int channels =
                        mlt_properties_get_int(
                            source_properties,
                            key
                        );

                    if (channels > 0) {
                        mlt_properties_set_int(
                            properties,
                            "channels",
                            channels
                        );
                    }
                }
            }
        }
    }
}

static void export_configure_png_common(
    mlt_properties properties)
{
    /*
     * PNG exports are rendered from the source graph, not copied from
     * Flutter's display texture. Their consumer profile converts anamorphic
     * storage pixels to display-correct square pixels. RGBA preserves
     * source alpha when the decoder provides it.
     */
    mlt_properties_set(properties, "f", "image2");
    mlt_properties_set(properties, "vcodec", "png");
    mlt_properties_set(properties, "pix_fmt", "rgba");
    mlt_properties_set_int(properties, "an", 1);
    mlt_properties_set(properties, "mlt_image_format", "rgba");

    /* Match the progressive frame the viewer presents. */
    mlt_properties_set(properties, "rescale", "lanczos");
    mlt_properties_set(properties, "deinterlacer", MLT_BRIDGE_DEINTERLACER);
    mlt_properties_set_int(properties, "top_field_first", -1);
    mlt_properties_set_int(properties, "progressive", 1);
}

static void export_configure_png_frame_consumer(
    mlt_properties properties)
{
    export_configure_png_common(properties);

    /*
     * A frame export is one literal file, never an image2 filename pattern.
     */
    mlt_properties_set_int(properties, "update", 1);
}

static void export_configure_png_sequence_consumer(
    mlt_properties properties)
{
    export_configure_png_common(properties);

    /*
     * Image2 expands frame_%06d.png into a one-based sequence. Keep update
     * disabled so every source frame becomes a separate PNG.
     */
    mlt_properties_set_int(properties, "update", 0);
    mlt_properties_set_int(properties, "start_number", 1);
}

static int export_configure_consumer(
    ExportKind kind,
    mlt_properties properties,
    mlt_producer source_producer,
    char *failure,
    size_t failure_size)
{
    switch (kind) {
        case EXPORT_KIND_MP4:
            export_configure_mp4_consumer(
                properties,
                source_producer
            );
            break;

        case EXPORT_KIND_PNG_FRAME:
            export_configure_png_frame_consumer(properties);
            break;

        case EXPORT_KIND_PNG_SEQUENCE:
            export_configure_png_sequence_consumer(properties);
            break;

        case EXPORT_KIND_WAV_AUDIO:
            export_configure_wav_audio_consumer(
                properties,
                source_producer
            );
            break;

        default:
            export_set_failure(
                failure,
                failure_size,
                "The requested export type is unsupported."
            );
            return 0;
    }

    /* Export never drops frames. */
    mlt_properties_set_int(properties, "real_time", -1);
    mlt_properties_set_int(properties, "terminate_on_pause", 1);

    return 1;
}

static int export_sequence_outputs_complete(
    const char *directory,
    int64_t expected_frames)
{
    if (directory == NULL ||
        directory[0] == '\0' ||
        expected_frames <= 0) {
        return 0;
    }

    GDir *dir =
        g_dir_open(directory, 0, NULL);

    if (dir == NULL) {
        return 0;
    }

    int64_t owned_count = 0;
    int64_t minimum_frame = G_MAXINT64;
    int64_t maximum_frame = 0;
    int all_have_data = 1;

    const char *name = NULL;

    while ((name = g_dir_read_name(dir)) != NULL) {
        const int64_t frame_number =
            export_sequence_frame_number(name);

        if (frame_number <= 0) {
            continue;
        }

        owned_count += 1;

        if (frame_number < minimum_frame) {
            minimum_frame = frame_number;
        }

        if (frame_number > maximum_frame) {
            maximum_frame = frame_number;
        }

        char *path =
            g_build_filename(
                directory,
                name,
                NULL
            );

        if (path == NULL ||
            !output_file_has_data(path)) {
            all_have_data = 0;
        }

        g_free(path);
    }

    g_dir_close(dir);

    /*
     * Filenames are unique directory entries. If N owned files exist and
     * their minimum and maximum indices are 1 and N, there can be no gap.
     */
    return all_have_data &&
           owned_count == expected_frames &&
           minimum_frame == 1 &&
           maximum_frame == expected_frames;
}

static int export_output_completed(
    const ExportJob *job,
    mlt_producer source_producer,
    int64_t total_frames,
    char *failure,
    size_t failure_size)
{
    switch (job->kind) {
        case EXPORT_KIND_PNG_FRAME:
            /*
             * A one-frame producer has no meaningful terminal-position check:
             * frame zero is both its start and end. The output file itself is
             * the useful completion signal for this export kind.
             */
            if (output_file_has_data(job->output_path)) {
                return 1;
            }

            export_set_failure(
                failure,
                failure_size,
                "MLT did not write the requested PNG frame."
            );
            return 0;

        case EXPORT_KIND_PNG_SEQUENCE: {
            const int64_t final_position =
                (int64_t)mlt_producer_position(source_producer);

            if (final_position >= total_frames - 1 &&
                export_sequence_outputs_complete(
                    job->output_path,
                    total_frames)) {
                return 1;
            }

            export_set_failure(
                failure,
                failure_size,
                "MLT image-sequence export stopped before every frame completed."
            );
            return 0;
        }

        case EXPORT_KIND_WAV_AUDIO:
        case EXPORT_KIND_MP4: {
            const int64_t final_position =
                (int64_t)mlt_producer_position(source_producer);

            if (final_position >= total_frames - 1 &&
                output_file_has_data(job->output_path)) {
                return 1;
            }

            export_set_failure(
                failure,
                failure_size,
                "MLT export stopped before the requested range completed."
            );
            return 0;
        }

        default:
            export_set_failure(
                failure,
                failure_size,
                "The requested export type is unsupported."
            );
            return 0;
    }
}

static gpointer export_worker(gpointer data)
{
    ExportJob *job = (ExportJob *)data;

    mlt_profile export_profile = NULL;
    mlt_profile owned_consumer_profile = NULL;
    mlt_profile consumer_profile = NULL;
    mlt_producer export_producer = NULL;
    mlt_consumer export_consumer = NULL;

    char *owned_consumer_target = NULL;
    const char *consumer_target = NULL;

    int64_t in_frame = 0;
    int64_t out_frame = -1;

    int succeeded = 0;
    int cancelled = 0;
    int destination_prepared = 0;
    char failure[512] = "";

    if (!export_prepare_source_graph(
            job,
            &export_profile,
            &export_producer,
            &in_frame,
            &out_frame,
            failure,
            sizeof(failure))) {
        goto cleanup;
    }

    if (!export_prepare_consumer_profile(
            job->kind,
            export_profile,
            &owned_consumer_profile,
            &consumer_profile,
            failure,
            sizeof(failure))) {
        goto cleanup;
    }

    if (job->kind == EXPORT_KIND_PNG_SEQUENCE) {
        owned_consumer_target =
            export_sequence_consumer_target(
                job->output_path
            );

        if (owned_consumer_target == NULL) {
            export_set_failure(
                failure,
                sizeof(failure),
                "Could not build the image-sequence filename pattern."
            );
            goto cleanup;
        }

        consumer_target = owned_consumer_target;
    } else {
        consumer_target = job->output_path;
    }

    export_consumer =
        mlt_factory_consumer(
            consumer_profile,
            "avformat",
            consumer_target
        );

    if (export_consumer == NULL) {
        export_set_failure(
            failure,
            sizeof(failure),
            "MLT avformat export consumer is unavailable."
        );
        goto cleanup;
    }

    mlt_properties properties =
        MLT_CONSUMER_PROPERTIES(export_consumer);

    if (!export_configure_consumer(
            job->kind,
            properties,
            export_producer,
            failure,
            sizeof(failure))) {
        goto cleanup;
    }

    if (mlt_consumer_connect(
            export_consumer,
            MLT_PRODUCER_SERVICE(export_producer)) != 0) {
        export_set_failure(
            failure,
            sizeof(failure),
            "MLT could not connect the export consumer."
        );
        goto cleanup;
    }

    if (!export_prepare_destination(
            job,
            failure,
            sizeof(failure))) {
        goto cleanup;
    }

    destination_prepared = 1;

    if (mlt_consumer_start(export_consumer) != 0) {
        export_set_failure(
            failure,
            sizeof(failure),
            "MLT could not start the export encoder."
        );
        goto cleanup;
    }

    const int64_t total_frames =
        out_frame - in_frame + 1;

    while (!mlt_consumer_is_stopped(export_consumer)) {
        if (export_cancel_was_requested()) {
            cancelled = 1;
            mlt_consumer_stop(export_consumer);
            break;
        }

        const int64_t position =
            (int64_t)mlt_producer_position(export_producer);

        const double progress =
            total_frames > 0
                ? ((double)(position + 1) / (double)total_frames)
                : 0.0;

        export_publish_progress(progress);

        g_usleep(50000);
    }

    /*
     * Even if the consumer stopped itself at EOF, stop() joins its worker
     * threads and flushes the muxer trailer.
     */
    mlt_consumer_stop(export_consumer);

    if (export_cancel_was_requested()) {
        cancelled = 1;
    }

    if (!cancelled &&
        export_output_completed(
            job,
            export_producer,
            total_frames,
            failure,
            sizeof(failure))) {
        succeeded = 1;
        export_publish_progress(1.0);
    }

cleanup:
    if (export_consumer != NULL) {
        if (!mlt_consumer_is_stopped(export_consumer)) {
            mlt_consumer_stop(export_consumer);
        }
        mlt_consumer_close(export_consumer);
        export_consumer = NULL;
    }

    if (export_producer != NULL) {
        mlt_producer_close(export_producer);
        export_producer = NULL;
    }

    if (owned_consumer_profile != NULL) {
        mlt_profile_close(owned_consumer_profile);
        owned_consumer_profile = NULL;
    }

    if (export_profile != NULL) {
        mlt_profile_close(export_profile);
        export_profile = NULL;
    }

    g_free(owned_consumer_target);
    owned_consumer_target = NULL;

    if (!succeeded &&
        destination_prepared) {
        export_remove_partial_output(job);
    }

    ensure_locks();

    g_mutex_lock(&export_mutex);

    export_running = 0;
    export_success = succeeded;

    if (cancelled) {
        export_set_error_locked("Export cancelled.");
    } else if (succeeded) {
        export_set_error_locked(NULL);
    } else if (failure[0] != '\0') {
        export_set_error_locked(failure);
    } else {
        export_set_error_locked("Export failed.");
    }

    g_mutex_unlock(&export_mutex);

    export_job_free(job);

    return NULL;
}

/*
 * Join a completed export worker so its GThread handle never leaks. This is
 * intentionally never called while export_mutex is held.
 */
static void join_finished_export_thread(void)
{
    ensure_locks();

    GThread *thread = NULL;

    g_mutex_lock(&export_mutex);

    if (!export_running &&
        export_thread != NULL) {
        thread = export_thread;
        export_thread = NULL;
    }

    g_mutex_unlock(&export_mutex);

    if (thread != NULL) {
        g_thread_join(thread);
    }
}

static void cancel_export_and_join(void)
{
    ensure_locks();

    GThread *thread = NULL;

    g_mutex_lock(&export_mutex);

    if (export_thread != NULL) {
        export_cancel_requested = 1;
        thread = export_thread;
        export_thread = NULL;
    }

    g_mutex_unlock(&export_mutex);

    if (thread != NULL) {
        g_thread_join(thread);
    }
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

    /*
     * The export worker uses the process-wide MLT factory. It must be fully
     * joined before playback tears that factory down.
     */
    cancel_export_and_join();

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
/* Export                                                                    */
/* ------------------------------------------------------------------------- */

static int start_export_job(
    const char *source_path,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame,
    ExportKind kind)
{
    ensure_locks();

    if (source_path == NULL ||
        source_path[0] == '\0' ||
        output_path == NULL ||
        output_path[0] == '\0' ||
        out_frame < in_frame) {
        g_mutex_lock(&export_mutex);
        export_set_error_locked("Invalid export request.");
        g_mutex_unlock(&export_mutex);

        return 0;
    }

    g_mutex_lock(&engine_mutex);
    const int initialized = repository != NULL;
    g_mutex_unlock(&engine_mutex);

    if (!initialized) {
        g_mutex_lock(&export_mutex);
        export_set_error_locked("MLT is not initialized.");
        g_mutex_unlock(&export_mutex);

        return 0;
    }

    join_finished_export_thread();

    g_mutex_lock(&export_mutex);

    if (export_running ||
        export_thread != NULL) {
        export_set_error_locked("An export is already running.");
        g_mutex_unlock(&export_mutex);

        return 0;
    }

    ExportJob *job =
        g_new0(ExportJob, 1);

    if (job == NULL) {
        export_set_error_locked("Could not allocate the export job.");
        g_mutex_unlock(&export_mutex);

        return 0;
    }

    job->source_path = g_strdup(source_path);
    job->output_path = g_strdup(output_path);
    job->in_frame = in_frame;
    job->out_frame = out_frame;
    job->kind = kind;

    if (job->source_path == NULL ||
        job->output_path == NULL) {
        export_job_free(job);
        export_set_error_locked("Could not copy the export paths.");
        g_mutex_unlock(&export_mutex);

        return 0;
    }

    export_running = 1;
    export_success = 0;
    export_cancel_requested = 0;
    export_progress = 0.0;
    export_set_error_locked(NULL);

    export_thread =
        g_thread_new(
            "mlt-player-export",
            export_worker,
            job
        );

    if (export_thread == NULL) {
        export_running = 0;
        export_job_free(job);
        export_set_error_locked("Could not start the export worker.");
        g_mutex_unlock(&export_mutex);

        return 0;
    }

    g_mutex_unlock(&export_mutex);

    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_start(
    const char *source_path,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame)
{
    return start_export_job(
        source_path,
        output_path,
        in_frame,
        out_frame,
        EXPORT_KIND_MP4
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_frame_start(
    const char *source_path,
    const char *output_path,
    int64_t frame)
{
    return start_export_job(
        source_path,
        output_path,
        frame,
        frame,
        EXPORT_KIND_PNG_FRAME
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_png_sequence_start(
    const char *source_path,
    const char *output_directory,
    int64_t in_frame,
    int64_t out_frame)
{
    return start_export_job(
        source_path,
        output_directory,
        in_frame,
        out_frame,
        EXPORT_KIND_PNG_SEQUENCE
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_audio_start(
    const char *source_path,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame)
{
    return start_export_job(
        source_path,
        output_path,
        in_frame,
        out_frame,
        EXPORT_KIND_WAV_AUDIO
    );
}

MLT_BRIDGE_EXPORT
void mlt_bridge_export_cancel(void)
{
    ensure_locks();

    g_mutex_lock(&export_mutex);

    if (export_running) {
        export_cancel_requested = 1;
    }

    g_mutex_unlock(&export_mutex);
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_is_running(void)
{
    ensure_locks();

    g_mutex_lock(&export_mutex);
    const int result = export_running;
    g_mutex_unlock(&export_mutex);

    if (!result) {
        join_finished_export_thread();
    }

    return result;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_export_progress(void)
{
    ensure_locks();

    g_mutex_lock(&export_mutex);
    const double result = export_progress;
    g_mutex_unlock(&export_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_succeeded(void)
{
    ensure_locks();

    g_mutex_lock(&export_mutex);
    const int result = !export_running && export_success;
    g_mutex_unlock(&export_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_export_error(void)
{
    ensure_locks();

    g_mutex_lock(&export_mutex);
    const char *result = export_error;
    g_mutex_unlock(&export_mutex);

    return result;
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

    /*
     * Capture the read-only stream topology and codec labels exposed by
     * avformat. video_index and audio_index are absolute container stream
     * indices, which is exactly what the inspector should report.
     */
    stream_count = 0;
    selected_video_stream_index = -1;
    selected_audio_stream_index = -1;

    video_codec_name[0] = '\0';
    video_codec_long_name[0] = '\0';
    audio_codec_name[0] = '\0';
    audio_codec_long_name[0] = '\0';

    video_pixel_format[0] = '\0';
    video_colorspace = -1;
    video_color_trc = -1;
    video_color_range[0] = '\0';

    if (!is_still) {
        if (mlt_properties_get(
                producer_properties,
                "meta.media.nb_streams") != NULL) {
            stream_count =
                mlt_properties_get_int(
                    producer_properties,
                    "meta.media.nb_streams"
                );
        }

        if (mlt_properties_get(
                producer_properties,
                "video_index") != NULL) {
            selected_video_stream_index =
                mlt_properties_get_int(
                    producer_properties,
                    "video_index"
                );
        }

        if (mlt_properties_get(
                producer_properties,
                "audio_index") != NULL) {
            selected_audio_stream_index =
                mlt_properties_get_int(
                    producer_properties,
                    "audio_index"
                );
        }

        read_codec_metadata_locked(
            producer_properties,
            selected_video_stream_index,
            video_codec_name,
            sizeof(video_codec_name),
            video_codec_long_name,
            sizeof(video_codec_long_name)
        );

        read_video_color_metadata_locked(
            producer_properties,
            selected_video_stream_index
        );

        read_codec_metadata_locked(
            producer_properties,
            selected_audio_stream_index,
            audio_codec_name,
            sizeof(audio_codec_name),
            audio_codec_long_name,
            sizeof(audio_codec_long_name)
        );

        read_stream_inspection_locked(producer_properties);
    }

    /*
     * avformat passes FFmpeg metadata through as meta.attr.*.markup.
     * Prefer the selected video stream's timecode, then the container tag,
     * then any stream-level timecode if the selected stream has none.
     */
    source_timecode[0] = '\0';

    const char *timecode = NULL;

    if (!is_still) {
        const int video_index =
            mlt_properties_get_int(
                producer_properties,
                "video_index"
            );

        if (video_index >= 0) {
            char key[128];

            snprintf(
                key,
                sizeof(key),
                "meta.attr.%d.stream.timecode.markup",
                video_index
            );

            timecode =
                mlt_properties_get(
                    producer_properties,
                    key
                );
        }

        if (timecode == NULL ||
            timecode[0] == '\0') {
            timecode =
                mlt_properties_get(
                    producer_properties,
                    "meta.attr.timecode.markup"
                );
        }

        if (timecode == NULL ||
            timecode[0] == '\0') {
            const int timecode_scan_stream_count =
                mlt_properties_get_int(
                    producer_properties,
                    "meta.media.nb_streams"
                );

            for (int index = 0;
                 index < timecode_scan_stream_count;
                 index++) {
                char key[128];

                snprintf(
                    key,
                    sizeof(key),
                    "meta.attr.%d.stream.timecode.markup",
                    index
                );

                const char *candidate =
                    mlt_properties_get(
                        producer_properties,
                        key
                    );

                if (candidate != NULL &&
                    candidate[0] != '\0') {
                    timecode = candidate;
                    break;
                }
            }
        }
    }

    if (timecode != NULL &&
        timecode[0] != '\0') {
        snprintf(
            source_timecode,
            sizeof(source_timecode),
            "%s",
            timecode
        );
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

MLT_BRIDGE_EXPORT
int mlt_bridge_set_play_all_frames(
    int enabled)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const int requested = enabled != 0;
    const int previous_requested = requested_play_all_frames;

    if (requested == previous_requested) {
        g_mutex_unlock(&engine_mutex);

        return 1;
    }

    requested_play_all_frames = requested;

    /*
     * MLT copies real_time into consumer-private state when the consumer
     * starts, so changing the property on a running consumer is not enough.
     * Rebuild only the consumer, preserving the viewer-visible frame and the
     * producer's current shuttle speed.
     */
    if (producer != NULL && consumer != NULL) {
        const double speed =
            mlt_producer_get_speed(producer);

        const mlt_position length =
            mlt_producer_get_length(producer);

        mlt_position position =
            mlt_producer_position(producer);

        if (!mlt_consumer_is_stopped(consumer) &&
            speed != 0.0) {
            position =
                mlt_consumer_position(consumer);

            if (speed > 0.0) {
                position += 1;
            } else {
                position -= 1;
            }
        }

        if (position < 0) {
            position = 0;
        }

        if (length > 0 &&
            position >= length) {
            position = length - 1;
        }

        mlt_producer_set_speed(producer, 0.0);
        close_consumer_locked();
        mlt_producer_seek(producer, position);

        if (!create_consumer_locked()) {
            requested_play_all_frames = previous_requested;

            g_mutex_unlock(&engine_mutex);

            invalidate_frames();

            return 0;
        }

        mlt_producer_set_speed(producer, speed);

        if (mlt_consumer_start(consumer) != 0) {
            set_error(
                "MLT could not restart playback "
                "after changing Play All Frames."
            );

            close_consumer_locked();
            requested_play_all_frames = previous_requested;

            g_mutex_unlock(&engine_mutex);

            invalidate_frames();

            return 0;
        }

        refresh_locked();
        set_error(NULL);
    }

    g_mutex_unlock(&engine_mutex);

    invalidate_frames();

    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_play_all_frames(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const int enabled =
        requested_play_all_frames;

    g_mutex_unlock(&engine_mutex);

    return enabled;
}

/* ------------------------------------------------------------------------- */
/* Transport                                                                 */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT
int mlt_bridge_set_speed(
    double speed)
{
    if (speed == 0.0) {
        return mlt_bridge_pause();
    }

    ensure_locks();

    g_mutex_lock(&engine_mutex);

    if (producer == NULL || is_still) {
        set_error("No timed media is loaded.");

        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    if (!create_consumer_locked()) {
        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    const double current_speed =
        mlt_producer_get_speed(producer);

    const mlt_position length =
        mlt_producer_get_length(producer);

    mlt_position position =
        mlt_producer_position(producer);

    int repositioned = 0;

    /*
     * The producer can be several frames ahead of what the consumer has
     * actually shown. When shuttle speed changes, anchor the producer to
     * the visible position before changing direction or magnitude. This
     * avoids a small but very noticeable jump when tapping J or L.
     */
    if (consumer != NULL &&
        !mlt_consumer_is_stopped(consumer) &&
        current_speed != 0.0) {
        position =
            mlt_consumer_position(consumer);

        if (current_speed > 0.0) {
            position += 1;
        } else {
            position -= 1;
        }

        if (position < 0) {
            position = 0;
        }

        if (length > 0 &&
            position >= length) {
            position = length - 1;
        }

        mlt_consumer_purge(consumer);
        mlt_producer_seek(producer, position);

        repositioned = 1;
    }

    if (speed > 0.0 &&
        length > 0 &&
        position >= length - 1) {
        mlt_consumer_purge(consumer);
        mlt_producer_seek(producer, 0);

        repositioned = 1;
    } else if (speed < 0.0 &&
               length > 0 &&
               position <= 0) {
        mlt_consumer_purge(consumer);
        mlt_producer_seek(producer, length - 1);

        repositioned = 1;
    }

    mlt_producer_set_speed(producer, speed);

    if (!ensure_consumer_running_locked()) {
        g_mutex_unlock(&engine_mutex);

        return 0;
    }

    refresh_locked();

    set_error(NULL);

    g_mutex_unlock(&engine_mutex);

    if (repositioned) {
        invalidate_frames();
    }

    return 1;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_speed(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const double speed =
        producer != NULL &&
        consumer != NULL &&
        !mlt_consumer_is_stopped(consumer)
            ? mlt_producer_get_speed(producer)
            : 0.0;

    g_mutex_unlock(&engine_mutex);

    return speed;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_play(void)
{
    return mlt_bridge_set_speed(1.0);
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
     * parked position is the next frame in the direction we were moving.
     */
    const double speed =
        mlt_producer_get_speed(producer);

    mlt_position position =
        mlt_consumer_position(consumer);

    if (speed > 0.0) {
        position += 1;
    } else if (speed < 0.0) {
        position -= 1;
    }

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
int mlt_bridge_stream_count(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const int result = producer != NULL ? stream_count : 0;
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_video_stream_index(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const int result =
        producer != NULL ? selected_video_stream_index : -1;
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_audio_stream_index(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const int result =
        producer != NULL ? selected_audio_stream_index : -1;
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_video_codec_name(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const char *result = producer != NULL ? video_codec_name : "";
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_video_codec_long_name(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const char *result = producer != NULL ? video_codec_long_name : "";
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_audio_codec_name(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const char *result = producer != NULL ? audio_codec_name : "";
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_audio_codec_long_name(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const char *result = producer != NULL ? audio_codec_long_name : "";
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_stream_type(int index)
{
    ensure_locks();
    g_mutex_lock(&engine_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const char *result = info != NULL ? info->type : "";
    g_mutex_unlock(&engine_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_stream_codec_name(int index)
{
    ensure_locks();
    g_mutex_lock(&engine_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const char *result = info != NULL ? info->codec_name : "";
    g_mutex_unlock(&engine_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_stream_codec_long_name(int index)
{
    ensure_locks();
    g_mutex_lock(&engine_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const char *result = info != NULL ? info->codec_long_name : "";
    g_mutex_unlock(&engine_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_stream_language(int index)
{
    ensure_locks();
    g_mutex_lock(&engine_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const char *result = info != NULL ? info->language : "";
    g_mutex_unlock(&engine_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_channels(int index)
{
    ensure_locks();
    g_mutex_lock(&engine_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int result = info != NULL ? info->channels : 0;
    g_mutex_unlock(&engine_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_sample_rate(int index)
{
    ensure_locks();
    g_mutex_lock(&engine_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int result = info != NULL ? info->sample_rate : 0;
    g_mutex_unlock(&engine_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_width(int index)
{
    ensure_locks();
    g_mutex_lock(&engine_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int result = info != NULL ? info->width : 0;
    g_mutex_unlock(&engine_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_height(int index)
{
    ensure_locks();
    g_mutex_lock(&engine_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int result = info != NULL ? info->height : 0;
    g_mutex_unlock(&engine_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_stream_bit_rate(int index)
{
    ensure_locks();
    g_mutex_lock(&engine_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int64_t result = info != NULL ? info->bit_rate : 0;
    g_mutex_unlock(&engine_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_video_pixel_format(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const char *result = producer != NULL ? video_pixel_format : "";
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_video_colorspace(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const int result = producer != NULL ? video_colorspace : -1;
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_video_color_trc(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const int result = producer != NULL ? video_color_trc : -1;
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_video_color_range(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);
    const char *result = producer != NULL ? video_color_range : "";
    g_mutex_unlock(&engine_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_source_timecode(void)
{
    ensure_locks();

    g_mutex_lock(&engine_mutex);

    const char *result =
        producer != NULL
            ? source_timecode
            : "";

    g_mutex_unlock(&engine_mutex);

    return result;
}

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
