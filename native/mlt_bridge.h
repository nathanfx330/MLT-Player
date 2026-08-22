/* native/mlt_bridge.h */

#ifndef MLT_PLAYER_MLT_BRIDGE_H
#define MLT_PLAYER_MLT_BRIDGE_H

#include <stdint.h>

typedef struct _FlTextureRegistrar FlTextureRegistrar;

#if defined(__GNUC__)
#define MLT_BRIDGE_EXPORT __attribute__((visibility("default")))
#else
#define MLT_BRIDGE_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------------- */
/* Lifecycle                                                                 */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT int
mlt_bridge_init(void);

MLT_BRIDGE_EXPORT void
mlt_bridge_shutdown(void);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_version(void);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_last_error(void);

/* ------------------------------------------------------------------------- */
/* Flutter texture                                                           */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT int64_t
mlt_bridge_register_flutter_texture(
    FlTextureRegistrar *registrar
);

MLT_BRIDGE_EXPORT void
mlt_bridge_unregister_flutter_texture(void);

MLT_BRIDGE_EXPORT int64_t
mlt_bridge_texture_id(void);

/* ------------------------------------------------------------------------- */
/* Media                                                                     */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT int
mlt_bridge_open(
    const char *path
);

MLT_BRIDGE_EXPORT void
mlt_bridge_close_media(void);

/* ------------------------------------------------------------------------- */
/* Transport                                                                 */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT int
mlt_bridge_play(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_pause(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_seek_ms(
    int64_t milliseconds
);

MLT_BRIDGE_EXPORT int64_t
mlt_bridge_position_ms(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_is_playing(void);

/*
 * Returns non-zero once playback has reached the last frame.
 * The consumer stops itself at that point, so the UI needs
 * this to distinguish "finished" from "paused".
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_is_eof(void);

/* ------------------------------------------------------------------------- */
/* Audio                                                                     */
/* ------------------------------------------------------------------------- */

/* volume is linear, 0.0 to 1.0 (values above 1.0 are clamped). */
MLT_BRIDGE_EXPORT void
mlt_bridge_set_volume(
    double volume
);

MLT_BRIDGE_EXPORT double
mlt_bridge_volume(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_has_audio(void);

/* ------------------------------------------------------------------------- */
/* Media properties                                                          */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT int64_t
mlt_bridge_duration_frames(void);

MLT_BRIDGE_EXPORT int64_t
mlt_bridge_duration_ms(void);

MLT_BRIDGE_EXPORT double
mlt_bridge_fps(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_width(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_height(void);

/*
 * Display aspect ratio as a single number (width / height of the
 * intended picture, not of the pixel grid). Anamorphic sources have
 * a display aspect that does not match width / height.
 */
MLT_BRIDGE_EXPORT double
mlt_bridge_display_aspect(void);

/*
 * Non-zero when the loaded resource is a still image or another
 * producer with no intrinsic duration. MLT reports a default length
 * (typically 15000 frames) for these, which is meaningless as a
 * timeline, so the UI should suppress the transport for them.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_is_still(void);

#ifdef __cplusplus
}
#endif

#endif
