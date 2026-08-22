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
/* Export                                                                    */
/* ------------------------------------------------------------------------- */

/*
 * Start a background MP4 export using a separate MLT graph. In/out are
 * absolute source frame numbers and are inclusive.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_export_start(
    const char *source_path,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame
);

/*
 * Export one exact absolute source frame as a PNG using the same independent
 * background export machinery. Preview playback is not disturbed.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_export_frame_start(
    const char *source_path,
    const char *output_path,
    int64_t frame
);

MLT_BRIDGE_EXPORT void
mlt_bridge_export_cancel(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_export_is_running(void);

MLT_BRIDGE_EXPORT double
mlt_bridge_export_progress(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_export_succeeded(void);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_export_error(void);

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

/*
 * Set shuttle speed. Positive values play forward, negative values play
 * backward, and magnitudes above 1.0 increase shuttle speed. Use pause()
 * for speed zero so the currently displayed frame is parked precisely.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_set_speed(
    double speed
);

MLT_BRIDGE_EXPORT double
mlt_bridge_speed(void);

/*
 * QuickTime-style Play All Frames. When enabled, the preview consumer uses
 * MLT real_time=-1 so video frames are never dropped to maintain wall-clock
 * speed; playback is allowed to slow down instead.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_set_play_all_frames(
    int enabled
);

MLT_BRIDGE_EXPORT int
mlt_bridge_play_all_frames(void);

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

/*
 * Read-only stream inspection. Stream indices are absolute container stream
 * indices as reported by the avformat producer. Codec strings are empty when
 * the loaded producer does not expose that metadata.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_stream_count(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_video_stream_index(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_audio_stream_index(void);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_video_codec_name(void);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_video_codec_long_name(void);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_audio_codec_name(void);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_audio_codec_long_name(void);

/*
 * Per-stream inspection. Index is the absolute container stream index.
 * MLT 7.22 explicitly labels video/audio stream types; other stream types
 * remain enumerable and are reported as "other" when no type label exists.
 */
MLT_BRIDGE_EXPORT const char *
mlt_bridge_stream_type(int index);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_stream_codec_name(int index);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_stream_codec_long_name(int index);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_stream_language(int index);

MLT_BRIDGE_EXPORT int
mlt_bridge_stream_channels(int index);

MLT_BRIDGE_EXPORT int
mlt_bridge_stream_sample_rate(int index);

MLT_BRIDGE_EXPORT int
mlt_bridge_stream_width(int index);

MLT_BRIDGE_EXPORT int
mlt_bridge_stream_height(int index);

MLT_BRIDGE_EXPORT int64_t
mlt_bridge_stream_bit_rate(int index);

/*
 * Source video format/color metadata for the selected video stream.
 * Strings are empty and integer identifiers are -1 when unavailable.
 */
MLT_BRIDGE_EXPORT const char *
mlt_bridge_video_pixel_format(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_video_colorspace(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_video_color_trc(void);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_video_color_range(void);

/*
 * Embedded/source starting timecode as reported by the loaded producer.
 * Returns an empty string when the file does not expose a timecode tag.
 */
MLT_BRIDGE_EXPORT const char *
mlt_bridge_source_timecode(void);

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
