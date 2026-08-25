#!/usr/bin/env bash
# tools/thumbnail_smoke.sh
#
# Focused native coverage for the Explorer thumbnail path.
#
# ffmpeg is used only here to manufacture deterministic test fixtures. The
# application runtime thumbnail generator itself does not shell out to ffmpeg.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EPHEMERAL="linux/flutter/ephemeral"

fail() {
    echo "thumbnail-smoke: $*" >&2
    exit 1
}

[ -d "$EPHEMERAL/flutter_linux" ] || fail \
    "missing $EPHEMERAL. Run 'flutter precache --linux' first."

[ -f "$EPHEMERAL/libflutter_linux_gtk.so" ] || fail \
    "missing the Flutter engine library in $EPHEMERAL."

pkg-config --exists mlt-framework-7 || fail \
    "libmlt-dev not found. See the requirements in README.md."

command -v ffmpeg >/dev/null || fail \
    "ffmpeg is required only to generate the deterministic smoke fixtures."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MLT_DATA_DIR="$(pkg-config --variable=prefix mlt-framework-7)/share/mlt-7"
[ -d "$MLT_DATA_DIR" ] || echo \
    "thumbnail-smoke: warning, $MLT_DATA_DIR is missing. Install libmlt-data." >&2

echo "thumbnail-smoke: building bridge with native thumbnail generator"

gcc -shared -fPIC \
    native/mlt_bridge.c \
    native/mlt_composition.c \
    native/mlt_export.c \
    native/mlt_thumbnail.c \
    -o "$WORK/libmlt_bridge.so" \
    -Inative \
    -I"$EPHEMERAL" \
    $(pkg-config --cflags mlt-framework-7 gtk+-3.0 epoxy) \
    $(pkg-config --libs mlt-framework-7 gtk+-3.0 epoxy) \
    -L"$EPHEMERAL" \
    -l:libflutter_linux_gtk.so \
    -lm \
    -Wall -Wextra -Wshadow -Werror \
    -Wl,--no-undefined

cp "$EPHEMERAL/libflutter_linux_gtk.so" "$WORK/"

echo "thumbnail-smoke: building focused test"

gcc \
    native/mlt_thumbnail_smoke.c \
    -o "$WORK/mlt_thumbnail_smoke" \
    -Inative \
    $(pkg-config --cflags glib-2.0 gdk-pixbuf-2.0) \
    $(pkg-config --libs glib-2.0 gdk-pixbuf-2.0) \
    -L"$WORK" -lmlt_bridge \
    -Wl,-rpath,"$WORK" \
    -Wall -Wextra -Werror

VIDEO="$WORK/black-leader.mp4"
STILL="$WORK/still.png"
VIDEO_JPEG="$WORK/video-thumbnail.jpg"
STILL_JPEG="$WORK/still-thumbnail.jpg"

echo "thumbnail-smoke: generating deterministic fixtures"

# Six seconds at 25 fps: two seconds of pure black, followed by four seconds
# of detailed test imagery. A fixed one-second thumbnail seek would be black;
# representative-frame selection should choose frame 50 or later.
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=black:s=640x360:r=25:d=2" \
    -f lavfi -i "testsrc2=size=640x360:rate=25:duration=4" \
    -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0,format=yuv420p[v]" \
    -map "[v]" \
    -c:v libx264 \
    "$VIDEO"

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=royalblue:s=800x600" \
    -frames:v 1 \
    "$STILL"

echo "thumbnail-smoke: running MLT thumbnail coverage"
echo

LD_LIBRARY_PATH="$WORK" \
SDL_AUDIODRIVER=dummy \
    "$WORK/mlt_thumbnail_smoke" \
    "$VIDEO" \
    "$STILL" \
    "$VIDEO_JPEG" \
    "$STILL_JPEG"
