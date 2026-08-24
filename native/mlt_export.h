/* native/mlt_export.h */
#ifndef MLT_EXPORT_H
#define MLT_EXPORT_H

#include <stdint.h>

#include "mlt_layers.h"
#include "mlt_parity.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum _MltExportKind {
    MLT_EXPORT_KIND_MP4 = 0,
    MLT_EXPORT_KIND_PNG_FRAME = 1,
    MLT_EXPORT_KIND_PNG_SEQUENCE = 2,
    MLT_EXPORT_KIND_WAV_AUDIO = 3
} MltExportKind;

typedef struct _MltExportLayerSnapshot {
    const char *path;
    int present;
    int64_t start_frame;
    int64_t end_frame;
    int64_t source_in_frame;
    int64_t source_out_frame;

    int has_audio;
    int is_still;
    int alpha_mode;

    double audio_gain;
    double opacity;
    double x;
    double y;
    double scale;
} MltExportLayerSnapshot;

/*
 * POC 11 composition snapshot. Slot 0 is the base movie; slots 1 and 2 are
 * independent overlays. Preview and export consume the same three-slot value
 * state so Layer 3 cannot drift from the live tractor during export.
 */
typedef struct _MltExportCompositionSnapshot {
    int layer_count;
    MltExportLayerSnapshot layers[MLT_COMPOSITION_MAX_LAYERS];
} MltExportCompositionSnapshot;

void mlt_export_set_error(const char *message);

int mlt_export_start_simple(
    const char *source_path,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame,
    MltExportKind kind
);

int mlt_export_start_composition(
    const MltExportCompositionSnapshot *snapshot,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame,
    MltExportKind kind
);

int mlt_export_derive_composition(
    const MltExportCompositionSnapshot *snapshot,
    int64_t in_frame,
    int64_t out_frame,
    MltCompositionDerivedState *state_out,
    char *error_buffer,
    int error_capacity
);

void mlt_export_cancel(void);
int mlt_export_is_running(void);
double mlt_export_progress(void);
int mlt_export_succeeded(void);
int mlt_export_error_copy(char *buffer, int capacity);
void mlt_export_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
