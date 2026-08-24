/* native/mlt_parity.h */
#ifndef MLT_PARITY_H
#define MLT_PARITY_H

#include <stdint.h>

#include "mlt_layers.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct _MltCompositionLayerDerivedState {
    int present;
    int64_t start_frame;
    int64_t timeline_length;
    int64_t source_in_frame;
    int64_t source_out_frame;

    int is_still;
    int alpha_mode;

    double base_width;
    double base_height;

    double x;
    double y;
    double width;
    double height;
    double opacity;

    int has_audio;
    double audio_gain;
} MltCompositionLayerDerivedState;

/*
 * Canonical preview/export diagnostic state. Layer slots are index-aligned
 * with native composition slots: 0 = base, 1 = Layer 2, 2 = Layer 3.
 * Presence and every per-layer derived value live only in layers[].
 */
typedef struct _MltCompositionDerivedState {
    int valid;
    int layer_count;

    int profile_width;
    int profile_height;
    double profile_fps;

    int64_t composition_length;
    int64_t range_in_frame;
    int64_t range_out_frame;

    int visual_order[MLT_COMPOSITION_MAX_LAYERS];

    MltCompositionLayerDerivedState layers[MLT_COMPOSITION_MAX_LAYERS];
} MltCompositionDerivedState;

int mlt_bridge_debug_composition_parity(
    int64_t in_frame,
    int64_t out_frame,
    MltCompositionDerivedState *preview_state,
    MltCompositionDerivedState *export_state,
    char *error_buffer,
    int error_capacity
);

#ifdef __cplusplus
}
#endif

#endif
