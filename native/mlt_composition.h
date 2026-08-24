/* native/mlt_composition.h */
#ifndef MLT_COMPOSITION_H
#define MLT_COMPOSITION_H

#include <framework/mlt.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum _MltSecondaryPlacementResult {
    MLT_SECONDARY_PLACEMENT_OK = 0,
    MLT_SECONDARY_PLACEMENT_INVALID_ARGUMENT = 1,
    MLT_SECONDARY_PLACEMENT_NO_DURATION = 2,
    MLT_SECONDARY_PLACEMENT_NO_ROOM = 3,
    MLT_SECONDARY_PLACEMENT_SOURCE_INIT_FAILED = 4,
    MLT_SECONDARY_PLACEMENT_PLAYLIST_CREATE_FAILED = 5,
    MLT_SECONDARY_PLACEMENT_LEAD_IN_FAILED = 6,
    MLT_SECONDARY_PLACEMENT_APPEND_FAILED = 7
} MltSecondaryPlacementResult;

int mlt_composition_secondary_base_size(
    mlt_profile target_profile,
    mlt_producer source,
    int source_is_still,
    double *out_width,
    double *out_height
);

MltSecondaryPlacementResult mlt_composition_build_secondary_playlist(
    mlt_profile target_profile,
    mlt_producer source,
    mlt_position start_frame,
    mlt_position end_frame,
    mlt_position base_length,
    int source_is_still,
    mlt_playlist *playlist_out,
    mlt_position *normalized_start_out
);

/*
 * Source-trim-aware overlay placement. Source In/Out are inclusive positions
 * in the composition profile's frame timebase. Pass -1/-1 for the full source.
 * Stills ignore source trim and continue to use timeline hold semantics.
 */
MltSecondaryPlacementResult mlt_composition_build_secondary_playlist_trimmed(
    mlt_profile target_profile,
    mlt_producer source,
    mlt_position start_frame,
    mlt_position end_frame,
    mlt_position source_in_frame,
    mlt_position source_out_frame,
    mlt_position base_length,
    int source_is_still,
    mlt_playlist *playlist_out,
    mlt_position *normalized_start_out,
    mlt_position *normalized_source_in_out,
    mlt_position *normalized_source_out_out
);

int mlt_composition_set_geometry(
    mlt_transition transition,
    double x,
    double y,
    double width,
    double height,
    double opacity
);

int mlt_composition_configure_transition(
    mlt_transition transition,
    double x,
    double y,
    double width,
    double height,
    double opacity
);

int mlt_composition_get_geometry(
    mlt_transition transition,
    double *x_out,
    double *y_out,
    double *width_out,
    double *height_out,
    double *opacity_out
);

mlt_filter mlt_composition_attach_alpha_filter(
    mlt_producer target,
    int mode
);

int mlt_composition_apply_alpha_mode(
    mlt_filter filter,
    int mode
);

#ifdef __cplusplus
}
#endif

#endif
