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
 * Generate one Explorer thumbnail using a private MLT producer graph.
 *
 * The function is synchronous and owns no preview/export-global state. Callers
 * are expected to run it off the Flutter UI isolate. Video sources sample a
 * small set of positions and select a representative frame; still images use
 * frame zero. The output is a JPEG with the exact requested canvas size.
 *
 * Returns non-zero on success. selected_frame_out may be NULL. error_buffer is
 * caller-owned and receives a NUL-terminated diagnostic on failure.
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

#ifdef __cplusplus
}
#endif

#endif
