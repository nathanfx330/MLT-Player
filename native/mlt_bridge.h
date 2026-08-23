/* native/mlt_bridge.h */

#ifndef MLT_PLAYER_MLT_BRIDGE_H
#define MLT_PLAYER_MLT_BRIDGE_H

#include <stdint.h>

typedef struct _FlTextureRegistrar FlTextureRegistrar;
typedef struct _MltBridgeEngine MltBridgeEngine;

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

/*
 * Playback state lives in an opaque engine handle. The process-wide MLT
 * repository and Flutter texture registrar remain shared infrastructure.
 * Activate an engine on each calling thread before using the legacy-shaped
 * media/transport/property operations below.
 */
MLT_BRIDGE_EXPORT MltBridgeEngine *
mlt_bridge_engine_create(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_engine_activate(
    MltBridgeEngine *engine
);

MLT_BRIDGE_EXPORT void
mlt_bridge_engine_destroy(
    MltBridgeEngine *engine
);

MLT_BRIDGE_EXPORT const char *
mlt_bridge_version(void);

/*
 * Mutable bridge strings use caller-owned copy-out buffers. Return value is
 * the required capacity including the trailing NUL; pass NULL/0 to query.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_last_error_copy(
    char *buffer,
    int capacity
);

/* ------------------------------------------------------------------------- */
/* Flutter texture                                                           */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT int64_t
mlt_bridge_register_flutter_texture(
    FlTextureRegistrar *registrar
);

MLT_BRIDGE_EXPORT void
mlt_bridge_unregister_flutter_texture(void);

/*
 * Select which opaque engine owns the single Flutter preview path. MLT 7.22
 * sdl2_audio is process-global enough that only this selected engine may own
 * a live preview consumer; background engines still own independent producers
 * and may be probed/searched/seeked without opening SDL audio.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_engine_set_texture_source(
    MltBridgeEngine *engine
);

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

/*
 * Export an inclusive absolute source-frame range as display-size PNG files.
 * output_directory is a dedicated directory; filenames are frame_000001.png,
 * frame_000002.png, and so on.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_export_png_sequence_start(
    const char *source_path,
    const char *output_directory,
    int64_t in_frame,
    int64_t out_frame
);

/*
 * Export an inclusive absolute source-frame range as uncompressed 24-bit PCM
 * WAV audio. Video is disabled explicitly; preview playback is unaffected.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_export_audio_start(
    const char *source_path,
    const char *output_path,
    int64_t in_frame,
    int64_t out_frame
);

MLT_BRIDGE_EXPORT void
mlt_bridge_export_cancel(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_export_is_running(void);

MLT_BRIDGE_EXPORT double
mlt_bridge_export_progress(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_export_succeeded(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_export_error_copy(
    char *buffer,
    int capacity
);

/* ------------------------------------------------------------------------- */
/* Media                                                                     */
/* ------------------------------------------------------------------------- */

MLT_BRIDGE_EXPORT int
mlt_bridge_open(
    const char *path
);

/*
 * Layer 2 is placed at an exact primary-timeline frame. Timed video plays for
 * its real duration; still images are held from their insertion frame through
 * the end of Movie A. The primary movie remains the duration/profile/inspection
 * authority. POC 10.6 adds alpha detection and explicit interpretation for
 * transparent PNG/video overlays.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_add_track(
    const char *path,
    int64_t start_frame
);

MLT_BRIDGE_EXPORT int
mlt_bridge_track_count(void);

MLT_BRIDGE_EXPORT int64_t
mlt_bridge_secondary_start_frame(void);

/* Track 2 video opacity only; audio level is controlled independently. */
MLT_BRIDGE_EXPORT int
mlt_bridge_set_secondary_opacity(
    double opacity
);

MLT_BRIDGE_EXPORT double
mlt_bridge_secondary_opacity(void);

/*
 * POC 10.8: Layer 2 presentation geometry in base-frame pixels. Scale is
 * uniform: 1.0 means the source's native presentation size for a still image
 * unless it had to fit down, or the base-frame fit size for timed video.
 * Anchor indices are row-major: 0 top-left through 8 bottom-right.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_set_secondary_geometry(
    double x,
    double y,
    double scale
);

MLT_BRIDGE_EXPORT int
mlt_bridge_set_secondary_anchor(
    int anchor
);

MLT_BRIDGE_EXPORT double
mlt_bridge_secondary_x(void);

MLT_BRIDGE_EXPORT double
mlt_bridge_secondary_y(void);

MLT_BRIDGE_EXPORT double
mlt_bridge_secondary_scale(void);

/*
 * POC 10.6 layer metadata / alpha interpretation.
 * Alpha mode: 0 Auto/native, 1 Straight/native, 2 Premultiplied (unpremultiply
 * RGB before MLT's existing composite transition applies alpha).
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_secondary_is_still(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_secondary_has_alpha(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_set_secondary_alpha_mode(
    int mode
);

MLT_BRIDGE_EXPORT int
mlt_bridge_secondary_alpha_mode(void);

/*
 * POC 10.5: per-track audio gain before the tractor mix.
 * Track indices are zero-based. Current builds expose track 0 and track 1.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_track_has_audio(
    int track_index
);

MLT_BRIDGE_EXPORT int
mlt_bridge_set_track_audio_gain(
    int track_index,
    double gain
);

MLT_BRIDGE_EXPORT double
mlt_bridge_track_audio_gain(
    int track_index
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

/* Exact frame-native transport for frame stepping and edit boundaries. */
MLT_BRIDGE_EXPORT int
mlt_bridge_seek_frame(
    int64_t frame
);

MLT_BRIDGE_EXPORT int64_t
mlt_bridge_position_frame(void);

/* Millisecond transport remains available for time-based UI scrubbing. */
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

MLT_BRIDGE_EXPORT int
mlt_bridge_video_codec_name_copy(char *buffer, int capacity);

MLT_BRIDGE_EXPORT int
mlt_bridge_video_codec_long_name_copy(char *buffer, int capacity);

MLT_BRIDGE_EXPORT int
mlt_bridge_audio_codec_name_copy(char *buffer, int capacity);

MLT_BRIDGE_EXPORT int
mlt_bridge_audio_codec_long_name_copy(char *buffer, int capacity);

/*
 * Per-stream inspection. Index is the absolute container stream index.
 * MLT 7.22 explicitly labels video/audio stream types; other stream types
 * remain enumerable and are reported as "other" when no type label exists.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_stream_type_copy(int index, char *buffer, int capacity);

MLT_BRIDGE_EXPORT int
mlt_bridge_stream_codec_name_copy(int index, char *buffer, int capacity);

MLT_BRIDGE_EXPORT int
mlt_bridge_stream_codec_long_name_copy(int index, char *buffer, int capacity);

MLT_BRIDGE_EXPORT int
mlt_bridge_stream_language_copy(int index, char *buffer, int capacity);

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
MLT_BRIDGE_EXPORT int
mlt_bridge_video_pixel_format_copy(char *buffer, int capacity);

MLT_BRIDGE_EXPORT int
mlt_bridge_video_colorspace(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_video_color_trc(void);

MLT_BRIDGE_EXPORT int
mlt_bridge_video_color_range_copy(char *buffer, int capacity);

/*
 * Embedded/source starting timecode as reported by the loaded producer.
 * Returns an empty string when the file does not expose a timecode tag.
 */
MLT_BRIDGE_EXPORT int
mlt_bridge_source_timecode_copy(char *buffer, int capacity);

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
