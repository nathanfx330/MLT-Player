#!/usr/bin/env bash
# tools/smoke.sh
#
# Builds the native bridge and the headless test outside of Flutter's build,
# generates fixtures, and runs the test against a dummy audio device.
#
# This answers one question and only one: is the problem in MLT and the
# bridge, or in the Flutter integration. Run it before debugging the UI.
#
#   tools/smoke.sh                  # generates test media with ffmpeg
#   tools/smoke.sh /path/clip.mp4   # uses your own primary media
#
# Requires that Flutter has fetched its Linux artifacts at least once, which
# any of `flutter build linux`, `flutter run -d linux`, or
# `flutter precache --linux` will do.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EPHEMERAL="linux/flutter/ephemeral"

fail() {
    echo "smoke: $*" >&2
    exit 1
}

# --------------------------------------------------------------------------
# Preconditions
# --------------------------------------------------------------------------

[ -d "$EPHEMERAL/flutter_linux" ] || fail \
    "missing $EPHEMERAL. Run 'flutter precache --linux' first."

[ -f "$EPHEMERAL/libflutter_linux_gtk.so" ] || fail \
    "missing the Flutter engine library in $EPHEMERAL."

pkg-config --exists mlt-framework-7 || fail \
    "libmlt-dev not found. See the requirements in README.md."

# The loader producer reads its service dictionary from MLT's data directory.
# Without it every open returns NULL and says nothing about why.
MLT_DATA_DIR="$(pkg-config --variable=prefix mlt-framework-7)/share/mlt-7"
[ -d "$MLT_DATA_DIR" ] || echo \
    "smoke: warning, $MLT_DATA_DIR is missing. Install libmlt-data." >&2

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

echo "smoke: building the bridge"

gcc -shared -fPIC \
    native/mlt_bridge.c \
    native/mlt_composition.c \
    native/mlt_export.c \
    -o "$WORK/libmlt_bridge.so" \
    -Inative \
    -I"$EPHEMERAL" \
    $(pkg-config --cflags mlt-framework-7 gtk+-3.0 epoxy) \
    $(pkg-config --libs mlt-framework-7 gtk+-3.0 epoxy) \
    -L"$EPHEMERAL" \
    -l:libflutter_linux_gtk.so \
    -Wall -Wextra -Wshadow -Werror \
    -Wl,--no-undefined

cp "$EPHEMERAL/libflutter_linux_gtk.so" "$WORK/"

echo "smoke: building the test"

gcc \
    native/mlt_smoke.c \
    -o "$WORK/mlt_smoke" \
    -Inative \
    $(pkg-config --cflags glib-2.0) \
    $(pkg-config --libs glib-2.0) \
    -L"$WORK" -lmlt_bridge \
    -Wl,-rpath,"$WORK" \
    -Wall -Wextra -Werror

echo "smoke: building the no-active-engine guard test"

gcc \
    native/mlt_guard_smoke.c \
    -o "$WORK/mlt_guard_smoke" \
    -Inative \
    -L"$WORK" -lmlt_bridge \
    -Wl,-rpath,"$WORK" \
    -Wall -Wextra -Werror

echo "smoke: building the preview/export parity test"

gcc \
    native/mlt_parity_smoke.c \
    -o "$WORK/mlt_parity_smoke" \
    -Inative \
    $(pkg-config --cflags glib-2.0) \
    $(pkg-config --libs glib-2.0) \
    -L"$WORK" -lmlt_bridge \
    -Wl,-rpath,"$WORK" \
    -Wall -Wextra -Werror \
    -lm


echo "smoke: building the layer timing test"

gcc \
    native/mlt_layer_timing_smoke.c \
    -o "$WORK/mlt_layer_timing_smoke" \
    -Inative \
    $(pkg-config --cflags glib-2.0) \
    $(pkg-config --libs glib-2.0) \
    -L"$WORK" -lmlt_bridge \
    -Wl,-rpath,"$WORK" \
    -Wall -Wextra -Werror


echo "smoke: building the layer source-trim test"

gcc \
    native/mlt_layer_source_trim_smoke.c \
    -o "$WORK/mlt_layer_source_trim_smoke" \
    -Inative \
    $(pkg-config --cflags glib-2.0) \
    $(pkg-config --libs glib-2.0) \
    -L"$WORK" -lmlt_bridge \
    -Wl,-rpath,"$WORK" \
    -Wall -Wextra -Werror


echo "smoke: building the layer order test"

gcc \
    native/mlt_layer_order_smoke.c \
    -o "$WORK/mlt_layer_order_smoke" \
    -Inative \
    $(pkg-config --cflags glib-2.0) \
    $(pkg-config --libs glib-2.0) \
    -L"$WORK" -lmlt_bridge \
    -Wl,-rpath,"$WORK" \
    -Wall -Wextra -Werror \
    -lm


echo "smoke: building the video export preset test"

gcc \
    native/mlt_export_preset_smoke.c \
    -o "$WORK/mlt_export_preset_smoke" \
    -Inative \
    $(pkg-config --cflags glib-2.0) \
    $(pkg-config --libs glib-2.0) \
    -L"$WORK" -lmlt_bridge \
    -Wl,-rpath,"$WORK" \
    -Wall -Wextra -Werror


echo "smoke: building the video export frame-rate test"

gcc \
    native/mlt_export_frame_rate_smoke.c \
    -o "$WORK/mlt_export_frame_rate_smoke" \
    -Inative \
    $(pkg-config --cflags glib-2.0) \
    $(pkg-config --libs glib-2.0) \
    -L"$WORK" -lmlt_bridge \
    -Wl,-rpath,"$WORK" \
    -Wall -Wextra -Werror


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

MEDIA="${1:-}"

if [ -z "$MEDIA" ]; then
    command -v ffmpeg >/dev/null || fail \
        "no media given and ffmpeg is not installed."

    MEDIA="$WORK/sample.mp4"

    echo "smoke: generating a test clip"

    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=640x360:rate=25:duration=6" \
        -f lavfi -i "sine=frequency=440:duration=6" \
        -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest \
        "$MEDIA"
fi

[ -f "$MEDIA" ] || fail "no such file: $MEDIA"

# A text file is the interesting negative case: MLT's loader turns it into a
# pango text producer with a 15000 frame default length rather than failing,
# so the bridge has to refuse it on its own.
JUNK="$WORK/not-media.txt"
printf 'This is not a video.\n' > "$JUNK"

ALPHA_STILL=""
ALPHA_VIDEO=""

if command -v ffmpeg >/dev/null; then
    ALPHA_STILL="$WORK/alpha-still.png"
    ALPHA_VIDEO="$WORK/alpha-video.mov"

    echo "smoke: generating alpha fixtures"

    # Oversized semi-transparent RGBA PNG. It is intentionally larger than
    # the generated 640x360 base movie so the smoke test proves that a still
    # layer never expands the base canvas. colorchannelmixer forces a real
    # 8-bit alpha channel instead of relying on a filename/container hint.
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i \
        "color=c=red:s=1280x720,format=rgba,colorchannelmixer=aa=0.5" \
        -frames:v 1 \
        "$ALPHA_STILL"

    # QuickTime Animation is deliberately simple here: it is lossless, carries
    # alpha, and decodes through avformat without requiring an editor-specific
    # plugin. The fixture is short because we only need to prove alpha topology.
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i \
        "testsrc2=size=320x180:rate=25:duration=1,format=rgba,colorchannelmixer=aa=0.5" \
        -c:v qtrle -pix_fmt argb \
        "$ALPHA_VIDEO"
fi

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------

echo "smoke: running no-active-engine guards"
echo

LD_LIBRARY_PATH="$WORK" \
SDL_AUDIODRIVER=dummy \
    "$WORK/mlt_guard_smoke"

echo
echo "smoke: running against $(basename "$MEDIA")"
echo

ARGS=("$MEDIA" "$JUNK")

if [ -n "$ALPHA_STILL" ]; then
    ARGS+=("$ALPHA_STILL")

    if [ -n "$ALPHA_VIDEO" ]; then
        ARGS+=("$ALPHA_VIDEO")
    fi
fi

LD_LIBRARY_PATH="$WORK" \
SDL_AUDIODRIVER=dummy \
    "$WORK/mlt_smoke" "${ARGS[@]}"

echo
echo "smoke: running preview/export parity"
echo

PARITY_ARGS=("$MEDIA")
if [ -n "$ALPHA_STILL" ]; then
    PARITY_ARGS+=("$ALPHA_STILL")
fi

LD_LIBRARY_PATH="$WORK" \
SDL_AUDIODRIVER=dummy \
    "$WORK/mlt_parity_smoke" "${PARITY_ARGS[@]}"

echo
echo "smoke: running layer timing coverage"
echo

LD_LIBRARY_PATH="$WORK" \
SDL_AUDIODRIVER=dummy \
    "$WORK/mlt_layer_timing_smoke" "$MEDIA"

echo
echo "smoke: running layer source-trim coverage"
echo

LD_LIBRARY_PATH="$WORK" \
SDL_AUDIODRIVER=dummy \
    "$WORK/mlt_layer_source_trim_smoke" "$MEDIA"

echo
echo "smoke: running layer order coverage"
echo

LD_LIBRARY_PATH="$WORK" \
SDL_AUDIODRIVER=dummy \
    "$WORK/mlt_layer_order_smoke" "$MEDIA"

echo
echo "smoke: running video export preset coverage"
echo

PRESET_MOV="$WORK/prores-422-hq.mov"

LD_LIBRARY_PATH="$WORK" \
SDL_AUDIODRIVER=dummy \
    "$WORK/mlt_export_preset_smoke" "$MEDIA" "$PRESET_MOV"

command -v ffprobe >/dev/null || fail \
    "ffprobe is required to validate the ProRes export preset."

VIDEO_CODEC="$(
    ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$PRESET_MOV"
)"

VIDEO_PROFILE="$(
    ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=profile \
        -of default=noprint_wrappers=1:nokey=1 \
        "$PRESET_MOV"
)"

VIDEO_PIX_FMT="$(
    ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=pix_fmt \
        -of default=noprint_wrappers=1:nokey=1 \
        "$PRESET_MOV"
)"

[ "$VIDEO_CODEC" = "prores" ] || fail \
    "ProRes preset encoded '$VIDEO_CODEC' instead of ProRes."
[ "$VIDEO_PROFILE" = "HQ" ] || fail \
    "ProRes preset reported profile '$VIDEO_PROFILE' instead of HQ."
[ "$VIDEO_PIX_FMT" = "yuv422p10le" ] || fail \
    "ProRes preset wrote pixel format '$VIDEO_PIX_FMT' instead of yuv422p10le."

INPUT_AUDIO_CODEC="$(
    ffprobe -v error \
        -select_streams a:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "$MEDIA" \
        2>/dev/null || true
)"

if [ -n "$INPUT_AUDIO_CODEC" ]; then
    OUTPUT_AUDIO_CODEC="$(
        ffprobe -v error \
            -select_streams a:0 \
            -show_entries stream=codec_name \
            -of default=noprint_wrappers=1:nokey=1 \
            "$PRESET_MOV"
    )"

    [ "$OUTPUT_AUDIO_CODEC" = "pcm_s24le" ] || fail \
        "ProRes preset wrote audio codec '$OUTPUT_AUDIO_CODEC' instead of pcm_s24le."
fi

echo "  [ok] ProRes preset is prores / HQ / yuv422p10le"
if [ -n "$INPUT_AUDIO_CODEC" ]; then
    echo "  [ok] ProRes preset uses pcm_s24le audio"
fi


echo
echo "smoke: running video export frame-rate coverage"
echo

FRAME_RATE_MP4="$WORK/frame-rate-2997.mp4"

LD_LIBRARY_PATH="$WORK" \
SDL_AUDIODRIVER=dummy \
    "$WORK/mlt_export_frame_rate_smoke" "$MEDIA" "$FRAME_RATE_MP4"

OUTPUT_FRAME_RATE="$(
    ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=avg_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 \
        "$FRAME_RATE_MP4"
)"

OUTPUT_FRAME_COUNT="$(
    ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=nb_frames \
        -of default=noprint_wrappers=1:nokey=1 \
        "$FRAME_RATE_MP4"
)"

OUTPUT_DURATION="$(
    ffprobe -v error \
        -select_streams v:0 \
        -show_entries stream=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$FRAME_RATE_MP4"
)"

[ "$OUTPUT_FRAME_RATE" = "30000/1001" ] || fail \
    "29.97 conform wrote frame rate '$OUTPUT_FRAME_RATE' instead of 30000/1001."

if [ "$OUTPUT_FRAME_COUNT" != "N/A" ] && [ -n "$OUTPUT_FRAME_COUNT" ]; then
    [ "$OUTPUT_FRAME_COUNT" = "30" ] || fail \
        "29.97 conform wrote $OUTPUT_FRAME_COUNT frames instead of 30 for one source second."
fi

awk -v duration="$OUTPUT_DURATION" 'BEGIN { exit !(duration >= 0.95 && duration <= 1.05) }' || fail \
    "29.97 conform changed one source second into ${OUTPUT_DURATION}s."

echo "  [ok] 25 fps source conforms to 30000/1001 without changing duration"
if [ "$OUTPUT_FRAME_COUNT" != "N/A" ] && [ -n "$OUTPUT_FRAME_COUNT" ]; then
    echo "  [ok] one source second becomes 30 output frames"
fi

