/* native/mlt_thumbnail.c */

#include "mlt_thumbnail.h"

#include <framework/mlt.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib/gstdio.h>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define THUMBNAIL_SCORE_WIDTH 160
#define THUMBNAIL_SCORE_HEIGHT 90
#define THUMBNAIL_CANDIDATE_COUNT 3
#define THUMBNAIL_FRAME_ERROR_CAPACITY 512

/*
 * MLT producer/decoder/plugin stacks are proven concurrently against preview
 * and export, but Explorer previously allowed two independent thumbnail graphs
 * to enter the stack at the same instant from short-lived Dart isolates. The
 * release build exposes that timing much more aggressively than debug. Keep
 * thumbnail generation single-file here so callers remain safe regardless of
 * how many worker isolates request thumbnails concurrently.
 */
static GMutex thumbnail_generation_mutex;
static gsize thumbnail_mutex_initialized = 0;

static void thumbnail_ensure_mutex(void)
{
    if (g_once_init_enter(&thumbnail_mutex_initialized)) {
        g_mutex_init(&thumbnail_generation_mutex);
        g_once_init_leave(&thumbnail_mutex_initialized, 1);
    }
}

static void thumbnail_set_error(
    char *buffer,
    int capacity,
    const char *message)
{
    if (buffer == NULL || capacity <= 0) {
        return;
    }

    snprintf(
        buffer,
        (size_t)capacity,
        "%s",
        message != NULL ? message : "MLT thumbnail generation failed."
    );
}

static void thumbnail_set_error_once(
    char *buffer,
    int capacity,
    const char *message)
{
    if (buffer == NULL || capacity <= 0 || buffer[0] != '\0') {
        return;
    }

    thumbnail_set_error(buffer, capacity, message);
}

static int thumbnail_has_suffix(
    const char *path,
    const char *suffix)
{
    if (path == NULL || suffix == NULL) {
        return 0;
    }

    const size_t path_length = strlen(path);
    const size_t suffix_length = strlen(suffix);

    if (path_length < suffix_length) {
        return 0;
    }

    return g_ascii_strcasecmp(
               path + path_length - suffix_length,
               suffix) == 0;
}

static int thumbnail_path_is_still(const char *path)
{
    static const char *const suffixes[] = {
        ".png",
        ".jpg",
        ".jpeg",
        ".webp",
        ".bmp",
        ".tif",
        ".tiff",
        ".exr",
    };

    for (size_t index = 0;
         index < sizeof(suffixes) / sizeof(suffixes[0]);
         index++) {
        if (thumbnail_has_suffix(path, suffixes[index])) {
            return 1;
        }
    }

    return 0;
}

/*
 * Mirror the Player's primary-open policy: still images explicitly prefer
 * pixbuf (with avformat fallback) so Qt/qimage is never selected implicitly;
 * timed media keeps MLT's normal loader/avformat selection.
 */
static mlt_producer thumbnail_open_source(
    mlt_profile profile,
    const char *path,
    int is_still)
{
    if (profile == NULL || path == NULL || path[0] == '\0') {
        return NULL;
    }

    if (!is_still) {
        return mlt_factory_producer(profile, NULL, path);
    }

    mlt_producer producer =
        mlt_factory_producer(profile, "pixbuf", path);

    if (producer == NULL) {
        producer =
            mlt_factory_producer(profile, "avformat", path);
    }

    return producer;
}

typedef enum _ThumbnailMediaKind {
    THUMBNAIL_MEDIA_TIMED,
    THUMBNAIL_MEDIA_STILL,
    THUMBNAIL_MEDIA_UNSUPPORTED,
} ThumbnailMediaKind;

static ThumbnailMediaKind thumbnail_classify_producer(
    mlt_producer producer)
{
    if (producer == NULL) {
        return THUMBNAIL_MEDIA_UNSUPPORTED;
    }

    mlt_properties properties = MLT_PRODUCER_PROPERTIES(producer);
    const char *service = mlt_properties_get(properties, "mlt_service");

    if (service == NULL) {
        return THUMBNAIL_MEDIA_UNSUPPORTED;
    }

    static const char *const timed_services[] = {
        "avformat",
        "avformat-novalidate",
        "chain",
        "xml",
        "xml-string",
        "melt",
        "melt_file",
        NULL,
    };

    static const char *const still_services[] = {
        "pixbuf",
        "qimage",
        "svg",
        "color",
        "colour",
        NULL,
    };

    for (int index = 0; timed_services[index] != NULL; index++) {
        if (strcmp(service, timed_services[index]) != 0) {
            continue;
        }

        if (mlt_properties_get(properties, "meta.media.nb_streams") != NULL &&
            mlt_properties_get_int(properties, "meta.media.nb_streams") <= 0) {
            return THUMBNAIL_MEDIA_UNSUPPORTED;
        }

        return THUMBNAIL_MEDIA_TIMED;
    }

    for (int index = 0; still_services[index] != NULL; index++) {
        if (strcmp(service, still_services[index]) == 0) {
            return THUMBNAIL_MEDIA_STILL;
        }
    }

    return THUMBNAIL_MEDIA_UNSUPPORTED;
}

static int thumbnail_producer_has_video(mlt_producer producer)
{
    if (producer == NULL) {
        return 0;
    }

    mlt_properties properties = MLT_PRODUCER_PROPERTIES(producer);

    if (mlt_properties_get(properties, "video_index") != NULL) {
        return mlt_properties_get_int(properties, "video_index") >= 0;
    }

    if (mlt_properties_get(properties, "meta.media.nb_streams") != NULL) {
        const int count =
            mlt_properties_get_int(properties, "meta.media.nb_streams");

        for (int index = 0; index < count; index++) {
            char key[128];
            snprintf(
                key,
                sizeof(key),
                "meta.media.%d.stream.type",
                index
            );

            const char *type = mlt_properties_get(properties, key);
            if (type != NULL && strcmp(type, "video") == 0) {
                return 1;
            }
        }

        return 0;
    }

    return 1;
}

static int thumbnail_attach_still_converter(
    mlt_profile profile,
    mlt_producer producer)
{
    if (profile == NULL || producer == NULL) {
        return 0;
    }

    mlt_filter filter =
        mlt_factory_filter(profile, "avcolor_space", NULL);

    if (filter == NULL) {
        filter = mlt_factory_filter(profile, "imageconvert", NULL);
    }

    if (filter == NULL) {
        return 0;
    }

    const int attached =
        mlt_producer_attach(producer, filter) == 0;

    mlt_filter_close(filter);
    return attached;
}

static int thumbnail_decode_rgb(
    mlt_producer producer,
    int64_t position,
    int requested_width,
    int requested_height,
    uint8_t **image_out,
    int *width_out,
    int *height_out,
    mlt_frame *frame_out)
{
    if (producer == NULL ||
        image_out == NULL ||
        width_out == NULL ||
        height_out == NULL ||
        frame_out == NULL ||
        requested_width <= 0 ||
        requested_height <= 0 ||
        position < 0) {
        return 0;
    }

    *image_out = NULL;
    *frame_out = NULL;

    if (mlt_producer_seek(
            producer,
            (mlt_position)position) != 0 ||
        mlt_producer_set_speed(producer, 1.0) != 0) {
        return 0;
    }

    mlt_frame frame = NULL;
    if (mlt_service_get_frame(
            MLT_PRODUCER_SERVICE(producer),
            &frame,
            0) != 0 ||
        frame == NULL) {
        if (frame != NULL) {
            mlt_frame_close(frame);
        }
        return 0;
    }

    mlt_image_format format = mlt_image_rgb;
    int width = requested_width;
    int height = requested_height;
    uint8_t *image = NULL;

    if (mlt_frame_get_image(
            frame,
            &image,
            &format,
            &width,
            &height,
            0) != 0 ||
        image == NULL ||
        format != mlt_image_rgb ||
        width <= 0 ||
        height <= 0) {
        mlt_frame_close(frame);
        return 0;
    }

    *image_out = image;
    *width_out = width;
    *height_out = height;
    *frame_out = frame;
    return 1;
}

static double thumbnail_frame_score(
    const uint8_t *image,
    int width,
    int height)
{
    if (image == NULL || width <= 0 || height <= 0) {
        return -1.0;
    }

    const int64_t pixel_count = (int64_t)width * (int64_t)height;
    if (pixel_count <= 0) {
        return -1.0;
    }

    double sum = 0.0;
    double sum_squared = 0.0;
    int64_t near_black = 0;

    for (int64_t index = 0; index < pixel_count; index++) {
        const uint8_t *pixel = image + (index * 3);
        const int luma =
            (54 * (int)pixel[0] +
             183 * (int)pixel[1] +
             19 * (int)pixel[2]) >> 8;

        sum += (double)luma;
        sum_squared += (double)luma * (double)luma;

        if (luma < 18) {
            near_black++;
        }
    }

    const double mean = sum / (double)pixel_count;
    double variance =
        (sum_squared / (double)pixel_count) - (mean * mean);

    if (variance < 0.0) {
        variance = 0.0;
    }

    const double dark_fraction =
        (double)near_black / (double)pixel_count;

    /*
     * Variance favors informative texture/detail. The dark penalty is strong
     * enough to reject black leader/fades while still allowing a dark scene
     * with genuine contrast to win over a flat bright slate.
     */
    double score =
        variance + (mean * 2.0) - (dark_fraction * 2500.0);

    if (mean < 10.0) {
        score -= 5000.0;
    }

    return score;
}

static int64_t thumbnail_candidate_frame(
    int64_t source_length,
    double fraction)
{
    if (source_length <= 1) {
        return 0;
    }

    const double last = (double)(source_length - 1);
    int64_t frame = (int64_t)llround(last * fraction);

    if (frame < 0) {
        frame = 0;
    } else if (frame >= source_length) {
        frame = source_length - 1;
    }

    return frame;
}

static int thumbnail_choose_frame(
    mlt_producer producer,
    int64_t source_length,
    int is_still,
    int64_t *selected_frame_out)
{
    if (producer == NULL || selected_frame_out == NULL) {
        return 0;
    }

    if (is_still || source_length <= 1) {
        *selected_frame_out = 0;
        return 1;
    }

    static const double fractions[THUMBNAIL_CANDIDATE_COUNT] = {
        0.15,
        0.50,
        0.85,
    };

    int64_t candidates[THUMBNAIL_CANDIDATE_COUNT];
    int candidate_count = 0;

    for (int index = 0;
         index < THUMBNAIL_CANDIDATE_COUNT;
         index++) {
        const int64_t candidate =
            thumbnail_candidate_frame(source_length, fractions[index]);

        int duplicate = 0;
        for (int prior = 0; prior < candidate_count; prior++) {
            if (candidates[prior] == candidate) {
                duplicate = 1;
                break;
            }
        }

        if (!duplicate) {
            candidates[candidate_count++] = candidate;
        }
    }

    if (candidate_count == 0) {
        candidates[candidate_count++] = 0;
    }

    int found = 0;
    int64_t best_frame = candidates[0];
    double best_score = -1.0e30;

    for (int index = 0; index < candidate_count; index++) {
        uint8_t *image = NULL;
        int width = 0;
        int height = 0;
        mlt_frame frame = NULL;

        if (!thumbnail_decode_rgb(
                producer,
                candidates[index],
                THUMBNAIL_SCORE_WIDTH,
                THUMBNAIL_SCORE_HEIGHT,
                &image,
                &width,
                &height,
                &frame)) {
            continue;
        }

        const double score =
            thumbnail_frame_score(image, width, height);

        mlt_frame_close(frame);

        if (!found || score > best_score) {
            found = 1;
            best_score = score;
            best_frame = candidates[index];
        }
    }

    if (!found) {
        /* A final frame-zero attempt preserves a useful fallback for odd files. */
        uint8_t *image = NULL;
        int width = 0;
        int height = 0;
        mlt_frame frame = NULL;

        if (!thumbnail_decode_rgb(
                producer,
                0,
                THUMBNAIL_SCORE_WIDTH,
                THUMBNAIL_SCORE_HEIGHT,
                &image,
                &width,
                &height,
                &frame)) {
            return 0;
        }

        mlt_frame_close(frame);
        best_frame = 0;
    }

    *selected_frame_out = best_frame;
    return 1;
}

static void thumbnail_free_pixels(
    guchar *pixels,
    gpointer data)
{
    (void)data;
    g_free(pixels);
}

static int thumbnail_render_selected_frame(
    mlt_profile profile,
    mlt_producer producer,
    int64_t selected_frame,
    const char *output_path,
    int output_width,
    int output_height,
    char *error_buffer,
    int error_capacity)
{
    if (profile == NULL ||
        producer == NULL ||
        output_path == NULL ||
        output_path[0] == '\0' ||
        output_width <= 0 ||
        output_height <= 0) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The MLT thumbnail render request is invalid."
        );
        return 0;
    }

    double display_aspect = mlt_profile_dar(profile);
    if (display_aspect <= 0.0 && profile->width > 0 && profile->height > 0) {
        display_aspect = (double)profile->width / (double)profile->height;
    }
    if (display_aspect <= 0.0) {
        display_aspect = (double)output_width / (double)output_height;
    }

    const double canvas_aspect =
        (double)output_width / (double)output_height;

    int content_width = output_width;
    int content_height = output_height;

    if (display_aspect > canvas_aspect) {
        content_height = (int)llround((double)output_width / display_aspect);
    } else {
        content_width = (int)llround((double)output_height * display_aspect);
    }

    if (content_width < 1) {
        content_width = 1;
    } else if (content_width > output_width) {
        content_width = output_width;
    }

    if (content_height < 1) {
        content_height = 1;
    } else if (content_height > output_height) {
        content_height = output_height;
    }

    uint8_t *image = NULL;
    int decoded_width = 0;
    int decoded_height = 0;
    mlt_frame frame = NULL;

    if (!thumbnail_decode_rgb(
            producer,
            selected_frame,
            content_width,
            content_height,
            &image,
            &decoded_width,
            &decoded_height,
            &frame)) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "MLT could not decode the selected thumbnail frame."
        );
        return 0;
    }

    const size_t canvas_bytes =
        (size_t)output_width * (size_t)output_height * 3u;
    guchar *canvas = g_try_malloc0(canvas_bytes);

    if (canvas == NULL) {
        mlt_frame_close(frame);
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "Could not allocate the thumbnail image buffer."
        );
        return 0;
    }

    int copy_width = decoded_width;
    int copy_height = decoded_height;

    if (copy_width > output_width) {
        copy_width = output_width;
    }
    if (copy_height > output_height) {
        copy_height = output_height;
    }

    const int source_x =
        decoded_width > copy_width ? (decoded_width - copy_width) / 2 : 0;
    const int source_y =
        decoded_height > copy_height ? (decoded_height - copy_height) / 2 : 0;
    const int destination_x = (output_width - copy_width) / 2;
    const int destination_y = (output_height - copy_height) / 2;

    for (int row = 0; row < copy_height; row++) {
        const uint8_t *source =
            image +
            (((size_t)(source_y + row) * (size_t)decoded_width +
              (size_t)source_x) * 3u);
        guchar *destination =
            canvas +
            (((size_t)(destination_y + row) * (size_t)output_width +
              (size_t)destination_x) * 3u);

        memcpy(destination, source, (size_t)copy_width * 3u);
    }

    mlt_frame_close(frame);
    frame = NULL;

    GdkPixbuf *pixbuf =
        gdk_pixbuf_new_from_data(
            canvas,
            GDK_COLORSPACE_RGB,
            FALSE,
            8,
            output_width,
            output_height,
            output_width * 3,
            thumbnail_free_pixels,
            NULL
        );

    if (pixbuf == NULL) {
        g_free(canvas);
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "Could not construct the thumbnail JPEG image."
        );
        return 0;
    }

    GError *save_error = NULL;
    const gboolean saved =
        gdk_pixbuf_save(
            pixbuf,
            output_path,
            "jpeg",
            &save_error,
            "quality",
            "88",
            NULL
        );

    g_object_unref(pixbuf);

    if (!saved) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            save_error != NULL && save_error->message != NULL
                ? save_error->message
                : "Could not save the thumbnail JPEG."
        );
        if (save_error != NULL) {
            g_error_free(save_error);
        }
        return 0;
    }

    if (save_error != NULL) {
        g_error_free(save_error);
    }

    return 1;
}

typedef enum _ThumbnailSelectionMode {
    THUMBNAIL_SELECT_REPRESENTATIVE,
    THUMBNAIL_SELECT_EXACT_FRAME,
} ThumbnailSelectionMode;

static int thumbnail_generate_locked(
    const char *source_path,
    const char *output_path,
    int output_width,
    int output_height,
    ThumbnailSelectionMode selection_mode,
    int64_t requested_frame,
    int64_t *selected_frame_out,
    char *error_buffer,
    int error_capacity)
{
    const int is_still = thumbnail_path_is_still(source_path);
    mlt_profile profile = mlt_profile_init(NULL);
    mlt_producer probe = NULL;
    mlt_producer producer = NULL;
    int succeeded = 0;

    if (profile == NULL) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "Could not create an MLT thumbnail profile."
        );
        goto cleanup;
    }

    probe = thumbnail_open_source(profile, source_path, is_still);
    if (probe == NULL) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "MLT could not open the thumbnail source."
        );
        goto cleanup;
    }

    mlt_producer_probe(probe);

    const ThumbnailMediaKind media_kind =
        thumbnail_classify_producer(probe);

    if (media_kind == THUMBNAIL_MEDIA_UNSUPPORTED ||
        (!is_still &&
         (media_kind != THUMBNAIL_MEDIA_TIMED ||
          !thumbnail_producer_has_video(probe)))) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "MLT opened the source, but it is not thumbnailable video/image media."
        );
        goto cleanup;
    }

    mlt_profile_from_producer(profile, probe);

    mlt_producer_close(probe);
    probe = NULL;

    producer = thumbnail_open_source(profile, source_path, is_still);
    if (producer == NULL) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "MLT could not reopen the thumbnail source."
        );
        goto cleanup;
    }

    mlt_producer_probe(producer);

    if (is_still && !thumbnail_attach_still_converter(profile, producer)) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "MLT could not attach the still-image color converter."
        );
        goto cleanup;
    }

    const int64_t source_length =
        is_still ? 1 : (int64_t)mlt_producer_get_length(producer);

    if (source_length <= 0) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The thumbnail source has no decodable video frames."
        );
        goto cleanup;
    }

    int64_t selected_frame = 0;
    if (selection_mode == THUMBNAIL_SELECT_EXACT_FRAME) {
        selected_frame = is_still ? 0 : requested_frame;
        if (selected_frame >= source_length) {
            selected_frame = source_length - 1;
        }
    } else if (!thumbnail_choose_frame(
                   producer,
                   source_length,
                   is_still,
                   &selected_frame)) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "MLT could not decode a representative thumbnail frame."
        );
        goto cleanup;
    }

    if (!thumbnail_render_selected_frame(
            profile,
            producer,
            selected_frame,
            output_path,
            output_width,
            output_height,
            error_buffer,
            error_capacity)) {
        goto cleanup;
    }

    if (selected_frame_out != NULL) {
        *selected_frame_out = selected_frame;
    }
    succeeded = 1;

cleanup:
    if (producer != NULL) {
        mlt_producer_close(producer);
    }
    if (probe != NULL) {
        mlt_producer_close(probe);
    }
    if (profile != NULL) {
        mlt_profile_close(profile);
    }

    return succeeded;
}

static int thumbnail_generate_frame_batch_locked(
    const char *source_path,
    const char *output_directory,
    int output_width,
    int output_height,
    const int64_t *requested_frames,
    int frame_count,
    int *succeeded_count_out,
    char *error_buffer,
    int error_capacity)
{
    const int is_still = thumbnail_path_is_still(source_path);
    mlt_profile profile = mlt_profile_init(NULL);
    mlt_producer probe = NULL;
    mlt_producer producer = NULL;
    int session_succeeded = 0;
    int generated_count = 0;

    if (profile == NULL) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "Could not create an MLT storyboard batch profile."
        );
        goto cleanup;
    }

    probe = thumbnail_open_source(profile, source_path, is_still);
    if (probe == NULL) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "MLT could not open the storyboard batch source."
        );
        goto cleanup;
    }

    mlt_producer_probe(probe);

    const ThumbnailMediaKind media_kind =
        thumbnail_classify_producer(probe);

    if (media_kind == THUMBNAIL_MEDIA_UNSUPPORTED ||
        (!is_still &&
         (media_kind != THUMBNAIL_MEDIA_TIMED ||
          !thumbnail_producer_has_video(probe)))) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "MLT opened the storyboard source, but it has no usable video."
        );
        goto cleanup;
    }

    mlt_profile_from_producer(profile, probe);

    mlt_producer_close(probe);
    probe = NULL;

    producer = thumbnail_open_source(profile, source_path, is_still);
    if (producer == NULL) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "MLT could not reopen the storyboard batch source."
        );
        goto cleanup;
    }

    mlt_producer_probe(producer);

    if (is_still && !thumbnail_attach_still_converter(profile, producer)) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "MLT could not attach the storyboard still-image color converter."
        );
        goto cleanup;
    }

    const int64_t source_length =
        is_still ? 1 : (int64_t)mlt_producer_get_length(producer);

    if (source_length <= 0) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The storyboard batch source has no decodable video frames."
        );
        goto cleanup;
    }

    session_succeeded = 1;

    for (int index = 0; index < frame_count; index++) {
        int64_t selected_frame = is_still ? 0 : requested_frames[index];
        if (selected_frame >= source_length) {
            selected_frame = source_length - 1;
        }

        char file_name[64];
        char temporary_name[64];
        snprintf(file_name, sizeof(file_name), "%d.jpg", index);
        snprintf(temporary_name, sizeof(temporary_name), "%d.part.jpg", index);

        char *output_path =
            g_build_filename(output_directory, file_name, NULL);
        char *temporary_path =
            g_build_filename(output_directory, temporary_name, NULL);

        if (output_path == NULL || temporary_path == NULL) {
            thumbnail_set_error_once(
                error_buffer,
                error_capacity,
                "Could not allocate a storyboard batch output path."
            );
            if (output_path != NULL) {
                g_free(output_path);
            }
            if (temporary_path != NULL) {
                g_free(temporary_path);
            }
            continue;
        }

        g_remove(output_path);
        g_remove(temporary_path);

        char frame_error[THUMBNAIL_FRAME_ERROR_CAPACITY] = {0};
        const int rendered = thumbnail_render_selected_frame(
            profile,
            producer,
            selected_frame,
            temporary_path,
            output_width,
            output_height,
            frame_error,
            (int)sizeof(frame_error)
        );

        if (!rendered) {
            char diagnostic[THUMBNAIL_FRAME_ERROR_CAPACITY + 96];
            snprintf(
                diagnostic,
                sizeof(diagnostic),
                "Storyboard frame %lld failed: %s",
                (long long)selected_frame,
                frame_error[0] != '\0'
                    ? frame_error
                    : "MLT could not render the requested frame."
            );
            thumbnail_set_error_once(
                error_buffer,
                error_capacity,
                diagnostic
            );
            g_remove(temporary_path);
            g_free(temporary_path);
            g_free(output_path);
            continue;
        }

        if (g_rename(temporary_path, output_path) != 0) {
            thumbnail_set_error_once(
                error_buffer,
                error_capacity,
                "Could not publish a storyboard batch thumbnail."
            );
            g_remove(temporary_path);
            g_free(temporary_path);
            g_free(output_path);
            continue;
        }

        generated_count++;
        g_free(temporary_path);
        g_free(output_path);
    }

cleanup:
    if (succeeded_count_out != NULL) {
        *succeeded_count_out = generated_count;
    }
    if (producer != NULL) {
        mlt_producer_close(producer);
    }
    if (probe != NULL) {
        mlt_producer_close(probe);
    }
    if (profile != NULL) {
        mlt_profile_close(profile);
    }

    return session_succeeded && generated_count > 0;
}

static int thumbnail_generate_serialized(
    const char *source_path,
    const char *output_path,
    int output_width,
    int output_height,
    ThumbnailSelectionMode selection_mode,
    int64_t requested_frame,
    int64_t *selected_frame_out,
    char *error_buffer,
    int error_capacity)
{
    if (selected_frame_out != NULL) {
        *selected_frame_out = -1;
    }
    if (error_buffer != NULL && error_capacity > 0) {
        error_buffer[0] = '\0';
    }

    /*
     * Validate arguments before taking the process-wide generation lock. A
     * malformed direct FFI/native call must fail without changing the lock
     * state seen by the next valid thumbnail request. Once the mutex is held,
     * every generation exit returns through this wrapper and unlocks it.
     */
    if (source_path == NULL || source_path[0] == '\0') {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The thumbnail source path is empty."
        );
        return 0;
    }

    if (output_path == NULL || output_path[0] == '\0') {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The thumbnail output path is empty."
        );
        return 0;
    }

    if (output_width <= 0 || output_height <= 0) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The thumbnail dimensions are invalid."
        );
        return 0;
    }

    if (selection_mode == THUMBNAIL_SELECT_EXACT_FRAME && requested_frame < 0) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The requested thumbnail frame is invalid."
        );
        return 0;
    }

    thumbnail_ensure_mutex();
    g_mutex_lock(&thumbnail_generation_mutex);

    const int succeeded = thumbnail_generate_locked(
        source_path,
        output_path,
        output_width,
        output_height,
        selection_mode,
        requested_frame,
        selected_frame_out,
        error_buffer,
        error_capacity
    );

    g_mutex_unlock(&thumbnail_generation_mutex);
    return succeeded;
}

int mlt_thumbnail_generate(
    const char *source_path,
    const char *output_path,
    int output_width,
    int output_height,
    int64_t *selected_frame_out,
    char *error_buffer,
    int error_capacity)
{
    return thumbnail_generate_serialized(
        source_path,
        output_path,
        output_width,
        output_height,
        THUMBNAIL_SELECT_REPRESENTATIVE,
        0,
        selected_frame_out,
        error_buffer,
        error_capacity
    );
}

int mlt_thumbnail_generate_at_frame(
    const char *source_path,
    const char *output_path,
    int output_width,
    int output_height,
    int64_t requested_frame,
    int64_t *selected_frame_out,
    char *error_buffer,
    int error_capacity)
{
    return thumbnail_generate_serialized(
        source_path,
        output_path,
        output_width,
        output_height,
        THUMBNAIL_SELECT_EXACT_FRAME,
        requested_frame,
        selected_frame_out,
        error_buffer,
        error_capacity
    );
}

int mlt_thumbnail_generate_frame_batch(
    const char *source_path,
    const char *output_directory,
    int output_width,
    int output_height,
    const int64_t *requested_frames,
    int frame_count,
    int *succeeded_count_out,
    char *error_buffer,
    int error_capacity)
{
    if (succeeded_count_out != NULL) {
        *succeeded_count_out = 0;
    }
    if (error_buffer != NULL && error_capacity > 0) {
        error_buffer[0] = '\0';
    }

    if (source_path == NULL || source_path[0] == '\0') {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The storyboard batch source path is empty."
        );
        return 0;
    }

    if (output_directory == NULL || output_directory[0] == '\0') {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The storyboard batch output directory is empty."
        );
        return 0;
    }

    if (!g_file_test(output_directory, G_FILE_TEST_IS_DIR)) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The storyboard batch output directory does not exist."
        );
        return 0;
    }

    if (output_width <= 0 || output_height <= 0) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The storyboard batch dimensions are invalid."
        );
        return 0;
    }

    if (requested_frames == NULL || frame_count <= 0) {
        thumbnail_set_error(
            error_buffer,
            error_capacity,
            "The storyboard batch contains no frame requests."
        );
        return 0;
    }

    for (int index = 0; index < frame_count; index++) {
        if (requested_frames[index] < 0) {
            thumbnail_set_error(
                error_buffer,
                error_capacity,
                "The storyboard batch contains an invalid source frame."
            );
            return 0;
        }
    }

    thumbnail_ensure_mutex();
    g_mutex_lock(&thumbnail_generation_mutex);

    const int succeeded = thumbnail_generate_frame_batch_locked(
        source_path,
        output_directory,
        output_width,
        output_height,
        requested_frames,
        frame_count,
        succeeded_count_out,
        error_buffer,
        error_capacity
    );

    g_mutex_unlock(&thumbnail_generation_mutex);
    return succeeded;
}
