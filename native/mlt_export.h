/* native/mlt_export.h */
#ifndef MLT_EXPORT_H
#define MLT_EXPORT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum _MltExportKind {
    MLT_EXPORT_KIND_MP4 = 0,
    MLT_EXPORT_KIND_PNG_FRAME = 1,
    MLT_EXPORT_KIND_PNG_SEQUENCE = 2,
    MLT_EXPORT_KIND_WAV_AUDIO = 3
} MltExportKind;

typedef struct _MltExportCompositionSnapshot {
    const char *base_path;
    const char *layer2_path;
    int has_layer2;
    int base_has_audio;
    int layer2_has_audio;
    int layer2_is_still;
    int layer2_alpha_mode;
    int64_t layer2_start_frame;
    double base_audio_gain;
    double layer2_audio_gain;
    double layer2_opacity;
    double layer2_x;
    double layer2_y;
    double layer2_scale;
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
