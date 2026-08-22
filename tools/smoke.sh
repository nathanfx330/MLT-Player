#!/usr/bin/env bash
#
# tools/smoke.sh
#
# Builds the native bridge and the headless test outside of Flutter's build,
# generates fixtures, and runs the test against a dummy audio device.
#
# This answers one question and only one: is the problem in MLT and the
# bridge, or in the Flutter integration. Run it before debugging the UI.
#
#   tools/smoke.sh                  # generates a test clip with ffmpeg
#   tools/smoke.sh /path/clip.mp4   # uses your own media
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

STILL=""
if command -v ffmpeg >/dev/null; then
    STILL="$WORK/still.png"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=320x240" -frames:v 1 "$STILL"
fi

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------

echo "smoke: running against $(basename "$MEDIA")"
echo

LD_LIBRARY_PATH="$WORK" \
SDL_AUDIODRIVER=dummy \
    "$WORK/mlt_smoke" "$MEDIA" "$JUNK" $STILL
