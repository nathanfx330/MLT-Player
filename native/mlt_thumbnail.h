/* native/mlt_thumbnail.h */

#ifndef MLT_PLAYER_MLT_THUMBNAIL_H
#define MLT_PLAYER_MLT_THUMBNAIL_H

#include <stdint.h>

#if defined(__GNUC__)
#define MLT_THUMBNAIL_EXPORT __attribute__((visibility("default")))
#else
#define MLT_THUMBNAIL_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Explorer/storyboard thumbnail generation is synchronous and owns no
 * preview/export-global state. Callers are expected to run it off the Flutter
 * UI isolate. The output is a JPEG with the exact requested canvas size.
 *
 * Generation is serialized process-wide. Concurrent callers are safe, but
 * thumbnail decodes do not execute in parallel. Increasing caller-side worker
 * concurrency above one therefore does not increase MLT thumbnail throughput.
 * Keep this contract until parallel producer/plugin decoding has been proven
 * safe in standalone optimized release builds.
 *
 * Returns non-zero on success. selected_frame_out may be NULL. error_buffer is
 * caller-owned and receives a NUL-terminated diagnostic on failure.
 */

/*
 * Choose one representative frame for Explorer. Timed video samples a small
 * set of positions and scores them for useful visual content; still images use
 * frame zero.
 */
MLT_THUMBNAIL_EXPORT int
mlt_thumbnail_generate(
    const char *source_path,
    const char *output_path,
    int output_width,
    int output_height,
    int64_t *selected_frame_out,
    char *error_buffer,
    int error_capacity
);

/*
 * Decode a specific source frame for Storyboard/Visual Time. requested_frame
 * is zero-based and clamps to the final source frame when it exceeds the media
 * length. This API does not run the representative-frame heuristic.
 */
MLT_THUMBNAIL_EXPORT int
mlt_thumbnail_generate_at_frame(
    const char *source_path,
    const char *output_path,
    int output_width,
    int output_height,
    int64_t requested_frame,
    int64_t *selected_frame_out,
    char *error_buffer,
    int error_capacity
);

#ifdef __cplusplus
}
#endif

#endif
