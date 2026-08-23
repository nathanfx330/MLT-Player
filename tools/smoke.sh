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

echo "smoke: building the MP4 PTS diagnostic"

gcc \
    native/mlt_pts_smoke.c \
    -o "$WORK/mlt_pts_smoke" \
    -Inative \
    $(pkg-config --cflags mlt-framework-7) \
    $(pkg-config --libs mlt-framework-7) \
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

PTS_AUDIO_MEDIA=""
PTS_SILENT_MEDIA=""

if command -v ffmpeg >/dev/null; then
    PTS_AUDIO_MEDIA="$WORK/pts-audio.mp4"
    PTS_SILENT_MEDIA="$WORK/pts-silent.mp4"

    echo "smoke: generating PTS diagnostic fixtures"

    # Dedicated short fixtures keep the timestamp diagnosis independent from
    # whatever primary media the caller supplied to the general smoke suite.
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=320x180:rate=25:duration=2" \
        -f lavfi -i "sine=frequency=660:duration=2" \
        -c:v libx264 -pix_fmt yuv420p \
        -c:a aac -shortest \
        "$PTS_AUDIO_MEDIA"

    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=320x180:rate=25:duration=2" \
        -c:v libx264 -pix_fmt yuv420p \
        -an \
        "$PTS_SILENT_MEDIA"
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

if [ -n "$PTS_AUDIO_MEDIA" ] &&
   [ -n "$PTS_SILENT_MEDIA" ]; then
    echo
    echo "smoke: running MP4 PTS diagnosis"
    echo

    declare -A PTS_WARNING_COUNTS

    run_pts_case() {
        local label="$1"
        local mode="$2"
        local media="$3"
        local still="${4:-}"
        local output="$WORK/pts-${label}.mp4"
        local log="$WORK/pts-${label}.log"

        local args=(
            "$mode"
            "$media"
            "$output"
        )

        if [ -n "$still" ]; then
            args+=("$still")
        fi

        echo "PTS case: $label"

        LD_LIBRARY_PATH="$WORK" \
        SDL_AUDIODRIVER=dummy \
            "$WORK/mlt_pts_smoke" "${args[@]}" \
            2>"$log"

        local warnings
        warnings="$(
            grep -cF \
                "Timestamps are unset in a packet" \
                "$log" || true
        )"

        PTS_WARNING_COUNTS["$label"]="$warnings"

        echo "  unset-PTS warnings: $warnings"

        if command -v ffprobe >/dev/null; then
            local streams
            streams="$(
                ffprobe \
                    -v error \
                    -show_entries stream=index,codec_type \
                    -of csv=p=0 \
                    "$output" |
                tr '\n' ' '
            )"

            echo "  output streams: ${streams:-none}"
        fi

        local relevant
        relevant="$(
            grep -E \
                'audio stream [0-9]+ pkt pts|Timestamps are unset in a packet|Encoder did not produce proper pts' \
                "$log" |
            tail -n 12 || true
        )"

        if [ -n "$relevant" ]; then
            echo "  relevant MLT/FFmpeg log tail:"
            while IFS= read -r line; do
                echo "    $line"
            done <<< "$relevant"
        else
            echo "  relevant MLT/FFmpeg log tail: none"
        fi

        echo
    }

    run_pts_case \
        "simple-audio" \
        "simple" \
        "$PTS_AUDIO_MEDIA"

    run_pts_case \
        "simple-silent" \
        "simple" \
        "$PTS_SILENT_MEDIA"

    if [ -n "$ALPHA_STILL" ]; then
        run_pts_case \
            "layered-audio" \
            "composition" \
            "$PTS_AUDIO_MEDIA" \
            "$ALPHA_STILL"

        run_pts_case \
            "layered-silent" \
            "composition" \
            "$PTS_SILENT_MEDIA" \
            "$ALPHA_STILL"
    else
        PTS_WARNING_COUNTS["layered-audio"]=0
        PTS_WARNING_COUNTS["layered-silent"]=0
        echo "PTS layered cases skipped: no alpha-still fixture."
        echo
    fi

    audio_warning_total=$((
        ${PTS_WARNING_COUNTS["simple-audio"]:-0} +
        ${PTS_WARNING_COUNTS["layered-audio"]:-0}
    ))

    silent_warning_total=$((
        ${PTS_WARNING_COUNTS["simple-silent"]:-0} +
        ${PTS_WARNING_COUNTS["layered-silent"]:-0}
    ))

    echo "PTS diagnosis summary"
    echo "  audio-fixture warnings : $audio_warning_total"
    echo "  silent-fixture warnings: $silent_warning_total"

    if [ "$audio_warning_total" -gt 0 ] &&
       [ "$silent_warning_total" -eq 0 ]; then
        echo "  diagnosis: warning follows the presence of an encoded audio stream."
    elif [ "$audio_warning_total" -eq 0 ] &&
         [ "$silent_warning_total" -eq 0 ]; then
        echo "  diagnosis: warning did not reproduce in the controlled PTS fixtures."
    elif [ "$audio_warning_total" -gt 0 ] &&
         [ "$silent_warning_total" -gt 0 ]; then
        echo "  diagnosis: warning is not isolated to audio; inspect the per-case logs above."
    else
        echo "  diagnosis: warning reproduced only in silent output; inspect the per-case logs above."
    fi
fi

