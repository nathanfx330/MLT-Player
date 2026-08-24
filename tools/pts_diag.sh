#!/usr/bin/env bash
# tools/pts_diag.sh
#
# Reproduces the MLT 7.22 avformat audio-flush PTS warning with a controlled
# audio/silent fixture matrix. This is intentionally diagnostic, not a normal
# smoke/CI gate. When the project raises its MLT baseline, run this script on
# the candidate version; if the warning is gone, promote zero warnings to a
# regression assertion.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EPHEMERAL="linux/flutter/ephemeral"

fail() {
    echo "pts-diag: $*" >&2
    exit 1
}

[ -d "$EPHEMERAL/flutter_linux" ] || fail \
    "missing $EPHEMERAL. Run 'flutter precache --linux' first."
[ -f "$EPHEMERAL/libflutter_linux_gtk.so" ] || fail \
    "missing the Flutter engine library in $EPHEMERAL."
pkg-config --exists mlt-framework-7 || fail \
    "libmlt-dev not found. See the requirements in README.md."
command -v ffmpeg >/dev/null || fail "ffmpeg is required."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MLT_VERSION="$(pkg-config --modversion mlt-framework-7)"
echo "PTS diagnostic on MLT $MLT_VERSION"
echo

echo "pts-diag: building the bridge"
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

echo "pts-diag: building the MP4 PTS diagnostic"
gcc \
    native/mlt_pts_smoke.c \
    -o "$WORK/mlt_pts_smoke" \
    -Inative \
    $(pkg-config --cflags mlt-framework-7) \
    $(pkg-config --libs mlt-framework-7) \
    -L"$WORK" -lmlt_bridge \
    -Wl,-rpath,"$WORK" \
    -Wall -Wextra -Werror

PTS_AUDIO_MEDIA="$WORK/pts-audio.mp4"
PTS_SILENT_MEDIA="$WORK/pts-silent.mp4"
ALPHA_STILL="$WORK/alpha-still.png"

echo "pts-diag: generating controlled fixtures"
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

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i \
    "color=c=red:s=1280x720,format=rgba,colorchannelmixer=aa=0.5" \
    -frames:v 1 \
    "$ALPHA_STILL"

declare -A PTS_WARNING_COUNTS

run_pts_case() {
    local label="$1"
    local mode="$2"
    local media="$3"
    local still="${4:-}"
    local output="$WORK/pts-${label}.mp4"
    local log="$WORK/pts-${label}.log"

    local args=("$mode" "$media" "$output")
    if [ -n "$still" ]; then
        args+=("$still")
    fi

    echo "PTS case: $label"

    LD_LIBRARY_PATH="$WORK" \
    SDL_AUDIODRIVER=dummy \
        "$WORK/mlt_pts_smoke" "${args[@]}" \
        2>"$log"

    local warnings
    warnings="$(grep -cF "Timestamps are unset in a packet" "$log" || true)"
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

run_pts_case "simple-audio" "simple" "$PTS_AUDIO_MEDIA"
run_pts_case "simple-silent" "simple" "$PTS_SILENT_MEDIA"
run_pts_case "layered-audio" "composition" "$PTS_AUDIO_MEDIA" "$ALPHA_STILL"
run_pts_case "layered-silent" "composition" "$PTS_SILENT_MEDIA" "$ALPHA_STILL"

audio_warning_total=$((
    ${PTS_WARNING_COUNTS["simple-audio"]:-0} +
    ${PTS_WARNING_COUNTS["layered-audio"]:-0}
))
silent_warning_total=$((
    ${PTS_WARNING_COUNTS["simple-silent"]:-0} +
    ${PTS_WARNING_COUNTS["layered-silent"]:-0}
))

echo "PTS diagnosis summary"
echo "  MLT version             : $MLT_VERSION"
echo "  audio-fixture warnings : $audio_warning_total"
echo "  silent-fixture warnings: $silent_warning_total"

if [ "$audio_warning_total" -gt 0 ] && [ "$silent_warning_total" -eq 0 ]; then
    echo "  diagnosis: warning follows the presence of an encoded audio stream."
elif [ "$audio_warning_total" -eq 0 ] && [ "$silent_warning_total" -eq 0 ]; then
    echo "  diagnosis: warning did not reproduce; candidate baseline may contain the audio-flush fix."
elif [ "$audio_warning_total" -gt 0 ] && [ "$silent_warning_total" -gt 0 ]; then
    echo "  diagnosis: warning is not isolated to audio; inspect the per-case logs above."
else
    echo "  diagnosis: warning reproduced only in silent output; inspect the per-case logs above."
fi
