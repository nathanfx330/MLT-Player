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
 * POC 11 adds layers[3] as the canonical indexed diagnostic view. The
 * legacy Layer-2 scalar fields stay for this transition slice so the mature
 * parity assertions remain readable while indexed assertions are added.
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

    MltCompositionLayerDerivedState layers[MLT_COMPOSITION_MAX_LAYERS];

    /* Transitional compatibility view for the existing parity harness. */
    int64_t layer2_start_frame;
    int64_t layer2_timeline_length;
    int layer2_is_still;
    int layer2_alpha_mode;

    double layer2_base_width;
    double layer2_base_height;

    double layer2_x;
    double layer2_y;
    double layer2_width;
    double layer2_height;
    double layer2_opacity;

    int base_has_audio;
    int layer2_has_audio;
    double base_audio_gain;
    double layer2_audio_gain;
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
