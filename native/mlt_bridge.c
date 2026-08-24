/* native/mlt_bridge.c */

#include "mlt_bridge.h"
#include "mlt_composition.h"
#include "mlt_export.h"
#include "mlt_parity.h"
#include "mlt_layer_api.h"

#include <flutter_linux/flutter_linux.h>
#include <epoxy/gl.h>
#include <framework/mlt.h>
#include <glib.h>

#include <float.h>
#include <limits.h>
#include <math.h>
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

typedef struct _FrameSlot {
    uint8_t *data;
    size_t capacity;
    int width;
    int height;
} FrameSlot;

struct _MltBridgeEngine {
    GMutex e_mutex;

    mlt_profile e_profile;
    mlt_producer e_producer;
    mlt_consumer e_consumer;

    /*
     * POC 10.3 keeps source ownership separate from the top-level producer.
     * e_producer is what transport/preview sees: the primary producer for a
     * one-track movie, or the tractor producer after Add to Movie.
     */
    mlt_producer e_primary_producer;
    mlt_producer e_secondary_producer;
    mlt_playlist e_secondary_playlist;
    mlt_producer e_tertiary_producer;
    mlt_playlist e_tertiary_playlist;
    mlt_tractor e_tractor;
    mlt_transition e_video_composite;
    mlt_transition e_audio_mix;
    mlt_transition e_tertiary_video_composite;
    mlt_transition e_tertiary_audio_mix;

    /*
     * Track-local audio gain is applied before the tractor's A+B mix.
     * The filter pointers are borrowed references owned by their producers.
     */
    mlt_filter e_track_audio_filters[MLT_COMPOSITION_MAX_LAYERS];
    double e_track_audio_gain[MLT_COMPOSITION_MAX_LAYERS];
    int e_track_has_audio[MLT_COMPOSITION_MAX_LAYERS];

    /* POC 10.6: layer-2 alpha interpretation and still-overlay state. */
    mlt_filter e_secondary_alpha_filter;
    int e_secondary_has_alpha;
    int e_secondary_alpha_mode;
    int e_secondary_is_still;

    mlt_filter e_tertiary_alpha_filter;
    int e_tertiary_has_alpha;
    int e_tertiary_alpha_mode;
    int e_tertiary_is_still;

    int e_track_count;
    int64_t e_secondary_start_frame;
    int64_t e_secondary_source_in_frame;
    int64_t e_secondary_source_out_frame;
    int64_t e_secondary_source_length_frames;
    double e_secondary_opacity;

    /* POC 10.8: Layer 2 presentation geometry in base-frame pixels. */
    double e_secondary_x;
    double e_secondary_y;
    double e_secondary_scale;
    double e_secondary_base_width;
    double e_secondary_base_height;

    int64_t e_tertiary_start_frame;
    int64_t e_tertiary_source_in_frame;
    int64_t e_tertiary_source_out_frame;
    int64_t e_tertiary_source_length_frames;
    double e_tertiary_opacity;
    double e_tertiary_x;
    double e_tertiary_y;
    double e_tertiary_scale;
    double e_tertiary_base_width;
    double e_tertiary_base_height;

    int e_has_video;
    int e_has_audio;
    int e_is_still;

    double e_requested_volume;
    int e_requested_play_all_frames;
    gint e_preview_enabled;

    /*
     * UI composition restores can rebuild a tractor in several native steps.
     * While this depth is non-zero, keep the last uploaded Flutter texture
     * visible and discard intermediate consumer frames. The final end call
     * requests one refresh from the fully configured graph.
     */
    gint e_preview_update_depth;

    int e_stream_count;
    int e_selected_video_stream_index;
    int e_selected_audio_stream_index;

    char e_video_codec_name[128];
    char e_video_codec_long_name[256];
    char e_audio_codec_name[128];
    char e_audio_codec_long_name[256];

    char e_video_pixel_format[128];
    int e_video_colorspace;
    int e_video_color_trc;
    char e_video_color_range[32];

    StreamInspection *e_stream_inspection;
    int e_stream_inspection_count;

    char e_last_error[512];
    char e_source_timecode[128];

    /* Published for the MLT frame callback without taking e_mutex. */
    gint e_target_width;
    gint e_target_height;

    GMutex e_frame_mutex;
    GCond e_frame_idle_cond;
    int e_active_frame_readers;

    FrameSlot e_slots[MLT_BRIDGE_SLOT_COUNT];
    int e_slot_write;
    int e_slot_ready;
    int e_slot_display;
    int e_slot_ready_valid;
    int64_t e_last_frame_position;
};

/*
 * The public C ABI keeps the existing operation names while engine ownership
 * becomes explicit through an opaque handle. Each calling thread activates
 * the handle it is about to use. This keeps the hot-path code compact and,
 * because GPrivate is thread-local, allows different engines to be driven on
 * different threads without reintroducing process-global playback state.
 */
static GPrivate current_engine_key = G_PRIVATE_INIT(NULL);

static MltBridgeEngine *current_engine(void)
{
    return (MltBridgeEngine *)g_private_get(&current_engine_key);
}

static void activate_engine_local(MltBridgeEngine *engine)
{
    g_private_set(&current_engine_key, engine);
}

/*
 * Playback state is accessed explicitly through the thread-local active
 * engine. Keeping the field names visible avoids the old macro alias layer,
 * which obscured ownership and could collide with unrelated identifiers.
 */

/* ------------------------------------------------------------------------- */
/* Process-wide state                                                        */
/* ------------------------------------------------------------------------- */

static GMutex factory_mutex;
static mlt_repository repository = NULL;
static int engine_count = 0;
static int factory_shutdown_requested = 0;
static char init_error[512] = "";

/* ------------------------------------------------------------------------- */
/* Flutter texture state                                                     */
/* ------------------------------------------------------------------------- */

/*
 * The Flutter registrar and GL texture are process-wide because the Linux
 * runner owns one Flutter view. texture_engine identifies which opaque engine
 * currently feeds that view; switching it does not move playback state back
 * to globals.
 */
static GMutex texture_mutex;
static FlTextureRegistrar *texture_registrar = NULL;
static MltBridgeEngine *texture_engine = NULL;
static GArray *retired_gl_textures = NULL;
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
        g_mutex_init(&factory_mutex);
        g_mutex_init(&texture_mutex);
        retired_gl_textures =
            g_array_new(FALSE, FALSE, sizeof(GLuint));

        g_once_init_leave(&locks_initialized, 1);
    }
}

/*
 * Public playback/media operations require a thread-local active engine.
 * Returning a neutral value is safer than dereferencing NULL when a caller
 * races teardown, uses a stale Dart wrapper, or invokes an operation after
 * destroying its engine. last_error_copy() intentionally remains usable with
 * no active engine and reports this process-level error.
 */
static MltBridgeEngine *require_current_engine(void)
{
    ensure_locks();

    MltBridgeEngine *engine =
        current_engine();

    if (engine != NULL) {
        return engine;
    }

    g_mutex_lock(&factory_mutex);

    snprintf(
        init_error,
        sizeof(init_error),
        "%s",
        "No active MLT engine."
    );

    g_mutex_unlock(&factory_mutex);

    return NULL;
}

/* ------------------------------------------------------------------------- */
/* Errors                                                                    */
/* ------------------------------------------------------------------------- */

/* Call with engine_mutex held. */
static void set_error(
    const char *message)
{
    if (message == NULL) {
        current_engine()->e_last_error[0] = '\0';
        return;
    }

    snprintf(
        current_engine()->e_last_error,
        sizeof(current_engine()->e_last_error),
        "%s",
        message
    );
}

/*
 * Copy a UTF-8 string into caller-owned storage. The return value is the
 * required capacity including the trailing NUL. Passing NULL/0 therefore
 * performs a size query without exposing bridge-owned storage.
 */
static int copy_string_value(
    const char *value,
    char *buffer,
    int capacity)
{
    const char *source = value != NULL ? value : "";
    const size_t length = strlen(source);

    if (length >= (size_t)INT_MAX) {
        return 0;
    }

    const int required = (int)length + 1;

    if (buffer == NULL || capacity <= 0) {
        return required;
    }

    const size_t writable =
        capacity > 1 ? (size_t)(capacity - 1) : 0;
    const size_t copy_length =
        length < writable ? length : writable;

    if (copy_length > 0) {
        memcpy(buffer, source, copy_length);
    }

    buffer[copy_length] = '\0';

    return required;
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

    g_mutex_lock(&current_engine()->e_frame_mutex);

    while (current_engine()->e_active_frame_readers > 0) {
        g_cond_wait(
            &current_engine()->e_frame_idle_cond,
            &current_engine()->e_frame_mutex
        );
    }

    for (int index = 0;
         index < MLT_BRIDGE_SLOT_COUNT;
         index++) {
        free(current_engine()->e_slots[index].data);

        current_engine()->e_slots[index].data = NULL;
        current_engine()->e_slots[index].capacity = 0;
        current_engine()->e_slots[index].width = 0;
        current_engine()->e_slots[index].height = 0;
    }

    current_engine()->e_slot_write = 0;
    current_engine()->e_slot_ready = 1;
    current_engine()->e_slot_display = 2;

    current_engine()->e_slot_ready_valid = 0;

    current_engine()->e_last_frame_position = -1;

    g_mutex_unlock(&current_engine()->e_frame_mutex);
}

/*
 * Marks every buffered frame stale without freeing the allocations,
 * so that a seek or a pause forces the next decoded frame to be
 * uploaded even if it carries a position we have already seen.
 */
static void invalidate_frames(void)
{
    ensure_locks();

    g_mutex_lock(&current_engine()->e_frame_mutex);

    current_engine()->e_last_frame_position = -1;

    g_mutex_unlock(&current_engine()->e_frame_mutex);
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
     * Claim the currently selected engine while texture_mutex prevents that
     * engine from being detached and destroyed. Increment its frame-reader
     * count before releasing texture_mutex so engine destruction can safely
     * wait for this raster upload to finish.
     */
    g_mutex_lock(&texture_mutex);

    /*
     * FlTextureGL guarantees that Flutter's GL context is current only while
     * populate() is running. Texture IDs retired by an earlier unregister are
     * therefore deleted here instead of making an unsafe GL call from the GTK
     * teardown thread. This closes the leak across texture re-registration and
     * hot-restart cycles; process exit still lets the driver reclaim the final
     * context-owned resources naturally.
     */
    if (retired_gl_textures != NULL &&
        retired_gl_textures->len > 0) {
        glDeleteTextures(
            (GLsizei)retired_gl_textures->len,
            (const GLuint *)retired_gl_textures->data
        );
        g_array_set_size(retired_gl_textures, 0);
    }

    MltBridgeEngine *engine = texture_engine;

    if (engine == NULL) {
        g_mutex_unlock(&texture_mutex);
        return FALSE;
    }

    activate_engine_local(engine);

    g_mutex_lock(&current_engine()->e_frame_mutex);

    if (current_engine()->e_slot_ready_valid) {
        const int previous_display =
            current_engine()->e_slot_display;

        current_engine()->e_slot_display = current_engine()->e_slot_ready;
        current_engine()->e_slot_ready = previous_display;

        current_engine()->e_slot_ready_valid = 0;
    }

    const int display_index =
        current_engine()->e_slot_display;

    current_engine()->e_active_frame_readers += 1;

    g_mutex_unlock(&current_engine()->e_frame_mutex);
    g_mutex_unlock(&texture_mutex);

    FrameSlot *slot =
        &current_engine()->e_slots[display_index];

    if (slot->data == NULL ||
        slot->width <= 0 ||
        slot->height <= 0) {
        g_mutex_lock(&current_engine()->e_frame_mutex);

        current_engine()->e_active_frame_readers -= 1;

        if (current_engine()->e_active_frame_readers == 0) {
            g_cond_broadcast(&current_engine()->e_frame_idle_cond);
        }

        g_mutex_unlock(&current_engine()->e_frame_mutex);

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

    g_mutex_lock(&current_engine()->e_frame_mutex);

    current_engine()->e_active_frame_readers -= 1;

    if (current_engine()->e_active_frame_readers == 0) {
        g_cond_broadcast(&current_engine()->e_frame_idle_cond);
    }

    g_mutex_unlock(&current_engine()->e_frame_mutex);

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

    MltBridgeEngine *engine =
        (MltBridgeEngine *)listener_data;

    if (engine == NULL) {
        return;
    }

    activate_engine_local(engine);

    mlt_frame frame =
        mlt_event_data_to_frame(
            event_data
        );

    if (frame == NULL) {
        return;
    }

    if (g_atomic_int_get(&engine->e_preview_update_depth) > 0) {
        return;
    }

    const int64_t position =
        (int64_t)mlt_frame_get_position(
            frame
        );

    ensure_locks();

    g_mutex_lock(&current_engine()->e_frame_mutex);

    const int already_have_frame =
        position == current_engine()->e_last_frame_position;

    g_mutex_unlock(&current_engine()->e_frame_mutex);

    if (already_have_frame) {
        return;
    }

    mlt_image_format format =
        mlt_image_rgba;

    uint8_t *image = NULL;

    int width =
        g_atomic_int_get(&current_engine()->e_target_width);

    int height =
        g_atomic_int_get(&current_engine()->e_target_height);

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
        &current_engine()->e_slots[current_engine()->e_slot_write];

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
    g_mutex_lock(&current_engine()->e_frame_mutex);

    const int previous_ready =
        current_engine()->e_slot_ready;

    current_engine()->e_slot_ready = current_engine()->e_slot_write;
    current_engine()->e_slot_write = previous_ready;

    current_engine()->e_slot_ready_valid = 1;

    current_engine()->e_last_frame_position = position;

    g_mutex_unlock(&current_engine()->e_frame_mutex);

    notify_flutter_frame_available();
}

/* Preview-consumer helpers are defined with the producer helpers below. */
static void close_consumer_locked(void);
static int create_consumer_locked(void);
static void refresh_locked(void);

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
     * Detach the engine from the raster thread first. A populate call that
     * already claimed it incremented active_frame_readers while holding
     * texture_mutex, so release_slots() below can wait it out safely.
     */
    g_mutex_lock(&texture_mutex);

    MltBridgeEngine *engine = texture_engine;
    texture_engine = NULL;

    if (engine != NULL) {
        g_atomic_int_set(
            &engine->e_preview_enabled,
            0
        );
    }

    FlTextureRegistrar *local_registrar =
        texture_registrar;

    MltVideoTexture *local_texture =
        video_texture;

    texture_registrar = NULL;
    video_texture = NULL;

    g_mutex_unlock(&texture_mutex);

    if (engine != NULL) {
        activate_engine_local(engine);

        g_mutex_lock(&current_engine()->e_mutex);
        close_consumer_locked();
        g_mutex_unlock(&current_engine()->e_mutex);

        release_slots();
    }

    if (local_registrar != NULL &&
        local_texture != NULL) {
        fl_texture_registrar_unregister_texture(
            local_registrar,
            FL_TEXTURE(local_texture)
        );
    }

    /*
     * No Flutter raster callback can still be using local_texture here:
     * texture_engine was detached before release_slots() waited out existing
     * readers, and the registrar has now removed the external texture. Move
     * the GL name to the deferred-delete queue before releasing the object.
     */
    if (local_texture != NULL) {
        g_mutex_lock(&texture_mutex);

        if (local_texture->gl_texture_id != 0 &&
            retired_gl_textures != NULL) {
            const GLuint retired_id =
                local_texture->gl_texture_id;

            g_array_append_val(
                retired_gl_textures,
                retired_id
            );

            local_texture->gl_texture_id = 0;
            local_texture->uploaded_width = 0;
            local_texture->uploaded_height = 0;
        }

        g_mutex_unlock(&texture_mutex);

        g_object_unref(local_texture);
    }

    if (local_registrar != NULL) {
        g_object_unref(local_registrar);
    }
}

MLT_LAYER_API_EXPORT
int mlt_bridge_preview_update_begin(
    MltBridgeEngine *engine)
{
    if (engine == NULL) {
        return 0;
    }

    int depth = 0;

    do {
        depth = g_atomic_int_get(&engine->e_preview_update_depth);

        if (depth == INT_MAX) {
            return 0;
        }
    } while (!g_atomic_int_compare_and_exchange(
        &engine->e_preview_update_depth,
        depth,
        depth + 1
    ));

    return 1;
}

MLT_LAYER_API_EXPORT
int mlt_bridge_preview_update_end(
    MltBridgeEngine *engine)
{
    if (engine == NULL) {
        return 0;
    }

    activate_engine_local(engine);

    int previous_depth = 0;

    do {
        previous_depth =
            g_atomic_int_get(&engine->e_preview_update_depth);

        if (previous_depth <= 0) {
            return 0;
        }
    } while (!g_atomic_int_compare_and_exchange(
        &engine->e_preview_update_depth,
        previous_depth,
        previous_depth - 1
    ));

    if (previous_depth == 1) {
        ensure_locks();

        g_mutex_lock(&engine->e_mutex);

        invalidate_frames();

        if (g_atomic_int_get(&engine->e_preview_enabled) &&
            engine->e_consumer != NULL) {
            refresh_locked();
        }

        g_mutex_unlock(&engine->e_mutex);
    }

    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_engine_set_texture_source(
    MltBridgeEngine *engine)
{
    if (engine == NULL) {
        return 0;
    }

    ensure_locks();

    MltBridgeEngine *caller_engine =
        current_engine();

    /*
     * MLT 7.22's sdl2_audio consumer calls SDL_QuitSubSystem(SDL_INIT_AUDIO)
     * when it stops. Two live preview consumers are therefore not safely
     * independent: stopping one tears the SDL audio subsystem out from under
     * the other. Opaque engines may coexist, but exactly one engine owns the
     * live preview consumer at a time.
     *
     * Detach the previous texture source first, then stop its consumer before
     * enabling the replacement. This makes the ownership rule enforceable in
     * native code instead of relying on Dart to avoid overlapping consumers.
     */
    g_mutex_lock(&texture_mutex);

    MltBridgeEngine *previous =
        texture_engine;

    if (previous == engine) {
        g_atomic_int_set(
            &engine->e_preview_enabled,
            1
        );
        g_mutex_unlock(&texture_mutex);
        return 1;
    }

    texture_engine = NULL;

    if (previous != NULL) {
        g_atomic_int_set(
            &previous->e_preview_enabled,
            0
        );
    }

    g_mutex_unlock(&texture_mutex);

    if (previous != NULL) {
        activate_engine_local(previous);

        g_mutex_lock(&previous->e_mutex);

        if (previous->e_producer != NULL) {
            mlt_producer_set_speed(
                previous->e_producer,
                0.0
            );
        }

        close_consumer_locked();

        g_mutex_unlock(&previous->e_mutex);

        release_slots();
    }

    g_atomic_int_set(
        &engine->e_preview_enabled,
        1
    );

    g_mutex_lock(&texture_mutex);
    texture_engine = engine;
    g_mutex_unlock(&texture_mutex);

    /*
     * A background engine may already have a producer loaded when it becomes
     * the viewer. Start its preview consumer only after the previous viewer
     * has relinquished SDL audio.
     */
    activate_engine_local(engine);

    g_mutex_lock(&engine->e_mutex);

    int preview_ready = 1;

    if (engine->e_producer != NULL &&
        engine->e_consumer == NULL) {
        preview_ready =
            create_consumer_locked();

        if (preview_ready &&
            mlt_consumer_start(engine->e_consumer) != 0) {
            set_error(
                "MLT could not start the preview consumer."
            );
            close_consumer_locked();
            preview_ready = 0;
        }

        if (preview_ready) {
            refresh_locked();
        }
    }

    g_mutex_unlock(&engine->e_mutex);

    if (!preview_ready) {
        g_mutex_lock(&texture_mutex);
        if (texture_engine == engine) {
            texture_engine = NULL;
        }
        g_mutex_unlock(&texture_mutex);

        g_atomic_int_set(
            &engine->e_preview_enabled,
            0
        );
    }

    if (caller_engine != NULL) {
        activate_engine_local(caller_engine);
    } else if (preview_ready) {
        activate_engine_local(engine);
    } else {
        activate_engine_local(NULL);
    }

    return preview_ready;
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
    if (current_engine()->e_consumer != NULL) {
        mlt_consumer_stop(current_engine()->e_consumer);
        mlt_consumer_close(current_engine()->e_consumer);

        current_engine()->e_consumer = NULL;
    }
}

static void close_producer_locked(void)
{
    close_consumer_locked();

    /*
     * e_producer is a borrowed alias: either e_primary_producer or the
     * tractor's embedded producer. Source and graph objects are closed
     * explicitly below so no object is released twice.
     */
    current_engine()->e_producer = NULL;

    if (current_engine()->e_tractor != NULL) {
        mlt_tractor_close(current_engine()->e_tractor);
        current_engine()->e_tractor = NULL;
    }

    /*
     * The field/tractor graph holds its own references to planted
     * transitions. Our engine retains the factory references so later POC 10
     * slices can mutate opacity/blend properties without searching the graph.
     */
    if (current_engine()->e_video_composite != NULL) {
        mlt_transition_close(current_engine()->e_video_composite);
        current_engine()->e_video_composite = NULL;
    }

    if (current_engine()->e_audio_mix != NULL) {
        mlt_transition_close(current_engine()->e_audio_mix);
        current_engine()->e_audio_mix = NULL;
    }

    if (current_engine()->e_tertiary_video_composite != NULL) {
        mlt_transition_close(current_engine()->e_tertiary_video_composite);
        current_engine()->e_tertiary_video_composite = NULL;
    }

    if (current_engine()->e_tertiary_audio_mix != NULL) {
        mlt_transition_close(current_engine()->e_tertiary_audio_mix);
        current_engine()->e_tertiary_audio_mix = NULL;
    }

    /*
     * These filters are attached to primary_producer and overlay playlists.
     * Drop the borrowed pointers before those producers release the filters.
     */
    current_engine()->e_track_audio_filters[0] = NULL;
    current_engine()->e_track_audio_filters[1] = NULL;
    current_engine()->e_track_audio_filters[2] = NULL;
    current_engine()->e_secondary_alpha_filter = NULL;
    current_engine()->e_tertiary_alpha_filter = NULL;

    if (current_engine()->e_tertiary_playlist != NULL) {
        mlt_playlist_close(current_engine()->e_tertiary_playlist);
        current_engine()->e_tertiary_playlist = NULL;
    }

    if (current_engine()->e_tertiary_producer != NULL) {
        mlt_producer_close(current_engine()->e_tertiary_producer);
        current_engine()->e_tertiary_producer = NULL;
    }

    if (current_engine()->e_secondary_playlist != NULL) {
        mlt_playlist_close(current_engine()->e_secondary_playlist);
        current_engine()->e_secondary_playlist = NULL;
    }

    if (current_engine()->e_secondary_producer != NULL) {
        mlt_producer_close(current_engine()->e_secondary_producer);
        current_engine()->e_secondary_producer = NULL;
    }

    if (current_engine()->e_primary_producer != NULL) {
        mlt_producer_close(current_engine()->e_primary_producer);
        current_engine()->e_primary_producer = NULL;
    }

    current_engine()->e_track_count = 0;
    current_engine()->e_secondary_start_frame = -1;
    current_engine()->e_secondary_source_in_frame = -1;
    current_engine()->e_secondary_source_out_frame = -1;
    current_engine()->e_secondary_source_length_frames = 0;
    current_engine()->e_secondary_opacity = 1.0;
    current_engine()->e_secondary_x = 0.0;
    current_engine()->e_secondary_y = 0.0;
    current_engine()->e_secondary_scale = 1.0;
    current_engine()->e_secondary_base_width = 0.0;
    current_engine()->e_secondary_base_height = 0.0;
    current_engine()->e_secondary_has_alpha = 0;
    current_engine()->e_secondary_alpha_mode = 0;
    current_engine()->e_secondary_is_still = 0;
    current_engine()->e_tertiary_start_frame = -1;
    current_engine()->e_tertiary_source_in_frame = -1;
    current_engine()->e_tertiary_source_out_frame = -1;
    current_engine()->e_tertiary_source_length_frames = 0;
    current_engine()->e_tertiary_opacity = 1.0;
    current_engine()->e_tertiary_x = 0.0;
    current_engine()->e_tertiary_y = 0.0;
    current_engine()->e_tertiary_scale = 1.0;
    current_engine()->e_tertiary_base_width = 0.0;
    current_engine()->e_tertiary_base_height = 0.0;
    current_engine()->e_tertiary_has_alpha = 0;
    current_engine()->e_tertiary_alpha_mode = 0;
    current_engine()->e_tertiary_is_still = 0;

    for (int index = 0; index < MLT_COMPOSITION_MAX_LAYERS; index++) {
        current_engine()->e_track_audio_gain[index] = 1.0;
        current_engine()->e_track_has_audio[index] = 0;
    }

    current_engine()->e_has_video = 0;
    current_engine()->e_has_audio = 0;
    current_engine()->e_is_still = 0;

    current_engine()->e_stream_count = 0;
    current_engine()->e_selected_video_stream_index = -1;
    current_engine()->e_selected_audio_stream_index = -1;

    current_engine()->e_video_codec_name[0] = '\0';
    current_engine()->e_video_codec_long_name[0] = '\0';
    current_engine()->e_audio_codec_name[0] = '\0';
    current_engine()->e_audio_codec_long_name[0] = '\0';

    current_engine()->e_video_pixel_format[0] = '\0';
    current_engine()->e_video_colorspace = -1;
    current_engine()->e_video_color_trc = -1;
    current_engine()->e_video_color_range[0] = '\0';

    free(current_engine()->e_stream_inspection);
    current_engine()->e_stream_inspection = NULL;
    current_engine()->e_stream_inspection_count = 0;

    current_engine()->e_source_timecode[0] = '\0';

    g_atomic_int_set(&current_engine()->e_target_width, 0);
    g_atomic_int_set(&current_engine()->e_target_height, 0);
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


static int path_has_still_image_extension(const char *path)
{
    if (path == NULL) {
        return 0;
    }

    const char *dot = strrchr(path, '.');
    if (dot == NULL) {
        return 0;
    }

    static const char *extensions[] = {
        ".png",
        ".jpg",
        ".jpeg",
        ".webp",
        ".bmp",
        ".tif",
        ".tiff",
        ".exr",
        NULL
    };

    for (int index = 0; extensions[index] != NULL; index++) {
        if (g_ascii_strcasecmp(dot, extensions[index]) == 0) {
            return 1;
        }
    }

    return 0;
}

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

static int producer_has_stream_locked(
    mlt_producer candidate,
    const char *index_property,
    const char *stream_type)
{
    if (candidate == NULL ||
        index_property == NULL ||
        stream_type == NULL) {
        return 0;
    }

    mlt_properties properties =
        MLT_PRODUCER_PROPERTIES(candidate);

    if (mlt_properties_get(
            properties,
            index_property) != NULL) {
        return mlt_properties_get_int(
                   properties,
                   index_property) >= 0;
    }

    /*
     * Some producers omit video_index/audio_index but still publish the
     * absolute stream topology. Prefer that evidence before falling back to
     * the historic "stream may exist" behavior.
     */
    if (mlt_properties_get(
            properties,
            "meta.media.nb_streams") != NULL) {
        const int count =
            mlt_properties_get_int(
                properties,
                "meta.media.nb_streams"
            );

        for (int index = 0; index < count; index++) {
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
                strcmp(type, stream_type) == 0) {
                return 1;
            }
        }

        return 0;
    }

    return 1;
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
    current_engine()->e_video_pixel_format[0] = '\0';
    current_engine()->e_video_colorspace = -1;
    current_engine()->e_video_color_trc = -1;
    current_engine()->e_video_color_range[0] = '\0';

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
            current_engine()->e_video_pixel_format,
            sizeof(current_engine()->e_video_pixel_format),
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
        current_engine()->e_video_colorspace =
            mlt_properties_get_int(properties, key);
    }

    snprintf(
        key,
        sizeof(key),
        "meta.media.%d.codec.color_trc",
        stream_index
    );

    if (mlt_properties_get(properties, key) != NULL) {
        current_engine()->e_video_color_trc =
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
                current_engine()->e_video_color_range,
                sizeof(current_engine()->e_video_color_range),
                "%s",
                "Full"
            );
        } else if (strcmp(value, "limited") == 0 ||
                   strcmp(value, "mpeg") == 0) {
            snprintf(
                current_engine()->e_video_color_range,
                sizeof(current_engine()->e_video_color_range),
                "%s",
                "Limited"
            );
        } else {
            snprintf(
                current_engine()->e_video_color_range,
                sizeof(current_engine()->e_video_color_range),
                "%s",
                value
            );
        }
    } else if (current_engine()->e_video_pixel_format[0] != '\0' &&
               (strncmp(current_engine()->e_video_pixel_format, "yuvj", 4) == 0 ||
                strstr(current_engine()->e_video_pixel_format, "rgb") != NULL ||
                strstr(current_engine()->e_video_pixel_format, "gbr") != NULL)) {
        snprintf(
            current_engine()->e_video_color_range,
            sizeof(current_engine()->e_video_color_range),
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
    free(current_engine()->e_stream_inspection);
    current_engine()->e_stream_inspection = NULL;
    current_engine()->e_stream_inspection_count = 0;

    if (properties == NULL || current_engine()->e_stream_count <= 0) {
        return;
    }

    current_engine()->e_stream_inspection =
        calloc((size_t)current_engine()->e_stream_count, sizeof(StreamInspection));

    if (current_engine()->e_stream_inspection == NULL) {
        return;
    }

    current_engine()->e_stream_inspection_count = current_engine()->e_stream_count;

    for (int inspection_index = 0;
         inspection_index < current_engine()->e_stream_inspection_count;
         inspection_index++) {
        StreamInspection *info = &current_engine()->e_stream_inspection[inspection_index];
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
    if (current_engine()->e_producer == NULL ||
        current_engine()->e_stream_inspection == NULL ||
        index < 0 ||
        index >= current_engine()->e_stream_inspection_count) {
        return NULL;
    }

    return &current_engine()->e_stream_inspection[index];
}

static int create_consumer_locked(void)
{
    if (!g_atomic_int_get(
            &current_engine()->e_preview_enabled)) {
        set_error(
            "This engine is not selected as the preview source."
        );

        return 0;
    }

    if (current_engine()->e_producer == NULL ||
        current_engine()->e_profile == NULL) {
        set_error("No producer is loaded.");

        return 0;
    }

    if (current_engine()->e_consumer != NULL) {
        return 1;
    }

    current_engine()->e_consumer =
        mlt_factory_consumer(
            current_engine()->e_profile,
            "sdl2_audio",
            NULL
        );

    if (current_engine()->e_consumer == NULL) {
        set_error(
            "Could not create the MLT "
            "sdl2_audio consumer."
        );

        return 0;
    }

    mlt_properties properties =
        MLT_CONSUMER_PROPERTIES(current_engine()->e_consumer);

    /*
     * Normal playback is asynchronous and may drop video frames to keep
     * real time. QuickTime-style Play All Frames flips MLT to -1, which
     * disables frame dropping; if rendering cannot keep up, playback slows
     * instead of skipping pictures.
     */
    mlt_properties_set_int(
        properties,
        "real_time",
        current_engine()->e_requested_play_all_frames ? -1 : 1
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
        current_engine()->e_requested_volume
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
        current_engine(),
        "consumer-frame-show",
        (mlt_listener)on_consumer_frame_show
    );

    const int connect_result =
        mlt_consumer_connect(
            current_engine()->e_consumer,
            MLT_PRODUCER_SERVICE(current_engine()->e_producer)
        );

    if (connect_result != 0) {
        mlt_consumer_close(current_engine()->e_consumer);

        current_engine()->e_consumer = NULL;

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
    if (current_engine()->e_consumer == NULL) {
        return 0;
    }

    if (!mlt_consumer_is_stopped(current_engine()->e_consumer)) {
        return 1;
    }

    /*
     * The consumer stops itself at end of file. Stopping again is
     * what joins its threads, and skipping it leaks one thread per
     * replay.
     */
    mlt_consumer_stop(current_engine()->e_consumer);

    if (mlt_consumer_start(current_engine()->e_consumer) != 0) {
        set_error("MLT could not start playback.");

        return 0;
    }

    return 1;
}

static void refresh_locked(void)
{
    if (current_engine()->e_consumer == NULL) {
        return;
    }

    mlt_properties_set_int(
        MLT_CONSUMER_PROPERTIES(current_engine()->e_consumer),
        "refresh",
        1
    );
}


/* ------------------------------------------------------------------------- */
/* Lifecycle                                                                 */
/* ------------------------------------------------------------------------- */

static void set_init_error_locked(const char *message)
{
    if (message == NULL) {
        init_error[0] = '\0';
        return;
    }

    snprintf(
        init_error,
        sizeof(init_error),
        "%s",
        message
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_init(void)
{
    ensure_locks();

    g_mutex_lock(&factory_mutex);

    if (repository != NULL) {
        factory_shutdown_requested = 0;
        set_init_error_locked(NULL);
        g_mutex_unlock(&factory_mutex);
        return 1;
    }

    repository = mlt_factory_init(NULL);

    if (repository == NULL) {
        set_init_error_locked("Failed to initialize MLT.");
        g_mutex_unlock(&factory_mutex);
        return 0;
    }

    factory_shutdown_requested = 0;
    set_init_error_locked(NULL);

    g_mutex_unlock(&factory_mutex);

    return 1;
}

MLT_BRIDGE_EXPORT
MltBridgeEngine *mlt_bridge_engine_create(void)
{
    ensure_locks();

    g_mutex_lock(&factory_mutex);

    if (repository == NULL) {
        set_init_error_locked("MLT is not initialized.");
        g_mutex_unlock(&factory_mutex);
        return NULL;
    }

    MltBridgeEngine *engine =
        g_new0(MltBridgeEngine, 1);

    if (engine == NULL) {
        set_init_error_locked("Could not allocate an MLT engine.");
        g_mutex_unlock(&factory_mutex);
        return NULL;
    }

    g_mutex_init(&engine->e_mutex);
    g_mutex_init(&engine->e_frame_mutex);
    g_cond_init(&engine->e_frame_idle_cond);

    engine->e_requested_volume = 1.0;
    engine->e_secondary_opacity = 1.0;
    engine->e_secondary_x = 0.0;
    engine->e_secondary_y = 0.0;
    engine->e_secondary_scale = 1.0;
    engine->e_secondary_base_width = 0.0;
    engine->e_secondary_base_height = 0.0;
    engine->e_secondary_start_frame = -1;
    engine->e_secondary_source_in_frame = -1;
    engine->e_secondary_source_out_frame = -1;
    engine->e_secondary_source_length_frames = 0;
    engine->e_secondary_has_alpha = 0;
    engine->e_secondary_alpha_mode = 0;
    engine->e_secondary_is_still = 0;
    engine->e_tertiary_opacity = 1.0;
    engine->e_tertiary_x = 0.0;
    engine->e_tertiary_y = 0.0;
    engine->e_tertiary_scale = 1.0;
    engine->e_tertiary_base_width = 0.0;
    engine->e_tertiary_base_height = 0.0;
    engine->e_tertiary_start_frame = -1;
    engine->e_tertiary_source_in_frame = -1;
    engine->e_tertiary_source_out_frame = -1;
    engine->e_tertiary_source_length_frames = 0;
    engine->e_tertiary_has_alpha = 0;
    engine->e_tertiary_alpha_mode = 0;
    engine->e_tertiary_is_still = 0;
    for (int index = 0; index < MLT_COMPOSITION_MAX_LAYERS; index++) {
        engine->e_track_audio_gain[index] = 1.0;
    }
    engine->e_selected_video_stream_index = -1;
    engine->e_selected_audio_stream_index = -1;
    engine->e_video_colorspace = -1;
    engine->e_video_color_trc = -1;
    engine->e_slot_write = 0;
    engine->e_slot_ready = 1;
    engine->e_slot_display = 2;
    engine->e_last_frame_position = -1;

    engine->e_profile = mlt_profile_init(NULL);

    if (engine->e_profile == NULL) {
        g_cond_clear(&engine->e_frame_idle_cond);
        g_mutex_clear(&engine->e_frame_mutex);
        g_mutex_clear(&engine->e_mutex);
        g_free(engine);

        set_init_error_locked("Failed to create the MLT engine profile.");
        g_mutex_unlock(&factory_mutex);
        return NULL;
    }

    engine_count += 1;
    set_init_error_locked(NULL);

    g_mutex_unlock(&factory_mutex);

    return engine;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_engine_activate(
    MltBridgeEngine *engine)
{
    if (engine == NULL) {
        return 0;
    }

    activate_engine_local(engine);
    return 1;
}

MLT_BRIDGE_EXPORT
void mlt_bridge_engine_destroy(
    MltBridgeEngine *engine)
{
    if (engine == NULL) {
        return;
    }

    ensure_locks();

    MltBridgeEngine *caller_engine =
        current_engine();

    /* Prevent any new Flutter raster callback from claiming this engine. */
    g_mutex_lock(&texture_mutex);
    if (texture_engine == engine) {
        texture_engine = NULL;
    }
    g_atomic_int_set(
        &engine->e_preview_enabled,
        0
    );
    g_mutex_unlock(&texture_mutex);

    activate_engine_local(engine);

    g_mutex_lock(&current_engine()->e_mutex);

    close_producer_locked();

    if (current_engine()->e_profile != NULL) {
        mlt_profile_close(current_engine()->e_profile);
        current_engine()->e_profile = NULL;
    }

    g_mutex_unlock(&current_engine()->e_mutex);

    /* Wait for a raster upload that claimed the engine before detachment. */
    release_slots();

    g_cond_clear(&engine->e_frame_idle_cond);
    g_mutex_clear(&engine->e_frame_mutex);
    g_mutex_clear(&engine->e_mutex);

    if (caller_engine != NULL &&
        caller_engine != engine) {
        activate_engine_local(caller_engine);
    } else {
        activate_engine_local(NULL);
    }

    g_free(engine);

    g_mutex_lock(&factory_mutex);

    if (engine_count > 0) {
        engine_count -= 1;
    }

    if (engine_count == 0 &&
        factory_shutdown_requested &&
        repository != NULL) {
        mlt_factory_close();
        repository = NULL;
        factory_shutdown_requested = 0;
    }

    g_mutex_unlock(&factory_mutex);
}

MLT_BRIDGE_EXPORT
const char *mlt_bridge_version(void)
{
    return mlt_version_get_string();
}

MLT_BRIDGE_EXPORT
int mlt_bridge_last_error_copy(
    char *buffer,
    int capacity)
{
    ensure_locks();

    MltBridgeEngine *engine = current_engine();

    if (engine != NULL) {
        g_mutex_lock(&engine->e_mutex);
        const int required =
            copy_string_value(engine->e_last_error, buffer, capacity);
        g_mutex_unlock(&engine->e_mutex);
        return required;
    }

    g_mutex_lock(&factory_mutex);
    const int required =
        copy_string_value(init_error, buffer, capacity);
    g_mutex_unlock(&factory_mutex);

    return required;
}

MLT_BRIDGE_EXPORT
void mlt_bridge_shutdown(void)
{
    ensure_locks();

    /* The background exporter shares the process-wide MLT factory. */
    mlt_export_shutdown();

    g_mutex_lock(&factory_mutex);

    factory_shutdown_requested = 1;

    if (engine_count == 0 &&
        repository != NULL) {
        mlt_factory_close();
        repository = NULL;
        factory_shutdown_requested = 0;
    }

    g_mutex_unlock(&factory_mutex);
}


/* ------------------------------------------------------------------------- */
/* Export                                                                    */
/* ------------------------------------------------------------------------- */

static int export_factory_is_ready(void)
{
    ensure_locks();

    g_mutex_lock(&factory_mutex);
    const int ready = repository != NULL;
    g_mutex_unlock(&factory_mutex);

    if (!ready) {
        mlt_export_set_error("MLT is not initialized.");
    }

    return ready;
}

static double preview_track_gain_locked(int track_index)
{
    if (track_index < 0 || track_index >= MLT_COMPOSITION_MAX_LAYERS) {
        return 0.0;
    }

    mlt_filter filter = current_engine()->e_track_audio_filters[track_index];

    if (filter != NULL) {
        const double gain =
            mlt_properties_get_double(
                MLT_FILTER_PROPERTIES(filter),
                "gain"
            );

        if (isfinite(gain)) {
            return CLAMP(gain, 0.0, 1.0);
        }
    }

    return CLAMP(current_engine()->e_track_audio_gain[track_index], 0.0, 1.0);
}


static int snapshot_export_composition_locked(
    MltExportCompositionSnapshot *snapshot,
    char *failure,
    size_t failure_size)
{
    if (snapshot == NULL) {
        if (failure != NULL && failure_size > 0) {
            snprintf(failure, failure_size, "%s", "Invalid composition snapshot request.");
        }
        return 0;
    }

    memset(snapshot, 0, sizeof(*snapshot));

    for (int index = 0; index < MLT_COMPOSITION_MAX_LAYERS; index++) {
        snapshot->layers[index].opacity = 1.0;
        snapshot->layers[index].scale = 1.0;
        snapshot->layers[index].audio_gain = 1.0;
        snapshot->layers[index].start_frame = index == 0 ? 0 : -1;
        snapshot->layers[index].end_frame = -1;
        snapshot->layers[index].source_in_frame = index == 0 ? 0 : -1;
        snapshot->layers[index].source_out_frame = -1;
    }

    if (current_engine()->e_primary_producer == NULL ||
        current_engine()->e_producer == NULL ||
        current_engine()->e_track_count < 1 ||
        current_engine()->e_is_still ||
        !current_engine()->e_has_video) {
        if (failure != NULL && failure_size > 0) {
            snprintf(failure, failure_size, "%s", "The open movie cannot be exported.");
        }
        return 0;
    }

    const char *primary_resource =
        mlt_properties_get(
            MLT_PRODUCER_PROPERTIES(current_engine()->e_primary_producer),
            "resource"
        );

    if (primary_resource == NULL || primary_resource[0] == '\0') {
        if (failure != NULL && failure_size > 0) {
            snprintf(failure, failure_size, "%s", "The base layer has no exportable source path.");
        }
        return 0;
    }

    MltExportLayerSnapshot *base =
        &snapshot->layers[MLT_COMPOSITION_BASE_LAYER];

    snapshot->layer_count = 1;
    base->path = primary_resource;
    base->present = 1;
    base->start_frame = 0;
    base->end_frame =
        (int64_t)mlt_producer_get_length(current_engine()->e_primary_producer) - 1;
    base->source_in_frame = 0;
    base->source_out_frame = base->end_frame;
    base->has_audio = current_engine()->e_track_has_audio[0] ? 1 : 0;
    base->audio_gain =
        CLAMP(current_engine()->e_track_audio_gain[0], 0.0, 1.0);

    if (current_engine()->e_track_count < 2 ||
        current_engine()->e_secondary_producer == NULL ||
        current_engine()->e_secondary_playlist == NULL ||
        current_engine()->e_video_composite == NULL) {
        return 1;
    }

    const char *secondary_resource =
        mlt_properties_get(
            MLT_PRODUCER_PROPERTIES(current_engine()->e_secondary_producer),
            "resource"
        );

    if (secondary_resource == NULL || secondary_resource[0] == '\0') {
        if (failure != NULL && failure_size > 0) {
            snprintf(failure, failure_size, "%s", "Layer 2 has no exportable source path.");
        }
        return 0;
    }

    MltExportLayerSnapshot *layer2 =
        &snapshot->layers[MLT_COMPOSITION_FIRST_OVERLAY];

    snapshot->layer_count = 2;
    layer2->path = secondary_resource;
    layer2->present = 1;
    layer2->start_frame = current_engine()->e_secondary_start_frame;
    layer2->end_frame =
        (int64_t)mlt_producer_get_length(
            mlt_playlist_producer(current_engine()->e_secondary_playlist)
        ) - 1;
    layer2->source_in_frame = current_engine()->e_secondary_source_in_frame;
    layer2->source_out_frame = current_engine()->e_secondary_source_out_frame;
    layer2->has_audio = current_engine()->e_track_has_audio[1] ? 1 : 0;
    layer2->is_still = current_engine()->e_secondary_is_still ? 1 : 0;
    layer2->alpha_mode = current_engine()->e_secondary_alpha_mode;
    layer2->audio_gain =
        CLAMP(current_engine()->e_track_audio_gain[1], 0.0, 1.0);
    layer2->opacity =
        CLAMP(current_engine()->e_secondary_opacity, 0.0, 1.0);
    layer2->x = current_engine()->e_secondary_x;
    layer2->y = current_engine()->e_secondary_y;
    layer2->scale =
        CLAMP(current_engine()->e_secondary_scale, 0.10, 3.0);

    if (current_engine()->e_track_count < 3 ||
        current_engine()->e_tertiary_producer == NULL ||
        current_engine()->e_tertiary_playlist == NULL ||
        current_engine()->e_tertiary_video_composite == NULL) {
        return 1;
    }

    const char *tertiary_resource =
        mlt_properties_get(
            MLT_PRODUCER_PROPERTIES(current_engine()->e_tertiary_producer),
            "resource"
        );

    if (tertiary_resource == NULL || tertiary_resource[0] == '\0') {
        if (failure != NULL && failure_size > 0) {
            snprintf(failure, failure_size, "%s", "Layer 3 has no exportable source path.");
        }
        return 0;
    }

    MltExportLayerSnapshot *layer3 =
        &snapshot->layers[MLT_COMPOSITION_SECOND_OVERLAY];

    snapshot->layer_count = 3;
    layer3->path = tertiary_resource;
    layer3->present = 1;
    layer3->start_frame = current_engine()->e_tertiary_start_frame;
    layer3->end_frame =
        (int64_t)mlt_producer_get_length(
            mlt_playlist_producer(current_engine()->e_tertiary_playlist)
        ) - 1;
    layer3->source_in_frame = current_engine()->e_tertiary_source_in_frame;
    layer3->source_out_frame = current_engine()->e_tertiary_source_out_frame;
    layer3->has_audio = current_engine()->e_track_has_audio[2] ? 1 : 0;
    layer3->is_still = current_engine()->e_tertiary_is_still ? 1 : 0;
    layer3->alpha_mode = current_engine()->e_tertiary_alpha_mode;
    layer3->audio_gain = CLAMP(current_engine()->e_track_audio_gain[2], 0.0, 1.0);
    layer3->opacity = CLAMP(current_engine()->e_tertiary_opacity, 0.0, 1.0);
    layer3->x = current_engine()->e_tertiary_x;
    layer3->y = current_engine()->e_tertiary_y;
    layer3->scale = CLAMP(current_engine()->e_tertiary_scale, 0.10, 3.0);

    return 1;
}

static int derive_preview_composition_locked(
    int64_t in_frame,
    int64_t out_frame,
    MltCompositionDerivedState *state,
    char *failure,
    size_t failure_size)
{
    if (state == NULL ||
        current_engine()->e_profile == NULL ||
        current_engine()->e_primary_producer == NULL ||
        current_engine()->e_producer == NULL ||
        current_engine()->e_track_count < 1) {
        if (failure != NULL && failure_size > 0) {
            snprintf(failure, failure_size, "%s", "The preview composition is unavailable.");
        }
        return 0;
    }

    memset(state, 0, sizeof(*state));
    for (int index = MLT_COMPOSITION_FIRST_OVERLAY;
         index < MLT_COMPOSITION_MAX_LAYERS;
         index++) {
        state->layers[index].start_frame = -1;
    }

    const int64_t composition_length =
        (int64_t)mlt_producer_get_length(current_engine()->e_primary_producer);

    int64_t normalized_in = in_frame;
    int64_t normalized_out = out_frame;

    if (normalized_in < 0) {
        normalized_in = 0;
    }
    if (normalized_out >= composition_length) {
        normalized_out = composition_length - 1;
    }

    if (composition_length <= 0 || normalized_out < normalized_in) {
        if (failure != NULL && failure_size > 0) {
            snprintf(failure, failure_size, "%s", "The preview parity range is invalid.");
        }
        return 0;
    }

    state->layer_count =
        current_engine()->e_track_count >= 3
            ? 3
            : (current_engine()->e_track_count >= 2 ? 2 : 1);
    state->profile_width = current_engine()->e_profile->width;
    state->profile_height = current_engine()->e_profile->height;
    state->profile_fps = mlt_profile_fps(current_engine()->e_profile);
    state->composition_length = composition_length;
    state->range_in_frame = normalized_in;
    state->range_out_frame = normalized_out;

    MltCompositionLayerDerivedState *base =
        &state->layers[MLT_COMPOSITION_BASE_LAYER];
    base->present = 1;
    base->start_frame = 0;
    base->timeline_length = composition_length;
    base->source_in_frame = 0;
    base->source_out_frame = composition_length - 1;
    base->base_width = state->profile_width;
    base->base_height = state->profile_height;
    base->x = 0.0;
    base->y = 0.0;
    base->width = state->profile_width;
    base->height = state->profile_height;
    base->opacity = 1.0;
    base->has_audio = current_engine()->e_track_has_audio[0] ? 1 : 0;
    base->audio_gain = preview_track_gain_locked(0);

    if (state->layer_count == 1) {
        state->valid = 1;
        return 1;
    }

    if (current_engine()->e_secondary_producer == NULL ||
        current_engine()->e_secondary_playlist == NULL ||
        current_engine()->e_video_composite == NULL) {
        if (failure != NULL && failure_size > 0) {
            snprintf(failure, failure_size, "%s", "The preview Layer 2 graph is incomplete.");
        }
        return 0;
    }

    MltCompositionLayerDerivedState *layer2 =
        &state->layers[MLT_COMPOSITION_FIRST_OVERLAY];
    layer2->present = 1;
    layer2->start_frame = current_engine()->e_secondary_start_frame;
    layer2->source_in_frame = current_engine()->e_secondary_source_in_frame;
    layer2->source_out_frame = current_engine()->e_secondary_source_out_frame;
    layer2->timeline_length =
        (int64_t)mlt_producer_get_length(
            mlt_playlist_producer(current_engine()->e_secondary_playlist)
        );
    layer2->is_still = current_engine()->e_secondary_is_still ? 1 : 0;
    layer2->alpha_mode = current_engine()->e_secondary_alpha_mode;
    layer2->has_audio = current_engine()->e_track_has_audio[1] ? 1 : 0;
    layer2->audio_gain = preview_track_gain_locked(1);

    if (current_engine()->e_secondary_alpha_filter != NULL) {
        layer2->alpha_mode =
            mlt_properties_get_int(
                MLT_FILTER_PROPERTIES(current_engine()->e_secondary_alpha_filter),
                "mlt_player_alpha_mode"
            );
    }

    if (!mlt_composition_secondary_base_size(
            current_engine()->e_profile,
            current_engine()->e_secondary_producer,
            layer2->is_still,
            &layer2->base_width,
            &layer2->base_height) ||
        !mlt_composition_get_geometry(
            current_engine()->e_video_composite,
            &layer2->x,
            &layer2->y,
            &layer2->width,
            &layer2->height,
            &layer2->opacity)) {
        if (failure != NULL && failure_size > 0) {
            snprintf(failure, failure_size, "%s", "Could not derive the preview Layer 2 geometry.");
        }
        return 0;
    }

    if (state->layer_count >= 3) {
        if (current_engine()->e_tertiary_producer == NULL ||
            current_engine()->e_tertiary_playlist == NULL ||
            current_engine()->e_tertiary_video_composite == NULL) {
            if (failure != NULL && failure_size > 0) {
                snprintf(failure, failure_size, "%s", "The preview Layer 3 graph is incomplete.");
            }
            return 0;
        }

        MltCompositionLayerDerivedState *layer3 =
            &state->layers[MLT_COMPOSITION_SECOND_OVERLAY];
        layer3->present = 1;
        layer3->start_frame = current_engine()->e_tertiary_start_frame;
        layer3->source_in_frame = current_engine()->e_tertiary_source_in_frame;
        layer3->source_out_frame = current_engine()->e_tertiary_source_out_frame;
        layer3->timeline_length =
            (int64_t)mlt_producer_get_length(
                mlt_playlist_producer(current_engine()->e_tertiary_playlist)
            );
        layer3->is_still = current_engine()->e_tertiary_is_still ? 1 : 0;
        layer3->alpha_mode = current_engine()->e_tertiary_alpha_mode;
        if (current_engine()->e_tertiary_alpha_filter != NULL) {
            layer3->alpha_mode = mlt_properties_get_int(
                MLT_FILTER_PROPERTIES(current_engine()->e_tertiary_alpha_filter),
                "mlt_player_alpha_mode"
            );
        }
        layer3->base_width = current_engine()->e_tertiary_base_width;
        layer3->base_height = current_engine()->e_tertiary_base_height;
        layer3->has_audio = current_engine()->e_track_has_audio[2] ? 1 : 0;
        layer3->audio_gain = preview_track_gain_locked(2);
        if (!mlt_composition_get_geometry(
                current_engine()->e_tertiary_video_composite,
                &layer3->x,
                &layer3->y,
                &layer3->width,
                &layer3->height,
                &layer3->opacity)) {
            if (failure != NULL && failure_size > 0) {
                snprintf(failure, failure_size, "%s", "Could not derive the preview Layer 3 geometry.");
            }
            return 0;
        }
    }

    state->valid = 1;
    return 1;
}

/*
 * POC 10.9 snapshots the open layered movie and hands only scalar/path state
 * to the export module. The worker still builds a completely independent MLT
 * graph; no live preview object crosses the module boundary.
 */
MLT_BRIDGE_EXPORT
int mlt_bridge_export_composition_start(
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame,
    int kind)
{
    ensure_locks();

    if (output_path == NULL ||
        output_path[0] == '\0' ||
        out_frame < in_frame ||
        kind < (int)MLT_EXPORT_KIND_MP4 ||
        kind > (int)MLT_EXPORT_KIND_WAV_AUDIO ||
        current_engine() == NULL) {
        mlt_export_set_error("Invalid composition export request.");
        return 0;
    }

    if (!export_factory_is_ready()) {
        return 0;
    }

    g_mutex_lock(&current_engine()->e_mutex);

    MltExportCompositionSnapshot snapshot = {0};
    char snapshot_failure[512] = "";

    if (!snapshot_export_composition_locked(
            &snapshot,
            snapshot_failure,
            sizeof(snapshot_failure))) {
        g_mutex_unlock(&current_engine()->e_mutex);
        mlt_export_set_error(
            snapshot_failure[0] != '\0'
                ? snapshot_failure
                : "The open movie cannot be exported."
        );
        return 0;
    }

    const int result =
        mlt_export_start_composition(
            &snapshot,
            output_path,
            in_frame,
            out_frame,
            (MltExportKind)kind
        );

    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_debug_composition_parity(
    int64_t in_frame,
    int64_t out_frame,
    MltCompositionDerivedState *preview_state,
    MltCompositionDerivedState *export_state,
    char *error_buffer,
    int error_capacity)
{
    ensure_locks();

    if (preview_state != NULL) {
        memset(preview_state, 0, sizeof(*preview_state));
    }
    if (export_state != NULL) {
        memset(export_state, 0, sizeof(*export_state));
    }
    if (error_buffer != NULL && error_capacity > 0) {
        error_buffer[0] = '\0';
    }

    if (preview_state == NULL ||
        export_state == NULL ||
        out_frame < in_frame ||
        current_engine() == NULL) {
        copy_string_value(
            "Invalid composition parity request.",
            error_buffer,
            error_capacity
        );
        return 0;
    }

    if (!export_factory_is_ready()) {
        copy_string_value(
            "MLT is not initialized.",
            error_buffer,
            error_capacity
        );
        return 0;
    }

    g_mutex_lock(&current_engine()->e_mutex);

    char failure[512] = "";
    MltExportCompositionSnapshot snapshot = {0};

    if (!snapshot_export_composition_locked(
            &snapshot,
            failure,
            sizeof(failure)) ||
        !derive_preview_composition_locked(
            in_frame,
            out_frame,
            preview_state,
            failure,
            sizeof(failure)) ||
        !mlt_export_derive_composition(
            &snapshot,
            in_frame,
            out_frame,
            export_state,
            failure,
            (int)sizeof(failure))) {
        g_mutex_unlock(&current_engine()->e_mutex);
        copy_string_value(
            failure[0] != '\0'
                ? failure
                : "Could not derive composition parity state.",
            error_buffer,
            error_capacity
        );
        return 0;
    }

    g_mutex_unlock(&current_engine()->e_mutex);
    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_start(
    const char *source_path,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame)
{
    if (!export_factory_is_ready()) {
        return 0;
    }

    return mlt_export_start_simple(
        source_path,
        output_path,
        in_frame,
        out_frame,
        MLT_EXPORT_KIND_MP4
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_frame_start(
    const char *source_path,
    const char *output_path,
    int64_t frame)
{
    if (!export_factory_is_ready()) {
        return 0;
    }

    return mlt_export_start_simple(
        source_path,
        output_path,
        frame,
        frame,
        MLT_EXPORT_KIND_PNG_FRAME
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_png_sequence_start(
    const char *source_path,
    const char *output_directory,
    int64_t in_frame,
    int64_t out_frame)
{
    if (!export_factory_is_ready()) {
        return 0;
    }

    return mlt_export_start_simple(
        source_path,
        output_directory,
        in_frame,
        out_frame,
        MLT_EXPORT_KIND_PNG_SEQUENCE
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_audio_start(
    const char *source_path,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame)
{
    if (!export_factory_is_ready()) {
        return 0;
    }

    return mlt_export_start_simple(
        source_path,
        output_path,
        in_frame,
        out_frame,
        MLT_EXPORT_KIND_WAV_AUDIO
    );
}

MLT_BRIDGE_EXPORT
void mlt_bridge_export_cancel(void)
{
    mlt_export_cancel();
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_is_running(void)
{
    return mlt_export_is_running();
}

MLT_BRIDGE_EXPORT
double mlt_bridge_export_progress(void)
{
    return mlt_export_progress();
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_succeeded(void)
{
    return mlt_export_succeeded();
}

MLT_BRIDGE_EXPORT
int mlt_bridge_export_error_copy(
    char *buffer,
    int capacity)
{
    return mlt_export_error_copy(buffer, capacity);
}

/* ------------------------------------------------------------------------- */
/* Media                                                                     */
/* ------------------------------------------------------------------------- */


/*
 * Attach MLT's standard volume filter and then release the factory reference.
 * The target producer owns the attached filter reference; the returned pointer
 * is borrowed and remains valid until that producer is closed.
 */
static mlt_filter attach_track_audio_filter_locked(
    mlt_producer target)
{
    if (target == NULL) {
        return NULL;
    }

    mlt_filter filter =
        mlt_factory_filter(
            current_engine()->e_profile,
            "volume",
            NULL
        );

    if (filter == NULL) {
        return NULL;
    }

    mlt_properties_set_double(
        MLT_FILTER_PROPERTIES(filter),
        "gain",
        1.0
    );

    if (mlt_producer_attach(
            target,
            filter) != 0) {
        mlt_filter_close(filter);
        return NULL;
    }

    /*
     * mlt_service_attach() increments the filter reference. Release the
     * factory's original reference and keep a borrowed pointer for live gain
     * property changes.
     */
    mlt_filter_close(filter);

    return filter;
}

/* ------------------------------------------------------------------------- */
/* POC 10.6 alpha-layer helpers                                              */
/* ------------------------------------------------------------------------- */

/*
 * Direct still-image producers bypass MLT's loader producer. The loader
 * normally guarantees that every producer has an image converter attached
 * (avcolor_space first, imageconvert as fallback). The core composite
 * transition requests YUV422 and assumes the producer honors that request.
 * Without a converter, pixbuf can return RGBA directly and composite will
 * interpret the 4-byte RGBA buffer as 2-byte YUV422, producing green/stride
 * corruption. Mirror the loader's conversion guarantee for direct stills.
 */
static int attach_still_image_converter_locked(
    mlt_producer target)
{
    if (target == NULL) {
        return 0;
    }

    mlt_filter filter =
        mlt_factory_filter(
            current_engine()->e_profile,
            "avcolor_space",
            NULL
        );

    if (filter == NULL) {
        filter =
            mlt_factory_filter(
                current_engine()->e_profile,
                "imageconvert",
                NULL
            );
    }

    if (filter == NULL) {
        return 0;
    }

    if (mlt_producer_attach(
            target,
            filter) != 0) {
        mlt_filter_close(filter);
        return 0;
    }

    /*
     * mlt_service_attach() owns a reference after a successful attach.
     * Release the factory reference, matching MLT loader behavior.
     */
    mlt_filter_close(filter);
    return 1;
}

/*
 * Validate the exact format contract used by core/composite for a still
 * overlay. This turns the visual green-buffer failure into an import-time
 * failure that the existing smoke test can catch. Alpha-bearing stills must
 * also retain a separate alpha plane after the RGBA -> YUV422 conversion.
 */
static int still_source_is_composite_ready_locked(
    mlt_producer candidate,
    int require_alpha)
{
    if (candidate == NULL || current_engine()->e_profile == NULL) {
        return 0;
    }

    const mlt_position saved_position =
        mlt_producer_position(candidate);
    const double saved_speed =
        mlt_producer_get_speed(candidate);

    mlt_producer_set_speed(candidate, 0.0);
    mlt_producer_seek(candidate, 0);

    mlt_frame frame = NULL;
    int ready = 0;

    if (mlt_service_get_frame(
            MLT_PRODUCER_SERVICE(candidate),
            &frame,
            0) == 0 &&
        frame != NULL) {
        uint8_t *image = NULL;
        mlt_image_format format = mlt_image_yuv422;
        int width = current_engine()->e_profile->width;
        int height = current_engine()->e_profile->height;

        if (mlt_frame_get_image(
                frame,
                &image,
                &format,
                &width,
                &height,
                1) == 0 &&
            image != NULL &&
            format == mlt_image_yuv422 &&
            width > 0 &&
            height > 0 &&
            (!require_alpha ||
             mlt_frame_get_alpha(frame) != NULL)) {
            ready = 1;
        }

        mlt_frame_close(frame);
    }

    mlt_producer_set_speed(candidate, saved_speed);
    mlt_producer_seek(candidate, saved_position);

    return ready;
}


/* Call with engine_mutex held. */
static int apply_secondary_geometry_locked(void)
{
    if (current_engine()->e_track_count < 2 ||
        current_engine()->e_video_composite == NULL ||
        current_engine()->e_secondary_base_width <= 0.0 ||
        current_engine()->e_secondary_base_height <= 0.0 ||
        !isfinite(current_engine()->e_secondary_x) ||
        !isfinite(current_engine()->e_secondary_y) ||
        !isfinite(current_engine()->e_secondary_scale) ||
        current_engine()->e_secondary_scale <= 0.0) {
        return 0;
    }

    const double width =
        current_engine()->e_secondary_base_width *
        current_engine()->e_secondary_scale;
    const double height =
        current_engine()->e_secondary_base_height *
        current_engine()->e_secondary_scale;

    if (!isfinite(width) ||
        !isfinite(height) ||
        width <= 0.0 ||
        height <= 0.0) {
        return 0;
    }

    mlt_service_lock(
        MLT_TRANSITION_SERVICE(
            current_engine()->e_video_composite
        )
    );

    const int applied =
        mlt_composition_set_geometry(
            current_engine()->e_video_composite,
            current_engine()->e_secondary_x,
            current_engine()->e_secondary_y,
            width,
            height,
            current_engine()->e_secondary_opacity
        );

    mlt_service_unlock(
        MLT_TRANSITION_SERVICE(
            current_engine()->e_video_composite
        )
    );

    if (!applied) {
        return 0;
    }

    invalidate_frames();
    refresh_locked();
    return 1;
}

static int read_secondary_rect_locked(
    mlt_rect *out_rect)
{
    if (out_rect == NULL ||
        current_engine()->e_track_count < 2 ||
        current_engine()->e_video_composite == NULL) {
        return 0;
    }

    mlt_service_lock(
        MLT_TRANSITION_SERVICE(
            current_engine()->e_video_composite
        )
    );

    const mlt_rect rect =
        mlt_properties_anim_get_rect(
            MLT_TRANSITION_PROPERTIES(
                current_engine()->e_video_composite
            ),
            "geometry",
            0,
            0
        );

    mlt_service_unlock(
        MLT_TRANSITION_SERVICE(
            current_engine()->e_video_composite
        )
    );

    if (!isfinite(rect.x) ||
        !isfinite(rect.y) ||
        !isfinite(rect.w) ||
        !isfinite(rect.h) ||
        rect.w <= 0.0 ||
        rect.h <= 0.0) {
        return 0;
    }

    *out_rect = rect;
    return 1;
}

/* Call with engine mutex held. */
static int apply_tertiary_geometry_locked(void)
{
    if (current_engine()->e_track_count < 3 ||
        current_engine()->e_tertiary_video_composite == NULL ||
        current_engine()->e_tertiary_base_width <= 0.0 ||
        current_engine()->e_tertiary_base_height <= 0.0 ||
        !isfinite(current_engine()->e_tertiary_x) ||
        !isfinite(current_engine()->e_tertiary_y) ||
        !isfinite(current_engine()->e_tertiary_scale) ||
        current_engine()->e_tertiary_scale <= 0.0) {
        return 0;
    }

    const double width =
        current_engine()->e_tertiary_base_width *
        current_engine()->e_tertiary_scale;
    const double height =
        current_engine()->e_tertiary_base_height *
        current_engine()->e_tertiary_scale;

    if (!isfinite(width) || !isfinite(height) ||
        width <= 0.0 || height <= 0.0) {
        return 0;
    }

    mlt_service_lock(
        MLT_TRANSITION_SERVICE(
            current_engine()->e_tertiary_video_composite
        )
    );

    const int applied =
        mlt_composition_set_geometry(
            current_engine()->e_tertiary_video_composite,
            current_engine()->e_tertiary_x,
            current_engine()->e_tertiary_y,
            width,
            height,
            current_engine()->e_tertiary_opacity
        );

    mlt_service_unlock(
        MLT_TRANSITION_SERVICE(
            current_engine()->e_tertiary_video_composite
        )
    );

    if (!applied) {
        return 0;
    }

    invalidate_frames();
    refresh_locked();
    return 1;
}

static int read_tertiary_rect_locked(mlt_rect *out_rect)
{
    if (out_rect == NULL ||
        current_engine()->e_track_count < 3 ||
        current_engine()->e_tertiary_video_composite == NULL) {
        return 0;
    }

    mlt_service_lock(
        MLT_TRANSITION_SERVICE(
            current_engine()->e_tertiary_video_composite
        )
    );

    const mlt_rect rect =
        mlt_properties_anim_get_rect(
            MLT_TRANSITION_PROPERTIES(
                current_engine()->e_tertiary_video_composite
            ),
            "geometry",
            0,
            0
        );

    mlt_service_unlock(
        MLT_TRANSITION_SERVICE(
            current_engine()->e_tertiary_video_composite
        )
    );

    if (!isfinite(rect.x) || !isfinite(rect.y) ||
        !isfinite(rect.w) || !isfinite(rect.h) ||
        rect.w <= 0.0 || rect.h <= 0.0) {
        return 0;
    }

    *out_rect = rect;
    return 1;
}

static int pixel_format_has_alpha_channel(
    const char *pixel_format)
{
    if (pixel_format == NULL || pixel_format[0] == '\0') {
        return 0;
    }

    if (strncmp(pixel_format, "yuva", 4) == 0 ||
        strncmp(pixel_format, "gbrap", 5) == 0 ||
        strncmp(pixel_format, "rgba", 4) == 0 ||
        strncmp(pixel_format, "bgra", 4) == 0 ||
        strncmp(pixel_format, "argb", 4) == 0 ||
        strncmp(pixel_format, "abgr", 4) == 0 ||
        strncmp(pixel_format, "ayuv", 4) == 0 ||
        strncmp(pixel_format, "ya8", 3) == 0 ||
        strncmp(pixel_format, "ya16", 4) == 0) {
        return 1;
    }

    return 0;
}

/*
 * Ask one source frame for its native image representation. This catches
 * image producers such as qimage/pixbuf, while codec metadata catches timed
 * alpha formats such as yuva444p10le and argb before any compositing occurs.
 */
static int producer_frame_reports_alpha_locked(
    mlt_producer candidate)
{
    if (candidate == NULL) {
        return 0;
    }

    const mlt_position saved_position =
        mlt_producer_position(candidate);
    const double saved_speed =
        mlt_producer_get_speed(candidate);

    mlt_producer_set_speed(candidate, 0.0);
    mlt_producer_seek(candidate, 0);

    mlt_frame frame = NULL;
    int result = 0;

    if (mlt_service_get_frame(
            MLT_PRODUCER_SERVICE(candidate),
            &frame,
            0) == 0 &&
        frame != NULL) {
        uint8_t *image = NULL;
        mlt_image_format format = mlt_image_none;
        int width = current_engine()->e_profile != NULL ? current_engine()->e_profile->width : 0;
        int height = current_engine()->e_profile != NULL ? current_engine()->e_profile->height : 0;

        if (mlt_frame_get_image(
                frame,
                &image,
                &format,
                &width,
                &height,
                0) == 0) {
            result =
                format == mlt_image_rgba ||
                mlt_frame_get_alpha(frame) != NULL;
        }

        mlt_frame_close(frame);
    }

    mlt_producer_set_speed(candidate, saved_speed);
    mlt_producer_seek(candidate, saved_position);

    return result;
}

static int producer_has_alpha_locked(
    mlt_producer candidate,
    MediaKind kind)
{
    if (candidate == NULL) {
        return 0;
    }

    mlt_properties properties =
        MLT_PRODUCER_PROPERTIES(candidate);

    if (kind == MEDIA_TIMED &&
        mlt_properties_get(properties, "video_index") != NULL) {
        const int stream_index =
            mlt_properties_get_int(properties, "video_index");

        if (stream_index >= 0) {
            char key[128];
            snprintf(
                key,
                sizeof(key),
                "meta.media.%d.codec.pix_fmt",
                stream_index
            );

            if (pixel_format_has_alpha_channel(
                    mlt_properties_get(properties, key))) {
                return 1;
            }
        }
    }

    return producer_frame_reports_alpha_locked(candidate);
}

/*
 * The filter is always attached to layer 2 but normally disabled. Auto and
 * Straight therefore preserve MLT's native decode path exactly. Selecting
 * Premultiplied enables the filter and unpremultiplies RGB before MLT's
 * existing composite transition applies alpha.
 */
static mlt_filter attach_secondary_alpha_filter_locked(
    mlt_producer target)
{
    return mlt_composition_attach_alpha_filter(
        target,
        0
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_open(
    const char *path)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (repository == NULL ||
        path == NULL ||
        path[0] == '\0') {
        set_error(
            "MLT is not initialized "
            "or the path is invalid."
        );

        g_mutex_unlock(&current_engine()->e_mutex);

        return 0;
    }

    close_producer_locked();

    if (current_engine()->e_profile != NULL) {
        mlt_profile_close(current_engine()->e_profile);

        current_engine()->e_profile = NULL;
    }

    current_engine()->e_profile = mlt_profile_init(NULL);

    if (current_engine()->e_profile == NULL) {
        set_error(
            "Could not create an MLT profile."
        );

        g_mutex_unlock(&current_engine()->e_mutex);

        return 0;
    }

    /*
     * First open discovers the geometry, second open runs against a
     * profile that matches it. Doing this in one pass would leave
     * the producer configured for whatever the default profile was.
     */
    mlt_producer probe_producer =
        mlt_factory_producer(
            current_engine()->e_profile,
            NULL,
            path
        );

    if (probe_producer == NULL) {
        set_error(
            "MLT could not open the selected media."
        );

        g_mutex_unlock(&current_engine()->e_mutex);

        return 0;
    }

    mlt_producer_probe(probe_producer);
    mlt_profile_from_producer(current_engine()->e_profile, probe_producer);
    mlt_producer_close(probe_producer);

    current_engine()->e_primary_producer =
        mlt_factory_producer(
            current_engine()->e_profile,
            NULL,
            path
        );

    current_engine()->e_producer = current_engine()->e_primary_producer;

    if (current_engine()->e_producer == NULL) {
        set_error(
            "MLT could not reopen the media "
            "with the detected profile."
        );

        g_mutex_unlock(&current_engine()->e_mutex);

        return 0;
    }

    mlt_producer_probe(current_engine()->e_producer);

    mlt_properties producer_properties =
        MLT_PRODUCER_PROPERTIES(current_engine()->e_producer);

    const MediaKind kind =
        classify_producer_locked(current_engine()->e_producer);

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

        g_mutex_unlock(&current_engine()->e_mutex);

        return 0;
    }

    current_engine()->e_is_still = (kind == MEDIA_STILL);

    if (current_engine()->e_is_still) {
        current_engine()->e_has_video = 1;
        current_engine()->e_has_audio = 0;
    } else {
        /*
         * avformat sets these indices to -1 when the corresponding
         * stream is absent. When a property is missing entirely we
         * have no evidence either way, so assume the stream exists
         * and let the consumer produce silence or a test card.
         */
        current_engine()->e_has_video =
            mlt_properties_get(
                producer_properties,
                "video_index") == NULL ||
            mlt_properties_get_int(
                producer_properties,
                "video_index") >= 0;

        current_engine()->e_has_audio =
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
    current_engine()->e_stream_count = 0;
    current_engine()->e_selected_video_stream_index = -1;
    current_engine()->e_selected_audio_stream_index = -1;

    current_engine()->e_video_codec_name[0] = '\0';
    current_engine()->e_video_codec_long_name[0] = '\0';
    current_engine()->e_audio_codec_name[0] = '\0';
    current_engine()->e_audio_codec_long_name[0] = '\0';

    current_engine()->e_video_pixel_format[0] = '\0';
    current_engine()->e_video_colorspace = -1;
    current_engine()->e_video_color_trc = -1;
    current_engine()->e_video_color_range[0] = '\0';

    if (!current_engine()->e_is_still) {
        if (mlt_properties_get(
                producer_properties,
                "meta.media.nb_streams") != NULL) {
            current_engine()->e_stream_count =
                mlt_properties_get_int(
                    producer_properties,
                    "meta.media.nb_streams"
                );
        }

        if (mlt_properties_get(
                producer_properties,
                "video_index") != NULL) {
            current_engine()->e_selected_video_stream_index =
                mlt_properties_get_int(
                    producer_properties,
                    "video_index"
                );
        }

        if (mlt_properties_get(
                producer_properties,
                "audio_index") != NULL) {
            current_engine()->e_selected_audio_stream_index =
                mlt_properties_get_int(
                    producer_properties,
                    "audio_index"
                );
        }

        read_codec_metadata_locked(
            producer_properties,
            current_engine()->e_selected_video_stream_index,
            current_engine()->e_video_codec_name,
            sizeof(current_engine()->e_video_codec_name),
            current_engine()->e_video_codec_long_name,
            sizeof(current_engine()->e_video_codec_long_name)
        );

        read_video_color_metadata_locked(
            producer_properties,
            current_engine()->e_selected_video_stream_index
        );

        read_codec_metadata_locked(
            producer_properties,
            current_engine()->e_selected_audio_stream_index,
            current_engine()->e_audio_codec_name,
            sizeof(current_engine()->e_audio_codec_name),
            current_engine()->e_audio_codec_long_name,
            sizeof(current_engine()->e_audio_codec_long_name)
        );

        read_stream_inspection_locked(producer_properties);
    }

    /*
     * avformat passes FFmpeg metadata through as meta.attr.*.markup.
     * Prefer the selected video stream's timecode, then the container tag,
     * then any stream-level timecode if the selected stream has none.
     */
    current_engine()->e_source_timecode[0] = '\0';

    const char *timecode = NULL;

    if (!current_engine()->e_is_still) {
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
            current_engine()->e_source_timecode,
            sizeof(current_engine()->e_source_timecode),
            "%s",
            timecode
        );
    }

    if (mlt_producer_get_length(current_engine()->e_producer) <= 0) {
        set_error("The media reports no duration.");

        close_producer_locked();

        g_mutex_unlock(&current_engine()->e_mutex);

        return 0;
    }

    current_engine()->e_track_count = 1;
    current_engine()->e_secondary_start_frame = -1;
    current_engine()->e_secondary_source_in_frame = -1;
    current_engine()->e_secondary_source_out_frame = -1;
    current_engine()->e_secondary_source_length_frames = 0;
    current_engine()->e_secondary_opacity = 1.0;
    current_engine()->e_secondary_x = 0.0;
    current_engine()->e_secondary_y = 0.0;
    current_engine()->e_secondary_scale = 1.0;
    current_engine()->e_secondary_base_width = 0.0;
    current_engine()->e_secondary_base_height = 0.0;
    current_engine()->e_secondary_has_alpha = 0;
    current_engine()->e_secondary_alpha_mode = 0;
    current_engine()->e_secondary_is_still = 0;
    current_engine()->e_secondary_alpha_filter = NULL;
    current_engine()->e_tertiary_start_frame = -1;
    current_engine()->e_tertiary_source_in_frame = -1;
    current_engine()->e_tertiary_source_out_frame = -1;
    current_engine()->e_tertiary_source_length_frames = 0;
    current_engine()->e_tertiary_opacity = 1.0;
    current_engine()->e_tertiary_x = 0.0;
    current_engine()->e_tertiary_y = 0.0;
    current_engine()->e_tertiary_scale = 1.0;
    current_engine()->e_tertiary_base_width = 0.0;
    current_engine()->e_tertiary_base_height = 0.0;
    current_engine()->e_tertiary_has_alpha = 0;
    current_engine()->e_tertiary_alpha_mode = 0;
    current_engine()->e_tertiary_is_still = 0;
    current_engine()->e_tertiary_alpha_filter = NULL;

    for (int index = 0; index < MLT_COMPOSITION_MAX_LAYERS; index++) {
        current_engine()->e_track_audio_gain[index] = 1.0;
        current_engine()->e_track_has_audio[index] = 0;
        current_engine()->e_track_audio_filters[index] = NULL;
    }
    current_engine()->e_track_has_audio[0] = current_engine()->e_has_audio ? 1 : 0;

    if (current_engine()->e_track_has_audio[0]) {
        current_engine()->e_track_audio_filters[0] =
            attach_track_audio_filter_locked(
                current_engine()->e_primary_producer
            );
    }

    g_atomic_int_set(
        &current_engine()->e_target_width,
        current_engine()->e_profile->width
    );

    g_atomic_int_set(
        &current_engine()->e_target_height,
        current_engine()->e_profile->height
    );

    mlt_producer_set_speed(current_engine()->e_producer, 0.0);
    mlt_producer_seek(current_engine()->e_producer, 0);

    if (g_atomic_int_get(
            &current_engine()->e_preview_enabled)) {
        if (!create_consumer_locked()) {
            close_producer_locked();

            g_mutex_unlock(&current_engine()->e_mutex);

            return 0;
        }

        if (mlt_consumer_start(current_engine()->e_consumer) != 0) {
            set_error(
                "MLT could not start the "
                "audio and preview consumer."
            );

            close_producer_locked();

            g_mutex_unlock(&current_engine()->e_mutex);

            return 0;
        }

        refresh_locked();
    }

    set_error(NULL);

    g_mutex_unlock(&current_engine()->e_mutex);

    /*
     * Drop any frame left over from the previous file so the first
     * frame of this one is not rejected as a duplicate position.
     */
    invalidate_frames();

    return 1;
}

typedef struct _TertiaryInitialState {
    double x;
    double y;
    double scale;
    double opacity;
    int alpha_mode;
    double audio_gain;
} TertiaryInitialState;

/* Call with engine mutex held. */
static int add_tertiary_track_locked(
    const char *path,
    int64_t start_frame,
    int64_t end_frame,
    int64_t source_in_frame,
    int64_t source_out_frame,
    const TertiaryInitialState *initial_state)
{
    const mlt_position primary_length =
        mlt_producer_get_length(current_engine()->e_primary_producer);

    if (primary_length <= 0 ||
        current_engine()->e_secondary_playlist == NULL ||
        current_engine()->e_tractor == NULL ||
        current_engine()->e_video_composite == NULL) {
        set_error("Layer 3 requires a complete two-layer composition.");
        return 0;
    }

    const int prior_has_audio = current_engine()->e_has_audio;
    mlt_producer old_top = current_engine()->e_producer;

    mlt_position saved_position =
        mlt_producer_position(old_top);

    if (current_engine()->e_consumer != NULL &&
        !mlt_consumer_is_stopped(current_engine()->e_consumer) &&
        mlt_producer_get_speed(old_top) != 0.0) {
        const double speed = mlt_producer_get_speed(old_top);
        saved_position = mlt_consumer_position(current_engine()->e_consumer);
        if (speed > 0.0) {
            saved_position += 1;
        } else if (speed < 0.0) {
            saved_position -= 1;
        }
    }

    if (saved_position < 0) {
        saved_position = 0;
    }
    if (saved_position >= primary_length) {
        saved_position = primary_length - 1;
    }

    mlt_producer_set_speed(old_top, 0.0);
    close_consumer_locked();

    mlt_producer pending_tertiary = NULL;
    mlt_playlist pending_tertiary_playlist = NULL;
    mlt_tractor pending_tractor = NULL;
    mlt_transition pending_layer2_composite = NULL;
    mlt_transition pending_layer2_mix = NULL;
    mlt_transition pending_layer3_composite = NULL;
    mlt_transition pending_layer3_mix = NULL;
    mlt_filter pending_tertiary_audio_filter = NULL;
    mlt_filter pending_tertiary_alpha_filter = NULL;

    int tertiary_has_audio = 0;
    int tertiary_has_alpha_value = 0;
    int tertiary_still = 0;
    double pending_base_width = 0.0;
    double pending_base_height = 0.0;
    double pending_x = 0.0;
    double pending_y = 0.0;
    double pending_scale = 1.0;
    double pending_opacity = 1.0;
    int pending_alpha_mode = 0;
    double pending_audio_gain = 1.0;
    int succeeded = 0;
    char failure[512] = "";

    const int path_is_still = path_has_still_image_extension(path);

    if (path_is_still) {
        pending_tertiary =
            mlt_factory_producer(current_engine()->e_profile, "pixbuf", path);
        if (pending_tertiary == NULL) {
            pending_tertiary =
                mlt_factory_producer(current_engine()->e_profile, "avformat", path);
        }
    } else {
        pending_tertiary =
            mlt_factory_producer(current_engine()->e_profile, NULL, path);
    }

    if (pending_tertiary == NULL) {
        snprintf(failure, sizeof(failure), "%s", "MLT could not open Layer 3.");
        goto add_tertiary_cleanup;
    }

    if (path_is_still &&
        !attach_still_image_converter_locked(pending_tertiary)) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "Could not install Layer 3 still-image color conversion support."
        );
        goto add_tertiary_cleanup;
    }

    mlt_producer_probe(pending_tertiary);

    const MediaKind tertiary_kind =
        classify_producer_locked(pending_tertiary);

    if ((tertiary_kind != MEDIA_TIMED && tertiary_kind != MEDIA_STILL) ||
        !producer_has_stream_locked(pending_tertiary, "video_index", "video")) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "Layer 3 must be video or a still image."
        );
        goto add_tertiary_cleanup;
    }

    tertiary_still = path_is_still || tertiary_kind == MEDIA_STILL;
    tertiary_has_alpha_value =
        producer_has_alpha_locked(pending_tertiary, tertiary_kind);

    if (tertiary_still &&
        !still_source_is_composite_ready_locked(
            pending_tertiary,
            tertiary_has_alpha_value)) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "Layer 3 could not provide composite-safe YUV422 with alpha."
        );
        goto add_tertiary_cleanup;
    }

    if (!mlt_composition_secondary_base_size(
            current_engine()->e_profile,
            pending_tertiary,
            tertiary_still,
            &pending_base_width,
            &pending_base_height)) {
        snprintf(failure, sizeof(failure), "%s", "Layer 3 has invalid presentation geometry.");
        goto add_tertiary_cleanup;
    }

    pending_x =
        ((double)current_engine()->e_profile->width - pending_base_width) / 2.0;
    pending_y =
        ((double)current_engine()->e_profile->height - pending_base_height) / 2.0;

    if (initial_state != NULL) {
        if (!isfinite(initial_state->x) ||
            !isfinite(initial_state->y) ||
            !isfinite(initial_state->scale) ||
            !isfinite(initial_state->opacity) ||
            !isfinite(initial_state->audio_gain) ||
            initial_state->alpha_mode < 0 ||
            initial_state->alpha_mode > 2) {
            snprintf(
                failure,
                sizeof(failure),
                "%s",
                "Layer 3 restore state is invalid."
            );
            goto add_tertiary_cleanup;
        }

        pending_x = initial_state->x;
        pending_y = initial_state->y;
        pending_scale = CLAMP(initial_state->scale, 0.10, 3.0);
        pending_opacity = CLAMP(initial_state->opacity, 0.0, 1.0);
        pending_alpha_mode = initial_state->alpha_mode;
        pending_audio_gain = CLAMP(initial_state->audio_gain, 0.0, 1.0);
    }

    const mlt_position pending_source_length =
        tertiary_still ? 0 : mlt_producer_get_length(pending_tertiary);
    mlt_position pending_start = 0;
    mlt_position pending_source_in = -1;
    mlt_position pending_source_out = -1;
    const MltSecondaryPlacementResult placement_result =
        mlt_composition_build_secondary_playlist_trimmed(
            current_engine()->e_profile,
            pending_tertiary,
            (mlt_position)start_frame,
            (mlt_position)end_frame,
            (mlt_position)source_in_frame,
            (mlt_position)source_out_frame,
            primary_length,
            tertiary_still,
            &pending_tertiary_playlist,
            &pending_start,
            &pending_source_in,
            &pending_source_out
        );

    if (placement_result != MLT_SECONDARY_PLACEMENT_OK) {
        const char *placement_error = "Could not configure Layer 3 timing and placement.";
        switch (placement_result) {
            case MLT_SECONDARY_PLACEMENT_NO_DURATION:
                placement_error = "Layer 3 reports no usable duration.";
                break;
            case MLT_SECONDARY_PLACEMENT_NO_ROOM:
                placement_error = "There is no room for Layer 3 at that playhead.";
                break;
            case MLT_SECONDARY_PLACEMENT_SOURCE_INIT_FAILED:
                placement_error = "MLT could not initialize Layer 3.";
                break;
            case MLT_SECONDARY_PLACEMENT_PLAYLIST_CREATE_FAILED:
                placement_error = "Could not create the offset playlist for Layer 3.";
                break;
            case MLT_SECONDARY_PLACEMENT_LEAD_IN_FAILED:
                placement_error = "Could not create the blank lead-in for Layer 3.";
                break;
            case MLT_SECONDARY_PLACEMENT_APPEND_FAILED:
                placement_error = "Could not place the added media on Layer 3.";
                break;
            case MLT_SECONDARY_PLACEMENT_INVALID_ARGUMENT:
            case MLT_SECONDARY_PLACEMENT_OK:
            default:
                break;
        }
        snprintf(failure, sizeof(failure), "%s", placement_error);
        goto add_tertiary_cleanup;
    }

    tertiary_has_audio =
        tertiary_still
            ? 0
            : producer_has_stream_locked(pending_tertiary, "audio_index", "audio");

    if (tertiary_has_audio) {
        pending_tertiary_audio_filter =
            attach_track_audio_filter_locked(
                mlt_playlist_producer(pending_tertiary_playlist)
            );
        if (pending_tertiary_audio_filter == NULL) {
            snprintf(failure, sizeof(failure), "%s", "Could not create Layer 3 audio level support.");
            goto add_tertiary_cleanup;
        }

        mlt_service_lock(MLT_FILTER_SERVICE(pending_tertiary_audio_filter));
        mlt_properties_set_double(
            MLT_FILTER_PROPERTIES(pending_tertiary_audio_filter),
            "gain",
            pending_audio_gain
        );
        mlt_service_unlock(MLT_FILTER_SERVICE(pending_tertiary_audio_filter));
    }

    pending_tertiary_alpha_filter =
        attach_secondary_alpha_filter_locked(pending_tertiary);
    if (pending_tertiary_alpha_filter == NULL) {
        snprintf(failure, sizeof(failure), "%s", "Could not create Layer 3 alpha interpretation support.");
        goto add_tertiary_cleanup;
    }

    if (!mlt_composition_apply_alpha_mode(
            pending_tertiary_alpha_filter,
            pending_alpha_mode)) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "Could not apply the restored Layer 3 alpha interpretation."
        );
        goto add_tertiary_cleanup;
    }

    pending_tractor = mlt_tractor_new();
    if (pending_tractor == NULL) {
        snprintf(failure, sizeof(failure), "%s", "Could not create the three-layer MLT tractor.");
        goto add_tertiary_cleanup;
    }

    mlt_service_set_profile(
        MLT_TRACTOR_SERVICE(pending_tractor),
        current_engine()->e_profile
    );

    if (mlt_tractor_set_track(pending_tractor, current_engine()->e_primary_producer, 0) != 0 ||
        mlt_tractor_set_track(
            pending_tractor,
            mlt_playlist_producer(current_engine()->e_secondary_playlist),
            1) != 0 ||
        mlt_tractor_set_track(
            pending_tractor,
            mlt_playlist_producer(pending_tertiary_playlist),
            2) != 0) {
        snprintf(failure, sizeof(failure), "%s", "Could not connect all three layers to the tractor.");
        goto add_tertiary_cleanup;
    }

    mlt_field field = mlt_tractor_field(pending_tractor);
    if (field == NULL) {
        snprintf(failure, sizeof(failure), "%s", "The three-layer tractor did not provide an MLT field.");
        goto add_tertiary_cleanup;
    }

    pending_layer2_composite =
        mlt_factory_transition(current_engine()->e_profile, "composite", NULL);
    if (pending_layer2_composite == NULL ||
        !mlt_composition_configure_transition(
            pending_layer2_composite,
            current_engine()->e_secondary_x,
            current_engine()->e_secondary_y,
            current_engine()->e_secondary_base_width * current_engine()->e_secondary_scale,
            current_engine()->e_secondary_base_height * current_engine()->e_secondary_scale,
            current_engine()->e_secondary_opacity) ||
        mlt_field_plant_transition(field, pending_layer2_composite, 0, 1) != 0) {
        snprintf(failure, sizeof(failure), "%s", "Could not rebuild the Layer 2 video composite.");
        goto add_tertiary_cleanup;
    }

    if (current_engine()->e_track_has_audio[1]) {
        pending_layer2_mix =
            mlt_factory_transition(current_engine()->e_profile, "mix", NULL);
        if (pending_layer2_mix == NULL) {
            snprintf(failure, sizeof(failure), "%s", "Could not rebuild the Layer 2 audio mix.");
            goto add_tertiary_cleanup;
        }
        mlt_properties mix_properties = MLT_TRANSITION_PROPERTIES(pending_layer2_mix);
        mlt_properties_set_int(mix_properties, "always_active", 1);
        mlt_properties_set_double(mix_properties, "start", 1.0);
        mlt_properties_set_double(mix_properties, "end", 1.0);
        mlt_properties_set_int(mix_properties, "sum", 1);
        if (mlt_field_plant_transition(field, pending_layer2_mix, 0, 1) != 0) {
            snprintf(failure, sizeof(failure), "%s", "Could not rebuild the Layer 2 audio transition.");
            goto add_tertiary_cleanup;
        }
    }

    pending_layer3_composite =
        mlt_factory_transition(current_engine()->e_profile, "composite", NULL);
    if (pending_layer3_composite == NULL ||
        !mlt_composition_configure_transition(
            pending_layer3_composite,
            pending_x,
            pending_y,
            pending_base_width * pending_scale,
            pending_base_height * pending_scale,
            pending_opacity) ||
        mlt_field_plant_transition(field, pending_layer3_composite, 0, 2) != 0) {
        snprintf(failure, sizeof(failure), "%s", "Could not plant the Layer 3 video composite.");
        goto add_tertiary_cleanup;
    }

    if (tertiary_has_audio) {
        pending_layer3_mix =
            mlt_factory_transition(current_engine()->e_profile, "mix", NULL);
        if (pending_layer3_mix == NULL) {
            snprintf(failure, sizeof(failure), "%s", "Could not create the Layer 3 audio mix.");
            goto add_tertiary_cleanup;
        }
        mlt_properties mix_properties = MLT_TRANSITION_PROPERTIES(pending_layer3_mix);
        mlt_properties_set_int(mix_properties, "always_active", 1);
        mlt_properties_set_double(mix_properties, "start", 1.0);
        mlt_properties_set_double(mix_properties, "end", 1.0);
        mlt_properties_set_int(mix_properties, "sum", 1);
        if (mlt_field_plant_transition(field, pending_layer3_mix, 0, 2) != 0) {
            snprintf(failure, sizeof(failure), "%s", "Could not plant the Layer 3 audio mix.");
            goto add_tertiary_cleanup;
        }
    }

    mlt_tractor_refresh(pending_tractor);
    mlt_producer pending_top = mlt_tractor_producer(pending_tractor);
    if (pending_top == NULL) {
        snprintf(failure, sizeof(failure), "%s", "The three-layer tractor did not expose a producer.");
        goto add_tertiary_cleanup;
    }

    mlt_producer_set_in_and_out(pending_top, 0, primary_length - 1);
    mlt_producer_set_speed(pending_top, 0.0);
    mlt_producer_seek(pending_top, saved_position);
    current_engine()->e_producer = pending_top;

    if (g_atomic_int_get(&current_engine()->e_preview_enabled)) {
        if (!create_consumer_locked()) {
            snprintf(
                failure,
                sizeof(failure),
                "%s",
                current_engine()->e_last_error[0] != '\0'
                    ? current_engine()->e_last_error
                    : "Could not create preview for the three-layer tractor."
            );
            current_engine()->e_producer = old_top;
            goto add_tertiary_cleanup;
        }

        if (mlt_consumer_start(current_engine()->e_consumer) != 0) {
            snprintf(failure, sizeof(failure), "%s", "MLT could not start three-layer preview.");
            close_consumer_locked();
            current_engine()->e_producer = old_top;
            goto add_tertiary_cleanup;
        }
        refresh_locked();
    }

    /* The new tractor now owns the active graph; retire the old two-layer graph. */
    if (current_engine()->e_tractor != NULL) {
        mlt_tractor_close(current_engine()->e_tractor);
    }
    if (current_engine()->e_video_composite != NULL) {
        mlt_transition_close(current_engine()->e_video_composite);
    }
    if (current_engine()->e_audio_mix != NULL) {
        mlt_transition_close(current_engine()->e_audio_mix);
    }

    current_engine()->e_tractor = pending_tractor;
    current_engine()->e_video_composite = pending_layer2_composite;
    current_engine()->e_audio_mix = pending_layer2_mix;
    current_engine()->e_tertiary_video_composite = pending_layer3_composite;
    current_engine()->e_tertiary_audio_mix = pending_layer3_mix;
    current_engine()->e_tertiary_producer = pending_tertiary;
    current_engine()->e_tertiary_playlist = pending_tertiary_playlist;
    current_engine()->e_tertiary_alpha_filter = pending_tertiary_alpha_filter;
    current_engine()->e_tertiary_has_alpha = tertiary_has_alpha_value ? 1 : 0;
    current_engine()->e_tertiary_alpha_mode = pending_alpha_mode;
    current_engine()->e_tertiary_is_still = tertiary_still ? 1 : 0;
    current_engine()->e_tertiary_start_frame = (int64_t)pending_start;
    current_engine()->e_tertiary_source_in_frame =
        tertiary_still ? -1 : (int64_t)pending_source_in;
    current_engine()->e_tertiary_source_out_frame =
        tertiary_still ? -1 : (int64_t)pending_source_out;
    current_engine()->e_tertiary_source_length_frames =
        tertiary_still ? 0 : (int64_t)pending_source_length;
    current_engine()->e_tertiary_opacity = pending_opacity;
    current_engine()->e_tertiary_x = pending_x;
    current_engine()->e_tertiary_y = pending_y;
    current_engine()->e_tertiary_scale = pending_scale;
    current_engine()->e_tertiary_base_width = pending_base_width;
    current_engine()->e_tertiary_base_height = pending_base_height;
    current_engine()->e_track_has_audio[2] = tertiary_has_audio ? 1 : 0;
    current_engine()->e_track_audio_gain[2] =
        tertiary_has_audio ? pending_audio_gain : 1.0;
    current_engine()->e_track_audio_filters[2] = pending_tertiary_audio_filter;
    current_engine()->e_track_count = 3;
    current_engine()->e_has_audio = prior_has_audio || tertiary_has_audio;

    pending_tertiary = NULL;
    pending_tertiary_playlist = NULL;
    pending_tractor = NULL;
    pending_layer2_composite = NULL;
    pending_layer2_mix = NULL;
    pending_layer3_composite = NULL;
    pending_layer3_mix = NULL;
    pending_tertiary_alpha_filter = NULL;

    set_error(NULL);
    succeeded = 1;

add_tertiary_cleanup:
    if (!succeeded) {
        close_consumer_locked();
        current_engine()->e_producer = old_top;

        if (pending_tractor != NULL) {
            mlt_tractor_close(pending_tractor);
        }
        if (pending_layer2_composite != NULL) {
            mlt_transition_close(pending_layer2_composite);
        }
        if (pending_layer2_mix != NULL) {
            mlt_transition_close(pending_layer2_mix);
        }
        if (pending_layer3_composite != NULL) {
            mlt_transition_close(pending_layer3_composite);
        }
        if (pending_layer3_mix != NULL) {
            mlt_transition_close(pending_layer3_mix);
        }
        if (pending_tertiary_playlist != NULL) {
            mlt_playlist_close(pending_tertiary_playlist);
        }
        if (pending_tertiary != NULL) {
            mlt_producer_close(pending_tertiary);
        }

        if (old_top != NULL) {
            mlt_producer_set_speed(old_top, 0.0);
            mlt_producer_seek(old_top, saved_position);
        }

        if (g_atomic_int_get(&current_engine()->e_preview_enabled) && old_top != NULL) {
            if (create_consumer_locked()) {
                if (mlt_consumer_start(current_engine()->e_consumer) == 0) {
                    refresh_locked();
                } else {
                    close_consumer_locked();
                }
            }
        }

        current_engine()->e_has_audio = prior_has_audio;
        set_error(failure[0] != '\0' ? failure : "Add Layer 3 failed.");
    }

    return succeeded;
}


MLT_BRIDGE_EXPORT
int mlt_bridge_add_layer_with_state_trimmed(
    int layer_index,
    const char *path,
    int64_t start_frame,
    int64_t end_frame,
    int64_t source_in_frame,
    int64_t source_out_frame,
    double x,
    double y,
    double scale,
    double opacity,
    int alpha_mode,
    double audio_gain)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);

    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY ||
        current_engine()->e_track_count != 2 ||
        path == NULL ||
        path[0] == '\0') {
        set_error(
            "Stateful layer insertion currently requires an existing two-layer composition and Layer 3."
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    const TertiaryInitialState initial_state = {
        .x = x,
        .y = y,
        .scale = scale,
        .opacity = opacity,
        .alpha_mode = alpha_mode,
        .audio_gain = audio_gain,
    };

    const int added = add_tertiary_track_locked(
        path,
        start_frame,
        end_frame,
        source_in_frame,
        source_out_frame,
        &initial_state
    );

    g_mutex_unlock(&current_engine()->e_mutex);
    invalidate_frames();
    return added;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_add_layer_with_state(
    int layer_index,
    const char *path,
    int64_t start_frame,
    int64_t end_frame,
    double x,
    double y,
    double scale,
    double opacity,
    int alpha_mode,
    double audio_gain)
{
    return mlt_bridge_add_layer_with_state_trimmed(
        layer_index,
        path,
        start_frame,
        end_frame,
        -1,
        -1,
        x,
        y,
        scale,
        opacity,
        alpha_mode,
        audio_gain
    );
}

static int add_track_with_range(
    const char *path,
    int64_t start_frame,
    int64_t end_frame,
    int64_t source_in_frame,
    int64_t source_out_frame)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (repository == NULL ||
        path == NULL ||
        path[0] == '\0') {
        set_error(
            "MLT is not initialized "
            "or the track path is invalid."
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    if (current_engine()->e_primary_producer == NULL ||
        current_engine()->e_producer == NULL ||
        current_engine()->e_track_count < 1 ||
        current_engine()->e_track_count >= MLT_COMPOSITION_MAX_LAYERS ||
        current_engine()->e_is_still ||
        !current_engine()->e_has_video) {
        set_error(
            "Add to Movie requires a timed video composition with an available layer slot."
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    if (current_engine()->e_track_count == 2) {
        const int added = add_tertiary_track_locked(
            path,
            start_frame,
            end_frame,
            source_in_frame,
            source_out_frame,
            NULL
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        invalidate_frames();
        return added;
    }

    const int primary_has_audio = current_engine()->e_has_audio;

    const mlt_position primary_length =
        mlt_producer_get_length(
            current_engine()->e_primary_producer
        );

    if (primary_length <= 0) {
        set_error("The primary movie has no usable duration.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    /*
     * Park at the viewer-visible frame before the graph is rebuilt. The new
     * tractor starts paused at the same frame; Add to Movie is an edit, not a
     * transport command.
     */
    mlt_position saved_position =
        mlt_producer_position(
            current_engine()->e_producer
        );

    if (current_engine()->e_consumer != NULL &&
        !mlt_consumer_is_stopped(current_engine()->e_consumer) &&
        mlt_producer_get_speed(current_engine()->e_producer) != 0.0) {
        const double speed =
            mlt_producer_get_speed(
                current_engine()->e_producer
            );

        saved_position =
            mlt_consumer_position(
                current_engine()->e_consumer
            );

        if (speed > 0.0) {
            saved_position += 1;
        } else if (speed < 0.0) {
            saved_position -= 1;
        }
    }

    if (saved_position < 0) {
        saved_position = 0;
    }

    if (saved_position >= primary_length) {
        saved_position = primary_length - 1;
    }

    mlt_producer_set_speed(
        current_engine()->e_producer,
        0.0
    );

    close_consumer_locked();

    mlt_producer pending_secondary = NULL;
    mlt_playlist pending_secondary_playlist = NULL;
    mlt_tractor pending_tractor = NULL;
    mlt_transition pending_composite = NULL;
    mlt_transition pending_mix = NULL;
    mlt_filter pending_secondary_audio_filter = NULL;
    mlt_filter pending_secondary_alpha_filter = NULL;

    int secondary_has_audio = 0;
    int secondary_has_alpha_value = 0;
    int secondary_still = 0;
    double pending_base_width = 0.0;
    double pending_base_height = 0.0;
    double pending_x = 0.0;
    double pending_y = 0.0;
    int succeeded = 0;
    char failure[512] = "";

    const int path_is_still =
        path_has_still_image_extension(path);

    /*
     * POC 10.6.2: never let the generic loader choose Qt/QImage for a
     * still-image layer on the helper isolate. MLT's pixbuf producer is a
     * real looping still producer, preserves RGBA alpha, and serializes
     * GdkPixbuf access internally. That makes it safe for the background
     * layer-loading path used by Flutter.
     *
     * Some formats (notably EXR on installations without a matching
     * GdkPixbuf loader) may not be available through pixbuf. Fall back to
     * avformat rather than qimage so still import never initializes Qt from
     * the helper isolate.
     */
    if (path_is_still) {
        pending_secondary =
            mlt_factory_producer(
                current_engine()->e_profile,
                "pixbuf",
                path
            );

        if (pending_secondary == NULL) {
            pending_secondary =
                mlt_factory_producer(
                    current_engine()->e_profile,
                    "avformat",
                    path
                );
        }
    } else {
        pending_secondary =
            mlt_factory_producer(
                current_engine()->e_profile,
                NULL,
                path
            );
    }

    if (pending_secondary == NULL) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "MLT could not open the added layer."
        );
        goto add_track_cleanup;
    }

    if (path_is_still &&
        !attach_still_image_converter_locked(
            pending_secondary
        )) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "Could not install still-image color conversion support."
        );
        goto add_track_cleanup;
    }

    mlt_producer_probe(
        pending_secondary
    );

    const MediaKind secondary_kind =
        classify_producer_locked(
            pending_secondary
        );

    if ((secondary_kind != MEDIA_TIMED &&
         secondary_kind != MEDIA_STILL) ||
        !producer_has_stream_locked(
            pending_secondary,
            "video_index",
            "video")) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "The added layer must be video or a still image."
        );
        goto add_track_cleanup;
    }

    secondary_still =
        path_is_still ||
        secondary_kind == MEDIA_STILL;

    secondary_has_alpha_value =
        producer_has_alpha_locked(
            pending_secondary,
            secondary_kind
        );

    if (secondary_still &&
        !still_source_is_composite_ready_locked(
            pending_secondary,
            secondary_has_alpha_value
        )) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "The still-image layer could not provide composite-safe YUV422 with alpha."
        );
        goto add_track_cleanup;
    }

    if (!mlt_composition_secondary_base_size(
            current_engine()->e_profile,
            pending_secondary,
            secondary_still,
            &pending_base_width,
            &pending_base_height)) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "The added layer has invalid presentation geometry."
        );
        goto add_track_cleanup;
    }

    pending_x =
        ((double)current_engine()->e_profile->width - pending_base_width) / 2.0;
    pending_y =
        ((double)current_engine()->e_profile->height - pending_base_height) / 2.0;

    /*
     * POC 10.3 uses the viewer playhead as the placement point. Preview and
     * export now share the exact same Layer 2 timing/playlist builder.
     */
    const mlt_position pending_source_length =
        secondary_still ? 0 : mlt_producer_get_length(pending_secondary);
    mlt_position pending_start = 0;
    mlt_position pending_source_in = -1;
    mlt_position pending_source_out = -1;

    const MltSecondaryPlacementResult placement_result =
        mlt_composition_build_secondary_playlist_trimmed(
            current_engine()->e_profile,
            pending_secondary,
            (mlt_position)start_frame,
            (mlt_position)end_frame,
            (mlt_position)source_in_frame,
            (mlt_position)source_out_frame,
            primary_length,
            secondary_still,
            &pending_secondary_playlist,
            &pending_start,
            &pending_source_in,
            &pending_source_out
        );

    if (placement_result != MLT_SECONDARY_PLACEMENT_OK) {
        const char *placement_error =
            "Could not configure the added layer's timing and placement.";

        switch (placement_result) {
            case MLT_SECONDARY_PLACEMENT_NO_DURATION:
                placement_error =
                    "The added video layer reports no usable duration.";
                break;

            case MLT_SECONDARY_PLACEMENT_NO_ROOM:
                placement_error =
                    "There is no room for the added layer at that playhead.";
                break;

            case MLT_SECONDARY_PLACEMENT_SOURCE_INIT_FAILED:
                placement_error =
                    "MLT could not initialize the added layer.";
                break;

            case MLT_SECONDARY_PLACEMENT_PLAYLIST_CREATE_FAILED:
                placement_error =
                    "Could not create the offset playlist for layer 2.";
                break;

            case MLT_SECONDARY_PLACEMENT_LEAD_IN_FAILED:
                placement_error =
                    "Could not create the blank lead-in for layer 2.";
                break;

            case MLT_SECONDARY_PLACEMENT_APPEND_FAILED:
                placement_error =
                    "Could not place the added media on layer 2.";
                break;

            case MLT_SECONDARY_PLACEMENT_INVALID_ARGUMENT:
            case MLT_SECONDARY_PLACEMENT_OK:
            default:
                break;
        }

        snprintf(
            failure,
            sizeof(failure),
            "%s",
            placement_error
        );
        goto add_track_cleanup;
    }

    secondary_has_audio =
        secondary_still
            ? 0
            : producer_has_stream_locked(
                  pending_secondary,
                  "audio_index",
                  "audio"
              );

    if (secondary_has_audio) {
        pending_secondary_audio_filter =
            attach_track_audio_filter_locked(
                mlt_playlist_producer(
                    pending_secondary_playlist
                )
            );
    }

    pending_secondary_alpha_filter =
        attach_secondary_alpha_filter_locked(
            pending_secondary
        );

    if (pending_secondary_alpha_filter == NULL) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "Could not create layer alpha interpretation support."
        );
        goto add_track_cleanup;
    }

    pending_tractor =
        mlt_tractor_new();

    if (pending_tractor == NULL) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "Could not create the MLT tractor."
        );
        goto add_track_cleanup;
    }

    /*
     * mlt_tractor_new() is profile-less by itself. MLT++'s
     * Tractor(Profile&) immediately applies the caller's profile; do the same
     * here so tractor FPS/geometry agree with the already-open primary movie.
     */
    mlt_service_set_profile(
        MLT_TRACTOR_SERVICE(
            pending_tractor
        ),
        current_engine()->e_profile
    );

    if (mlt_tractor_set_track(
            pending_tractor,
            current_engine()->e_primary_producer,
            0) != 0 ||
        mlt_tractor_set_track(
            pending_tractor,
            mlt_playlist_producer(
                pending_secondary_playlist
            ),
            1) != 0) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "Could not connect both movies to the tractor."
        );
        goto add_track_cleanup;
    }

    mlt_field field =
        mlt_tractor_field(
            pending_tractor
        );

    if (field == NULL) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "The tractor did not provide an MLT field."
        );
        goto add_track_cleanup;
    }

    pending_composite =
        mlt_factory_transition(
            current_engine()->e_profile,
            "composite",
            NULL
        );

    if (pending_composite == NULL) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "MLT's core composite transition is unavailable."
        );
        goto add_track_cleanup;
    }

    /*
     * Track 0 is the base movie and Track 1 is an explicitly positioned
     * overlay rectangle. Preview and export intentionally share one
     * configuration function so compositor policy cannot drift.
     */
    if (!mlt_composition_configure_transition(
            pending_composite,
            pending_x,
            pending_y,
            pending_base_width,
            pending_base_height,
            1.0)) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "Could not configure the video composite transition."
        );
        goto add_track_cleanup;
    }

    if (mlt_field_plant_transition(
            field,
            pending_composite,
            0,
            1) != 0) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "Could not plant the video composite transition."
        );
        goto add_track_cleanup;
    }

    if (secondary_has_audio) {
        pending_mix =
            mlt_factory_transition(
                current_engine()->e_profile,
                "mix",
                NULL
            );

        if (pending_mix == NULL) {
            snprintf(
                failure,
                sizeof(failure),
                "%s",
                "MLT's core audio mix transition is unavailable."
            );
            goto add_track_cleanup;
        }

        mlt_properties mix_properties =
            MLT_TRANSITION_PROPERTIES(
                pending_mix
            );

        mlt_properties_set_int(
            mix_properties,
            "always_active",
            1
        );
        mlt_properties_set_double(
            mix_properties,
            "start",
            1.0
        );
        mlt_properties_set_double(
            mix_properties,
            "end",
            1.0
        );
        /*
         * The default mix algorithm crossfades: mix=1.0 means B only.
         * Add to Movie needs both tracks at full level, so use MLT's sum
         * mode where mix=1.0 means A + B. POC 10.5 applies independent
         * per-track gain before this mix; limiting remains a later concern.
         */
        mlt_properties_set_int(
            mix_properties,
            "sum",
            1
        );

        if (mlt_field_plant_transition(
                field,
                pending_mix,
                0,
                1) != 0) {
            snprintf(
                failure,
                sizeof(failure),
                "%s",
                "Could not plant the audio mix transition."
            );
            goto add_track_cleanup;
        }
    }

    mlt_tractor_refresh(
        pending_tractor
    );

    mlt_producer pending_top =
        mlt_tractor_producer(
            pending_tractor
        );

    if (pending_top == NULL) {
        snprintf(
            failure,
            sizeof(failure),
            "%s",
            "The tractor did not expose a producer."
        );
        goto add_track_cleanup;
    }

    /*
     * Keep the primary movie authoritative even though mlt_multitrack_refresh
     * normally reports the longest connected track.
     */
    mlt_producer_set_in_and_out(
        pending_top,
        0,
        primary_length - 1
    );
    mlt_producer_set_speed(
        pending_top,
        0.0
    );
    mlt_producer_seek(
        pending_top,
        saved_position
    );

    current_engine()->e_producer = pending_top;

    if (g_atomic_int_get(
            &current_engine()->e_preview_enabled)) {
        if (!create_consumer_locked()) {
            snprintf(
                failure,
                sizeof(failure),
                "%s",
                current_engine()->e_last_error[0] != '\0'
                    ? current_engine()->e_last_error
                    : "Could not create preview for the tractor."
            );
            current_engine()->e_producer = current_engine()->e_primary_producer;
            goto add_track_cleanup;
        }

        if (mlt_consumer_start(current_engine()->e_consumer) != 0) {
            snprintf(
                failure,
                sizeof(failure),
                "%s",
                "MLT could not start tractor preview."
            );
            close_consumer_locked();
            current_engine()->e_producer = current_engine()->e_primary_producer;
            goto add_track_cleanup;
        }

        refresh_locked();
    }

    current_engine()->e_secondary_producer = pending_secondary;
    current_engine()->e_secondary_playlist = pending_secondary_playlist;
    current_engine()->e_tractor = pending_tractor;
    current_engine()->e_video_composite = pending_composite;
    current_engine()->e_audio_mix = pending_mix;
    current_engine()->e_track_count = 2;
    current_engine()->e_secondary_start_frame = (int64_t)pending_start;
    current_engine()->e_secondary_source_in_frame =
        secondary_still ? -1 : (int64_t)pending_source_in;
    current_engine()->e_secondary_source_out_frame =
        secondary_still ? -1 : (int64_t)pending_source_out;
    current_engine()->e_secondary_source_length_frames =
        secondary_still ? 0 : (int64_t)pending_source_length;
    current_engine()->e_secondary_opacity = 1.0;
    current_engine()->e_secondary_x = pending_x;
    current_engine()->e_secondary_y = pending_y;
    current_engine()->e_secondary_scale = 1.0;
    current_engine()->e_secondary_base_width = pending_base_width;
    current_engine()->e_secondary_base_height = pending_base_height;
    current_engine()->e_secondary_alpha_filter = pending_secondary_alpha_filter;
    current_engine()->e_secondary_has_alpha = secondary_has_alpha_value ? 1 : 0;
    current_engine()->e_secondary_alpha_mode = 0;
    current_engine()->e_secondary_is_still = secondary_still ? 1 : 0;

    current_engine()->e_track_has_audio[1] = secondary_has_audio ? 1 : 0;
    current_engine()->e_track_audio_gain[1] = 1.0;
    current_engine()->e_track_audio_filters[1] = pending_secondary_audio_filter;

    current_engine()->e_has_audio = primary_has_audio || secondary_has_audio;

    pending_secondary = NULL;
    pending_secondary_playlist = NULL;
    pending_tractor = NULL;
    pending_composite = NULL;
    pending_mix = NULL;
    pending_secondary_alpha_filter = NULL;

    set_error(NULL);
    succeeded = 1;

add_track_cleanup:
    if (!succeeded) {
        close_consumer_locked();

        current_engine()->e_producer = current_engine()->e_primary_producer;

        if (pending_tractor != NULL) {
            mlt_tractor_close(
                pending_tractor
            );
            pending_tractor = NULL;
        }

        if (pending_composite != NULL) {
            mlt_transition_close(
                pending_composite
            );
            pending_composite = NULL;
        }

        if (pending_mix != NULL) {
            mlt_transition_close(
                pending_mix
            );
            pending_mix = NULL;
        }

        if (pending_secondary_playlist != NULL) {
            mlt_playlist_close(
                pending_secondary_playlist
            );
            pending_secondary_playlist = NULL;
        }

        if (pending_secondary != NULL) {
            mlt_producer_close(
                pending_secondary
            );
            pending_secondary = NULL;
        }

        if (current_engine()->e_primary_producer != NULL) {
            mlt_producer_set_speed(
                current_engine()->e_primary_producer,
                0.0
            );
            mlt_producer_seek(
                current_engine()->e_primary_producer,
                saved_position
            );
        }

        /*
         * Restore the pre-edit viewer graph. Failure to restore preview is
         * secondary to the original Add to Movie failure, so preserve that
         * message for Dart.
         */
        if (g_atomic_int_get(
                &current_engine()->e_preview_enabled) &&
            current_engine()->e_primary_producer != NULL) {
            if (create_consumer_locked()) {
                if (mlt_consumer_start(current_engine()->e_consumer) == 0) {
                    refresh_locked();
                } else {
                    close_consumer_locked();
                }
            }
        }

        set_error(
            failure[0] != '\0'
                ? failure
                : "Add to Movie failed."
        );
        current_engine()->e_has_audio = primary_has_audio;
    }

    g_mutex_unlock(&current_engine()->e_mutex);

    invalidate_frames();

    return succeeded;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_add_track(
    const char *path,
    int64_t start_frame)
{
    return add_track_with_range(path, start_frame, -1, -1, -1);
}

MLT_BRIDGE_EXPORT
int mlt_bridge_add_track_bounded(
    const char *path,
    int64_t start_frame,
    int64_t end_frame)
{
    return add_track_with_range(path, start_frame, end_frame, -1, -1);
}

MLT_BRIDGE_EXPORT
int mlt_bridge_add_track_bounded_source(
    const char *path,
    int64_t start_frame,
    int64_t end_frame,
    int64_t source_in_frame,
    int64_t source_out_frame)
{
    return add_track_with_range(
        path,
        start_frame,
        end_frame,
        source_in_frame,
        source_out_frame
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_track_count(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int result = current_engine()->e_track_count;
    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_secondary_start_frame(void)
{
    if (require_current_engine() == NULL) {
        return -1;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int64_t result =
        current_engine()->e_track_count >= 2
            ? current_engine()->e_secondary_start_frame
            : -1;
    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_layer_end_frame(int layer_index)
{
    if (layer_index == MLT_COMPOSITION_BASE_LAYER) {
        if (require_current_engine() == NULL) {
            return -1;
        }
        ensure_locks();
        g_mutex_lock(&current_engine()->e_mutex);
        const int64_t result =
            current_engine()->e_primary_producer != NULL
                ? (int64_t)mlt_producer_get_length(
                      current_engine()->e_primary_producer
                  ) - 1
                : -1;
        g_mutex_unlock(&current_engine()->e_mutex);
        return result;
    }

    if (require_current_engine() == NULL) {
        return -1;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);

    mlt_playlist playlist = NULL;
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY &&
        current_engine()->e_track_count >= 2) {
        playlist = current_engine()->e_secondary_playlist;
    } else if (layer_index == MLT_COMPOSITION_SECOND_OVERLAY &&
               current_engine()->e_track_count >= 3) {
        playlist = current_engine()->e_tertiary_playlist;
    }

    const int64_t result =
        playlist != NULL
            ? (int64_t)mlt_producer_get_length(
                  mlt_playlist_producer(playlist)
              ) - 1
            : -1;

    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_layer_source_in_frame(int layer_index)
{
    if (require_current_engine() == NULL) {
        return -1;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);

    int64_t result = -1;
    if (layer_index == MLT_COMPOSITION_BASE_LAYER &&
        current_engine()->e_primary_producer != NULL) {
        result = 0;
    } else if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY &&
               current_engine()->e_track_count >= 2 &&
               !current_engine()->e_secondary_is_still) {
        result = current_engine()->e_secondary_source_in_frame;
    } else if (layer_index == MLT_COMPOSITION_SECOND_OVERLAY &&
               current_engine()->e_track_count >= 3 &&
               !current_engine()->e_tertiary_is_still) {
        result = current_engine()->e_tertiary_source_in_frame;
    }

    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_layer_source_out_frame(int layer_index)
{
    if (require_current_engine() == NULL) {
        return -1;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);

    int64_t result = -1;
    if (layer_index == MLT_COMPOSITION_BASE_LAYER &&
        current_engine()->e_primary_producer != NULL) {
        result = (int64_t)mlt_producer_get_length(
            current_engine()->e_primary_producer
        ) - 1;
    } else if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY &&
               current_engine()->e_track_count >= 2 &&
               !current_engine()->e_secondary_is_still) {
        result = current_engine()->e_secondary_source_out_frame;
    } else if (layer_index == MLT_COMPOSITION_SECOND_OVERLAY &&
               current_engine()->e_track_count >= 3 &&
               !current_engine()->e_tertiary_is_still) {
        result = current_engine()->e_tertiary_source_out_frame;
    }

    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_layer_source_length_frames(int layer_index)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);

    int64_t result = 0;
    if (layer_index == MLT_COMPOSITION_BASE_LAYER &&
        current_engine()->e_primary_producer != NULL) {
        result = (int64_t)mlt_producer_get_length(
            current_engine()->e_primary_producer
        );
    } else if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY &&
               current_engine()->e_track_count >= 2 &&
               !current_engine()->e_secondary_is_still) {
        result = current_engine()->e_secondary_source_length_frames;
    } else if (layer_index == MLT_COMPOSITION_SECOND_OVERLAY &&
               current_engine()->e_track_count >= 3 &&
               !current_engine()->e_tertiary_is_still) {
        result = current_engine()->e_tertiary_source_length_frames;
    }

    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_set_secondary_opacity(
    double opacity)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_track_count < 2 ||
        current_engine()->e_video_composite == NULL) {
        set_error(
            "Layer 2 opacity requires a two-layer composition."
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    if (!isfinite(opacity)) {
        set_error("Layer 2 opacity must be a finite value.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    if (opacity < 0.0) {
        opacity = 0.0;
    } else if (opacity > 1.0) {
        opacity = 1.0;
    }

    const double previous =
        current_engine()->e_secondary_opacity;
    current_engine()->e_secondary_opacity = opacity;

    /*
     * POC 10.8 routes opacity through the shared geometry writer so changing
     * opacity never resets Layer 2 position or scale back to the old full-frame
     * rectangle.
     */
    if (!apply_secondary_geometry_locked()) {
        current_engine()->e_secondary_opacity = previous;
        set_error("Could not apply Layer 2 opacity.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    set_error(NULL);
    g_mutex_unlock(&current_engine()->e_mutex);
    return 1;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_secondary_opacity(void)
{
    if (require_current_engine() == NULL) {
        return 0.0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    double result = 1.0;

    if (current_engine()->e_track_count >= 2 &&
        current_engine()->e_video_composite != NULL) {
        /*
         * Read the value MLT will actually apply, rather than only returning
         * the bridge's requested cache. This makes the public getter and the
         * smoke test catch geometry-encoding mistakes such as supplying 35.0
         * where MLT's rect opacity field expects 0.35.
         */
        mlt_service_lock(
            MLT_TRANSITION_SERVICE(
                current_engine()->e_video_composite
            )
        );

        const mlt_rect applied =
            mlt_properties_anim_get_rect(
                MLT_TRANSITION_PROPERTIES(
                    current_engine()->e_video_composite
                ),
                "geometry",
                0,
                0
            );

        mlt_service_unlock(
            MLT_TRANSITION_SERVICE(
                current_engine()->e_video_composite
            )
        );

        if (applied.o == DBL_MIN) {
            result = 1.0;
        } else {
            result = applied.o;
        }
    }

    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}


MLT_BRIDGE_EXPORT
int mlt_bridge_set_secondary_geometry(
    double x,
    double y,
    double scale)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_track_count < 2 ||
        current_engine()->e_video_composite == NULL) {
        set_error(
            "Layer 2 geometry requires a two-layer composition."
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    if (!isfinite(x) ||
        !isfinite(y) ||
        !isfinite(scale)) {
        set_error("Layer 2 geometry values must be finite.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    if (scale < 0.10) {
        scale = 0.10;
    } else if (scale > 3.0) {
        scale = 3.0;
    }

    const double old_x = current_engine()->e_secondary_x;
    const double old_y = current_engine()->e_secondary_y;
    const double old_scale = current_engine()->e_secondary_scale;

    current_engine()->e_secondary_x = x;
    current_engine()->e_secondary_y = y;
    current_engine()->e_secondary_scale = scale;

    if (!apply_secondary_geometry_locked()) {
        current_engine()->e_secondary_x = old_x;
        current_engine()->e_secondary_y = old_y;
        current_engine()->e_secondary_scale = old_scale;
        set_error("Could not apply Layer 2 geometry.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    set_error(NULL);
    g_mutex_unlock(&current_engine()->e_mutex);
    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_set_secondary_anchor(
    int anchor)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_track_count < 2 ||
        current_engine()->e_video_composite == NULL ||
        current_engine()->e_profile == NULL ||
        anchor < 0 ||
        anchor > 8) {
        set_error("Layer 2 anchor requires a valid two-layer composition.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    const double width =
        current_engine()->e_secondary_base_width *
        current_engine()->e_secondary_scale;
    const double height =
        current_engine()->e_secondary_base_height *
        current_engine()->e_secondary_scale;

    if (!isfinite(width) ||
        !isfinite(height) ||
        width <= 0.0 ||
        height <= 0.0) {
        set_error("Layer 2 has invalid presentation geometry.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    const int column = anchor % 3;
    const int row = anchor / 3;

    const double available_x =
        (double)current_engine()->e_profile->width - width;
    const double available_y =
        (double)current_engine()->e_profile->height - height;

    const double old_x = current_engine()->e_secondary_x;
    const double old_y = current_engine()->e_secondary_y;

    current_engine()->e_secondary_x =
        column == 0
            ? 0.0
            : (column == 1
                   ? available_x / 2.0
                   : available_x);
    current_engine()->e_secondary_y =
        row == 0
            ? 0.0
            : (row == 1
                   ? available_y / 2.0
                   : available_y);

    if (!apply_secondary_geometry_locked()) {
        current_engine()->e_secondary_x = old_x;
        current_engine()->e_secondary_y = old_y;
        set_error("Could not apply the Layer 2 anchor.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    set_error(NULL);
    g_mutex_unlock(&current_engine()->e_mutex);
    return 1;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_secondary_x(void)
{
    if (require_current_engine() == NULL) {
        return 0.0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    double result =
        current_engine()->e_track_count >= 2
            ? current_engine()->e_secondary_x
            : 0.0;

    mlt_rect rect;
    if (read_secondary_rect_locked(&rect)) {
        result = rect.x;
    }

    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_secondary_y(void)
{
    if (require_current_engine() == NULL) {
        return 0.0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    double result =
        current_engine()->e_track_count >= 2
            ? current_engine()->e_secondary_y
            : 0.0;

    mlt_rect rect;
    if (read_secondary_rect_locked(&rect)) {
        result = rect.y;
    }

    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_secondary_scale(void)
{
    if (require_current_engine() == NULL) {
        return 1.0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    double result =
        current_engine()->e_track_count >= 2
            ? current_engine()->e_secondary_scale
            : 1.0;

    mlt_rect rect;
    if (current_engine()->e_secondary_base_width > 0.0 &&
        read_secondary_rect_locked(&rect)) {
        result = rect.w / current_engine()->e_secondary_base_width;
    }

    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_secondary_is_still(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int result =
        current_engine()->e_track_count >= 2
            ? current_engine()->e_secondary_is_still
            : 0;
    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_secondary_has_alpha(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int result =
        current_engine()->e_track_count >= 2
            ? current_engine()->e_secondary_has_alpha
            : 0;
    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_set_secondary_alpha_mode(
    int mode)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_track_count < 2 ||
        current_engine()->e_secondary_alpha_filter == NULL) {
        set_error(
            "Alpha interpretation requires a second layer."
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    if (mode < 0 || mode > 2) {
        set_error(
            "Alpha interpretation must be Auto, Straight, or Premultiplied."
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    if (!mlt_composition_apply_alpha_mode(
            current_engine()->e_secondary_alpha_filter,
            mode)) {
        set_error("Could not apply Layer 2 alpha interpretation.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    current_engine()->e_secondary_alpha_mode = mode;
    set_error(NULL);

    invalidate_frames();
    refresh_locked();

    g_mutex_unlock(&current_engine()->e_mutex);
    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_secondary_alpha_mode(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    int result = 0;

    if (current_engine()->e_track_count >= 2 &&
        current_engine()->e_secondary_alpha_filter != NULL) {
        mlt_service_lock(
            MLT_FILTER_SERVICE(
                current_engine()->e_secondary_alpha_filter
            )
        );

        result =
            mlt_properties_get_int(
                MLT_FILTER_PROPERTIES(
                    current_engine()->e_secondary_alpha_filter
                ),
                "mlt_player_alpha_mode"
            );

        mlt_service_unlock(
            MLT_FILTER_SERVICE(
                current_engine()->e_secondary_alpha_filter
            )
        );
    }

    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_layer_start_frame(int layer_index)
{
    if (layer_index == MLT_COMPOSITION_BASE_LAYER) {
        return 0;
    }
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) {
        return mlt_bridge_secondary_start_frame();
    }
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY ||
        require_current_engine() == NULL) {
        return -1;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const int64_t result =
        current_engine()->e_track_count >= 3
            ? current_engine()->e_tertiary_start_frame
            : -1;
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_set_layer_opacity(int layer_index, double opacity)
{
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) {
        return mlt_bridge_set_secondary_opacity(opacity);
    }
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY ||
        require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_track_count < 3 ||
        current_engine()->e_tertiary_video_composite == NULL) {
        set_error("Layer 3 opacity requires a three-layer composition.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }
    if (!isfinite(opacity)) {
        set_error("Layer 3 opacity must be a finite value.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    opacity = CLAMP(opacity, 0.0, 1.0);
    const double previous = current_engine()->e_tertiary_opacity;
    current_engine()->e_tertiary_opacity = opacity;
    if (!apply_tertiary_geometry_locked()) {
        current_engine()->e_tertiary_opacity = previous;
        set_error("Could not apply Layer 3 opacity.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    set_error(NULL);
    g_mutex_unlock(&current_engine()->e_mutex);
    return 1;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_layer_opacity(int layer_index)
{
    if (layer_index == MLT_COMPOSITION_BASE_LAYER) {
        return 1.0;
    }
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) {
        return mlt_bridge_secondary_opacity();
    }
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY ||
        require_current_engine() == NULL) {
        return 0.0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    double result = current_engine()->e_track_count >= 3
        ? current_engine()->e_tertiary_opacity
        : 1.0;
    mlt_rect rect;
    if (read_tertiary_rect_locked(&rect)) {
        result = rect.o == DBL_MIN ? 1.0 : rect.o;
    }
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_set_layer_geometry(
    int layer_index,
    double x,
    double y,
    double scale)
{
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) {
        return mlt_bridge_set_secondary_geometry(x, y, scale);
    }
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY ||
        require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_track_count < 3 ||
        current_engine()->e_tertiary_video_composite == NULL) {
        set_error("Layer 3 geometry requires a three-layer composition.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }
    if (!isfinite(x) || !isfinite(y) || !isfinite(scale)) {
        set_error("Layer 3 geometry values must be finite.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    scale = CLAMP(scale, 0.10, 3.0);
    const double old_x = current_engine()->e_tertiary_x;
    const double old_y = current_engine()->e_tertiary_y;
    const double old_scale = current_engine()->e_tertiary_scale;
    current_engine()->e_tertiary_x = x;
    current_engine()->e_tertiary_y = y;
    current_engine()->e_tertiary_scale = scale;

    if (!apply_tertiary_geometry_locked()) {
        current_engine()->e_tertiary_x = old_x;
        current_engine()->e_tertiary_y = old_y;
        current_engine()->e_tertiary_scale = old_scale;
        set_error("Could not apply Layer 3 geometry.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    set_error(NULL);
    g_mutex_unlock(&current_engine()->e_mutex);
    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_set_layer_anchor(int layer_index, int anchor)
{
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) {
        return mlt_bridge_set_secondary_anchor(anchor);
    }
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY ||
        require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_track_count < 3 ||
        current_engine()->e_tertiary_video_composite == NULL ||
        current_engine()->e_profile == NULL ||
        anchor < 0 || anchor > 8) {
        set_error("Layer 3 anchor requires a valid three-layer composition.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    const double width = current_engine()->e_tertiary_base_width * current_engine()->e_tertiary_scale;
    const double height = current_engine()->e_tertiary_base_height * current_engine()->e_tertiary_scale;
    if (!isfinite(width) || !isfinite(height) || width <= 0.0 || height <= 0.0) {
        set_error("Layer 3 has invalid presentation geometry.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    const int column = anchor % 3;
    const int row = anchor / 3;
    const double available_x = (double)current_engine()->e_profile->width - width;
    const double available_y = (double)current_engine()->e_profile->height - height;
    const double old_x = current_engine()->e_tertiary_x;
    const double old_y = current_engine()->e_tertiary_y;

    current_engine()->e_tertiary_x = column == 0 ? 0.0 : (column == 1 ? available_x / 2.0 : available_x);
    current_engine()->e_tertiary_y = row == 0 ? 0.0 : (row == 1 ? available_y / 2.0 : available_y);

    if (!apply_tertiary_geometry_locked()) {
        current_engine()->e_tertiary_x = old_x;
        current_engine()->e_tertiary_y = old_y;
        set_error("Could not apply the Layer 3 anchor.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    set_error(NULL);
    g_mutex_unlock(&current_engine()->e_mutex);
    return 1;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_layer_x(int layer_index)
{
    if (layer_index == MLT_COMPOSITION_BASE_LAYER) return 0.0;
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) return mlt_bridge_secondary_x();
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY || require_current_engine() == NULL) return 0.0;
    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    double result = current_engine()->e_track_count >= 3 ? current_engine()->e_tertiary_x : 0.0;
    mlt_rect rect;
    if (read_tertiary_rect_locked(&rect)) result = rect.x;
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_layer_y(int layer_index)
{
    if (layer_index == MLT_COMPOSITION_BASE_LAYER) return 0.0;
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) return mlt_bridge_secondary_y();
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY || require_current_engine() == NULL) return 0.0;
    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    double result = current_engine()->e_track_count >= 3 ? current_engine()->e_tertiary_y : 0.0;
    mlt_rect rect;
    if (read_tertiary_rect_locked(&rect)) result = rect.y;
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_layer_scale(int layer_index)
{
    if (layer_index == MLT_COMPOSITION_BASE_LAYER) return 1.0;
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) return mlt_bridge_secondary_scale();
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY || require_current_engine() == NULL) return 1.0;
    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    double result = current_engine()->e_track_count >= 3 ? current_engine()->e_tertiary_scale : 1.0;
    mlt_rect rect;
    if (current_engine()->e_tertiary_base_width > 0.0 && read_tertiary_rect_locked(&rect)) {
        result = rect.w / current_engine()->e_tertiary_base_width;
    }
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_layer_is_still(int layer_index)
{
    if (layer_index == MLT_COMPOSITION_BASE_LAYER) return 0;
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) return mlt_bridge_secondary_is_still();
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY || require_current_engine() == NULL) return 0;
    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const int result = current_engine()->e_track_count >= 3 ? current_engine()->e_tertiary_is_still : 0;
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_layer_has_alpha(int layer_index)
{
    if (layer_index == MLT_COMPOSITION_BASE_LAYER) return 0;
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) return mlt_bridge_secondary_has_alpha();
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY || require_current_engine() == NULL) return 0;
    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const int result = current_engine()->e_track_count >= 3 ? current_engine()->e_tertiary_has_alpha : 0;
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_set_layer_alpha_mode(int layer_index, int mode)
{
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) {
        return mlt_bridge_set_secondary_alpha_mode(mode);
    }
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY || require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    if (current_engine()->e_track_count < 3 || current_engine()->e_tertiary_alpha_filter == NULL) {
        set_error("Alpha interpretation requires Layer 3.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }
    if (mode < 0 || mode > 2) {
        set_error("Alpha interpretation must be Auto, Straight, or Premultiplied.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }
    if (!mlt_composition_apply_alpha_mode(current_engine()->e_tertiary_alpha_filter, mode)) {
        set_error("Could not apply Layer 3 alpha interpretation.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }
    current_engine()->e_tertiary_alpha_mode = mode;
    set_error(NULL);
    invalidate_frames();
    refresh_locked();
    g_mutex_unlock(&current_engine()->e_mutex);
    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_layer_alpha_mode(int layer_index)
{
    if (layer_index == MLT_COMPOSITION_BASE_LAYER) return 0;
    if (layer_index == MLT_COMPOSITION_FIRST_OVERLAY) return mlt_bridge_secondary_alpha_mode();
    if (layer_index != MLT_COMPOSITION_SECOND_OVERLAY || require_current_engine() == NULL) return 0;
    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    int result = 0;
    if (current_engine()->e_track_count >= 3 && current_engine()->e_tertiary_alpha_filter != NULL) {
        mlt_service_lock(MLT_FILTER_SERVICE(current_engine()->e_tertiary_alpha_filter));
        result = mlt_properties_get_int(
            MLT_FILTER_PROPERTIES(current_engine()->e_tertiary_alpha_filter),
            "mlt_player_alpha_mode"
        );
        mlt_service_unlock(MLT_FILTER_SERVICE(current_engine()->e_tertiary_alpha_filter));
    }
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}


MLT_BRIDGE_EXPORT
int mlt_bridge_track_has_audio(
    int track_index)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const int result =
        track_index >= 0 &&
        track_index < current_engine()->e_track_count &&
        track_index < MLT_COMPOSITION_MAX_LAYERS
            ? current_engine()->e_track_has_audio[track_index]
            : 0;

    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_set_track_audio_gain(
    int track_index,
    double gain)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (track_index < 0 ||
        track_index >= current_engine()->e_track_count ||
        track_index >= MLT_COMPOSITION_MAX_LAYERS) {
        set_error(
            "That track is not available."
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    if (!current_engine()->e_track_has_audio[track_index]) {
        set_error(
            "That track has no audio."
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    mlt_filter filter =
        current_engine()->e_track_audio_filters[track_index];

    if (filter == NULL) {
        set_error(
            "MLT's volume filter is unavailable for that track."
        );
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    if (gain < 0.0) {
        gain = 0.0;
    } else if (gain > 1.0) {
        gain = 1.0;
    }

    mlt_service_lock(
        MLT_FILTER_SERVICE(filter)
    );

    mlt_properties_set_double(
        MLT_FILTER_PROPERTIES(filter),
        "gain",
        gain
    );

    mlt_service_unlock(
        MLT_FILTER_SERVICE(filter)
    );

    current_engine()->e_track_audio_gain[track_index] = gain;
    set_error(NULL);

    g_mutex_unlock(&current_engine()->e_mutex);

    return 1;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_track_audio_gain(
    int track_index)
{
    if (require_current_engine() == NULL) {
        return 0.0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    double result = 1.0;

    if (track_index >= 0 &&
        track_index < current_engine()->e_track_count &&
        track_index < MLT_COMPOSITION_MAX_LAYERS) {
        mlt_filter filter =
            current_engine()->e_track_audio_filters[track_index];

        if (filter != NULL) {
            mlt_service_lock(
                MLT_FILTER_SERVICE(filter)
            );

            result =
                mlt_properties_get_double(
                    MLT_FILTER_PROPERTIES(filter),
                    "gain"
                );

            mlt_service_unlock(
                MLT_FILTER_SERVICE(filter)
            );
        } else {
            result =
                current_engine()->e_track_audio_gain[track_index];
        }
    }

    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
void mlt_bridge_close_media(void)
{
    if (require_current_engine() == NULL) {
        return;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    close_producer_locked();

    g_mutex_unlock(&current_engine()->e_mutex);

    release_slots();
}

MLT_BRIDGE_EXPORT
int mlt_bridge_set_play_all_frames(
    int enabled)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const int requested = enabled != 0;
    const int previous_requested = current_engine()->e_requested_play_all_frames;

    if (requested == previous_requested) {
        g_mutex_unlock(&current_engine()->e_mutex);

        return 1;
    }

    current_engine()->e_requested_play_all_frames = requested;

    /*
     * MLT copies real_time into consumer-private state when the consumer
     * starts, so changing the property on a running consumer is not enough.
     * Rebuild only the consumer, preserving the viewer-visible frame and the
     * producer's current shuttle speed.
     */
    if (current_engine()->e_producer != NULL && current_engine()->e_consumer != NULL) {
        const double speed =
            mlt_producer_get_speed(current_engine()->e_producer);

        const mlt_position length =
            mlt_producer_get_length(current_engine()->e_producer);

        mlt_position position =
            mlt_producer_position(current_engine()->e_producer);

        if (!mlt_consumer_is_stopped(current_engine()->e_consumer) &&
            speed != 0.0) {
            position =
                mlt_consumer_position(current_engine()->e_consumer);

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

        mlt_producer_set_speed(current_engine()->e_producer, 0.0);
        close_consumer_locked();
        mlt_producer_seek(current_engine()->e_producer, position);

        if (!create_consumer_locked()) {
            current_engine()->e_requested_play_all_frames = previous_requested;

            g_mutex_unlock(&current_engine()->e_mutex);

            invalidate_frames();

            return 0;
        }

        mlt_producer_set_speed(current_engine()->e_producer, speed);

        if (mlt_consumer_start(current_engine()->e_consumer) != 0) {
            set_error(
                "MLT could not restart playback "
                "after changing Play All Frames."
            );

            close_consumer_locked();
            current_engine()->e_requested_play_all_frames = previous_requested;

            g_mutex_unlock(&current_engine()->e_mutex);

            invalidate_frames();

            return 0;
        }

        refresh_locked();
        set_error(NULL);
    }

    g_mutex_unlock(&current_engine()->e_mutex);

    invalidate_frames();

    return 1;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_play_all_frames(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const int enabled =
        current_engine()->e_requested_play_all_frames;

    g_mutex_unlock(&current_engine()->e_mutex);

    return enabled;
}

/* ------------------------------------------------------------------------- */
/* Transport                                                                 */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT
int mlt_bridge_set_speed(
    double speed)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    if (speed == 0.0) {
        return mlt_bridge_pause();
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_producer == NULL || current_engine()->e_is_still) {
        set_error("No timed media is loaded.");

        g_mutex_unlock(&current_engine()->e_mutex);

        return 0;
    }

    if (!create_consumer_locked()) {
        g_mutex_unlock(&current_engine()->e_mutex);

        return 0;
    }

    const double current_speed =
        mlt_producer_get_speed(current_engine()->e_producer);

    const mlt_position length =
        mlt_producer_get_length(current_engine()->e_producer);

    mlt_position position =
        mlt_producer_position(current_engine()->e_producer);

    int repositioned = 0;

    /*
     * The producer can be several frames ahead of what the consumer has
     * actually shown. When shuttle speed changes, anchor the producer to
     * the visible position before changing direction or magnitude. This
     * avoids a small but very noticeable jump when tapping J or L.
     */
    if (current_engine()->e_consumer != NULL &&
        !mlt_consumer_is_stopped(current_engine()->e_consumer) &&
        current_speed != 0.0) {
        position =
            mlt_consumer_position(current_engine()->e_consumer);

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

        mlt_consumer_purge(current_engine()->e_consumer);
        mlt_producer_seek(current_engine()->e_producer, position);

        repositioned = 1;
    }

    if (speed > 0.0 &&
        length > 0 &&
        position >= length - 1) {
        mlt_consumer_purge(current_engine()->e_consumer);
        mlt_producer_seek(current_engine()->e_producer, 0);

        repositioned = 1;
    } else if (speed < 0.0 &&
               length > 0 &&
               position <= 0) {
        mlt_consumer_purge(current_engine()->e_consumer);
        mlt_producer_seek(current_engine()->e_producer, length - 1);

        repositioned = 1;
    }

    mlt_producer_set_speed(current_engine()->e_producer, speed);

    if (!ensure_consumer_running_locked()) {
        g_mutex_unlock(&current_engine()->e_mutex);

        return 0;
    }

    refresh_locked();

    set_error(NULL);

    g_mutex_unlock(&current_engine()->e_mutex);

    if (repositioned) {
        invalidate_frames();
    }

    return 1;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_speed(void)
{
    if (require_current_engine() == NULL) {
        return 0.0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const double speed =
        current_engine()->e_producer != NULL &&
        current_engine()->e_consumer != NULL &&
        !mlt_consumer_is_stopped(current_engine()->e_consumer)
            ? mlt_producer_get_speed(current_engine()->e_producer)
            : 0.0;

    g_mutex_unlock(&current_engine()->e_mutex);

    return speed;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_play(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    return mlt_bridge_set_speed(1.0);
}

MLT_BRIDGE_EXPORT
int mlt_bridge_pause(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_producer == NULL) {
        g_mutex_unlock(&current_engine()->e_mutex);

        return 0;
    }

    if (current_engine()->e_consumer == NULL) {
        mlt_producer_set_speed(current_engine()->e_producer, 0.0);

        g_mutex_unlock(&current_engine()->e_mutex);

        return 1;
    }

    /*
     * The consumer has already shown the frame it reports, so the
     * parked position is the next frame in the direction we were moving.
     */
    const double speed =
        mlt_producer_get_speed(current_engine()->e_producer);

    mlt_position position =
        mlt_consumer_position(current_engine()->e_consumer);

    if (speed > 0.0) {
        position += 1;
    } else if (speed < 0.0) {
        position -= 1;
    }

    const mlt_position length =
        mlt_producer_get_length(current_engine()->e_producer);

    if (position < 0) {
        position = 0;
    }

    if (length > 0 &&
        position >= length) {
        position = length - 1;
    }

    mlt_producer_set_speed(current_engine()->e_producer, 0.0);
    mlt_consumer_purge(current_engine()->e_consumer);
    mlt_producer_seek(current_engine()->e_producer, position);

    refresh_locked();

    set_error(NULL);

    g_mutex_unlock(&current_engine()->e_mutex);

    invalidate_frames();

    return 1;
}

static int seek_frame_locked(mlt_position frame)
{
    if (current_engine()->e_producer == NULL) {
        return 0;
    }

    const mlt_position length =
        mlt_producer_get_length(current_engine()->e_producer);

    if (frame < 0) {
        frame = 0;
    }

    if (length > 0 &&
        frame >= length) {
        frame = length - 1;
    }

    if (current_engine()->e_consumer != NULL) {
        mlt_consumer_purge(current_engine()->e_consumer);
    }

    if (mlt_producer_seek(current_engine()->e_producer, frame) != 0) {
        set_error("MLT seek failed.");
        return 0;
    }

    /*
     * A seek does not restart the consumer. Purge plus refresh is the
     * supported way to make a running or paused consumer show the new
     * position.
     */
    refresh_locked();
    set_error(NULL);

    return 1;
}

static mlt_position visible_position_locked(void)
{
    if (current_engine()->e_producer == NULL) {
        return 0;
    }

    /*
     * While playing, the consumer knows the frame the viewer is actually
     * seeing. While paused or seeking, the producer holds the requested
     * position and the consumer may still be stale.
     */
    const int playing =
        current_engine()->e_consumer != NULL &&
        !mlt_consumer_is_stopped(current_engine()->e_consumer) &&
        mlt_producer_get_speed(current_engine()->e_producer) != 0.0;

    mlt_position position =
        playing
            ? mlt_consumer_position(current_engine()->e_consumer)
            : mlt_producer_position(current_engine()->e_producer);

    if (position < 0) {
        position = 0;
    }

    const mlt_position length =
        mlt_producer_get_length(current_engine()->e_producer);

    if (length > 0 && position >= length) {
        position = length - 1;
    }

    return position;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_seek_frame(
    int64_t frame)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int result = seek_frame_locked((mlt_position)frame);
    g_mutex_unlock(&current_engine()->e_mutex);

    if (result) {
        invalidate_frames();
    }

    return result;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_position_frame(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int64_t result =
        (int64_t)visible_position_locked();
    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_seek_ms(
    int64_t milliseconds)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_producer == NULL) {
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    const double fps =
        mlt_producer_get_fps(current_engine()->e_producer);

    if (fps <= 0.0) {
        set_error("Producer has an invalid frame rate.");
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    const mlt_position frame =
        (mlt_position)(
            ((double)milliseconds / 1000.0) * fps
        );

    const int result = seek_frame_locked(frame);
    g_mutex_unlock(&current_engine()->e_mutex);

    if (result) {
        invalidate_frames();
    }

    return result;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_position_ms(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    if (current_engine()->e_producer == NULL) {
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    const double fps =
        mlt_producer_get_fps(current_engine()->e_producer);

    if (fps <= 0.0) {
        g_mutex_unlock(&current_engine()->e_mutex);
        return 0;
    }

    const mlt_position position =
        visible_position_locked();

    g_mutex_unlock(&current_engine()->e_mutex);

    return (int64_t)(
        ((double)position / fps) * 1000.0
    );
}

MLT_BRIDGE_EXPORT
int mlt_bridge_is_playing(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const int playing =
        current_engine()->e_producer != NULL &&
        current_engine()->e_consumer != NULL &&
        !mlt_consumer_is_stopped(current_engine()->e_consumer) &&
        mlt_producer_get_speed(current_engine()->e_producer) != 0.0;

    g_mutex_unlock(&current_engine()->e_mutex);

    return playing;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_is_eof(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    int at_end = 0;

    if (current_engine()->e_producer != NULL && !current_engine()->e_is_still) {
        const mlt_position length =
            mlt_producer_get_length(current_engine()->e_producer);

        mlt_position position =
            mlt_producer_position(current_engine()->e_producer);

        if (current_engine()->e_consumer != NULL &&
            !mlt_consumer_is_stopped(current_engine()->e_consumer) &&
            mlt_producer_get_speed(current_engine()->e_producer) != 0.0) {
            position =
                mlt_consumer_position(current_engine()->e_consumer);
        }

        at_end =
            length > 0 &&
            position >= length - 1;
    }

    g_mutex_unlock(&current_engine()->e_mutex);

    return at_end;
}

/* ------------------------------------------------------------------------- */
/* Audio                                                                     */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT
void mlt_bridge_set_volume(
    double volume)
{
    if (require_current_engine() == NULL) {
        return;
    }

    ensure_locks();

    if (volume < 0.0) {
        volume = 0.0;
    }

    if (volume > 1.0) {
        volume = 1.0;
    }

    g_mutex_lock(&current_engine()->e_mutex);

    current_engine()->e_requested_volume = volume;

    if (current_engine()->e_consumer != NULL) {
        mlt_properties_set_double(
            MLT_CONSUMER_PROPERTIES(current_engine()->e_consumer),
            "volume",
            volume
        );
    }

    g_mutex_unlock(&current_engine()->e_mutex);
}

MLT_BRIDGE_EXPORT
double mlt_bridge_volume(void)
{
    if (require_current_engine() == NULL) {
        return 1.0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const double volume = current_engine()->e_requested_volume;

    g_mutex_unlock(&current_engine()->e_mutex);

    return volume;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_has_audio(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const int result =
        current_engine()->e_producer != NULL && current_engine()->e_has_audio;

    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

/* ------------------------------------------------------------------------- */
/* Media properties                                                          */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_count(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int result = current_engine()->e_producer != NULL ? current_engine()->e_stream_count : 0;
    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_video_stream_index(void)
{
    if (require_current_engine() == NULL) {
        return -1;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int result =
        current_engine()->e_producer != NULL ? current_engine()->e_selected_video_stream_index : -1;
    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_audio_stream_index(void)
{
    if (require_current_engine() == NULL) {
        return -1;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int result =
        current_engine()->e_producer != NULL ? current_engine()->e_selected_audio_stream_index : -1;
    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_video_codec_name_copy(
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const int required = copy_string_value(
        current_engine()->e_producer != NULL ? current_engine()->e_video_codec_name : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_video_codec_long_name_copy(
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const int required = copy_string_value(
        current_engine()->e_producer != NULL ? current_engine()->e_video_codec_long_name : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_audio_codec_name_copy(
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const int required = copy_string_value(
        current_engine()->e_producer != NULL ? current_engine()->e_audio_codec_name : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_audio_codec_long_name_copy(
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const int required = copy_string_value(
        current_engine()->e_producer != NULL ? current_engine()->e_audio_codec_long_name : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_type_copy(
    int index,
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int required = copy_string_value(
        info != NULL ? info->type : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_codec_name_copy(
    int index,
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int required = copy_string_value(
        info != NULL ? info->codec_name : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_codec_long_name_copy(
    int index,
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int required = copy_string_value(
        info != NULL ? info->codec_long_name : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_language_copy(
    int index,
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int required = copy_string_value(
        info != NULL ? info->language : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_channels(int index)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int result = info != NULL ? info->channels : 0;
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_sample_rate(int index)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int result = info != NULL ? info->sample_rate : 0;
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_width(int index)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int result = info != NULL ? info->width : 0;
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_stream_height(int index)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int result = info != NULL ? info->height : 0;
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_stream_bit_rate(int index)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const StreamInspection *info = stream_inspection_at_locked(index);
    const int64_t result = info != NULL ? info->bit_rate : 0;
    g_mutex_unlock(&current_engine()->e_mutex);
    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_video_pixel_format_copy(
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const int required = copy_string_value(
        current_engine()->e_producer != NULL ? current_engine()->e_video_pixel_format : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_video_colorspace(void)
{
    if (require_current_engine() == NULL) {
        return -1;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int result = current_engine()->e_producer != NULL ? current_engine()->e_video_colorspace : -1;
    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_video_color_trc(void)
{
    if (require_current_engine() == NULL) {
        return -1;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);
    const int result = current_engine()->e_producer != NULL ? current_engine()->e_video_color_trc : -1;
    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_video_color_range_copy(
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const int required = copy_string_value(
        current_engine()->e_producer != NULL ? current_engine()->e_video_color_range : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_source_timecode_copy(
    char *buffer,
    int capacity)
{
    if (require_current_engine() == NULL) {
        return copy_string_value("", buffer, capacity);
    }

    ensure_locks();
    g_mutex_lock(&current_engine()->e_mutex);
    const int required = copy_string_value(
        current_engine()->e_producer != NULL ? current_engine()->e_source_timecode : "",
        buffer,
        capacity
    );
    g_mutex_unlock(&current_engine()->e_mutex);
    return required;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_duration_frames(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const int64_t frames =
        current_engine()->e_producer != NULL && !current_engine()->e_is_still
            ? (int64_t)mlt_producer_get_length(current_engine()->e_producer)
            : 0;

    g_mutex_unlock(&current_engine()->e_mutex);

    return frames;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_fps(void)
{
    if (require_current_engine() == NULL) {
        return 0.0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const double fps =
        current_engine()->e_producer != NULL
            ? mlt_producer_get_fps(current_engine()->e_producer)
            : 0.0;

    g_mutex_unlock(&current_engine()->e_mutex);

    return fps;
}

MLT_BRIDGE_EXPORT
int64_t mlt_bridge_duration_ms(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    int64_t duration = 0;

    if (current_engine()->e_producer != NULL && !current_engine()->e_is_still) {
        const double fps =
            mlt_producer_get_fps(current_engine()->e_producer);

        if (fps > 0.0) {
            const int64_t frames =
                (int64_t)mlt_producer_get_length(current_engine()->e_producer);

            duration =
                (int64_t)(((double)frames / fps) * 1000.0);
        }
    }

    g_mutex_unlock(&current_engine()->e_mutex);

    return duration;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_width(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const int width =
        current_engine()->e_producer != NULL && current_engine()->e_has_video && current_engine()->e_profile != NULL
            ? current_engine()->e_profile->width
            : 0;

    g_mutex_unlock(&current_engine()->e_mutex);

    return width;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_height(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const int height =
        current_engine()->e_producer != NULL && current_engine()->e_has_video && current_engine()->e_profile != NULL
            ? current_engine()->e_profile->height
            : 0;

    g_mutex_unlock(&current_engine()->e_mutex);

    return height;
}

MLT_BRIDGE_EXPORT
double mlt_bridge_display_aspect(void)
{
    if (require_current_engine() == NULL) {
        return 0.0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    double aspect = 0.0;

    if (current_engine()->e_producer != NULL &&
        current_engine()->e_has_video &&
        current_engine()->e_profile != NULL) {
        if (current_engine()->e_profile->display_aspect_num > 0 &&
            current_engine()->e_profile->display_aspect_den > 0) {
            aspect =
                (double)current_engine()->e_profile->display_aspect_num /
                (double)current_engine()->e_profile->display_aspect_den;
        } else if (current_engine()->e_profile->height > 0) {
            aspect =
                (double)current_engine()->e_profile->width /
                (double)current_engine()->e_profile->height;
        }
    }

    g_mutex_unlock(&current_engine()->e_mutex);

    return aspect;
}

MLT_BRIDGE_EXPORT
int mlt_bridge_is_still(void)
{
    if (require_current_engine() == NULL) {
        return 0;
    }

    ensure_locks();

    g_mutex_lock(&current_engine()->e_mutex);

    const int result =
        current_engine()->e_producer != NULL && current_engine()->e_is_still;

    g_mutex_unlock(&current_engine()->e_mutex);

    return result;
}
