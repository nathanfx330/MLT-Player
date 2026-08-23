/* native/mlt_layer_api.h */
#ifndef MLT_LAYER_API_H
#define MLT_LAYER_API_H

#include <stdint.h>

typedef struct _MltBridgeEngine MltBridgeEngine;

#if defined(__GNUC__)
#define MLT_LAYER_API_EXPORT __attribute__((visibility("default")))
#else
#define MLT_LAYER_API_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Freeze Flutter frame publication while a composition graph is rebuilt.
 * Calls may be nested. end() publishes only the next frame from the fully
 * configured graph, keeping the previous GL texture visible in the meantime.
 */
MLT_LAYER_API_EXPORT int mlt_bridge_preview_update_begin(MltBridgeEngine *engine);
MLT_LAYER_API_EXPORT int mlt_bridge_preview_update_end(MltBridgeEngine *engine);

/* Zero-based layer indices: 0 base, 1 Layer 2, 2 Layer 3. */

/*
 * Add one overlay with its final presentation state already installed before
 * preview resumes. This is used by Undo/Redo so restoring Layer 3 never
 * exposes an intermediate default frame. Current builds accept layer_index 2.
 */
MLT_LAYER_API_EXPORT int mlt_bridge_add_layer_with_state(
    int layer_index,
    const char *path,
    int64_t start_frame,
    double x,
    double y,
    double scale,
    double opacity,
    int alpha_mode,
    double audio_gain);
MLT_LAYER_API_EXPORT int64_t mlt_bridge_layer_start_frame(int layer_index);
MLT_LAYER_API_EXPORT int mlt_bridge_set_layer_opacity(int layer_index, double opacity);
MLT_LAYER_API_EXPORT double mlt_bridge_layer_opacity(int layer_index);
MLT_LAYER_API_EXPORT int mlt_bridge_set_layer_geometry(int layer_index, double x, double y, double scale);
MLT_LAYER_API_EXPORT int mlt_bridge_set_layer_anchor(int layer_index, int anchor);
MLT_LAYER_API_EXPORT double mlt_bridge_layer_x(int layer_index);
MLT_LAYER_API_EXPORT double mlt_bridge_layer_y(int layer_index);
MLT_LAYER_API_EXPORT double mlt_bridge_layer_scale(int layer_index);
MLT_LAYER_API_EXPORT int mlt_bridge_layer_is_still(int layer_index);
MLT_LAYER_API_EXPORT int mlt_bridge_layer_has_alpha(int layer_index);
MLT_LAYER_API_EXPORT int mlt_bridge_set_layer_alpha_mode(int layer_index, int mode);
MLT_LAYER_API_EXPORT int mlt_bridge_layer_alpha_mode(int layer_index);

#ifdef __cplusplus
}
#endif

#endif
