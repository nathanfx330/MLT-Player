/* native/mlt_layers.h */
#ifndef MLT_PLAYER_MLT_LAYERS_H
#define MLT_PLAYER_MLT_LAYERS_H

/*
 * POC 11 composition slots are stable and zero-based.
 * Slot 0 is the base movie. Slots 1 and 2 are overlay layers.
 */
#define MLT_COMPOSITION_MAX_LAYERS 3
#define MLT_COMPOSITION_BASE_LAYER 0
#define MLT_COMPOSITION_FIRST_OVERLAY 1
#define MLT_COMPOSITION_SECOND_OVERLAY 2

#endif
