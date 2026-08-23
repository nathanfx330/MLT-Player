#!/usr/bin/env bash
# tools/generate_export_fixtures.sh
set -euo pipefail

output_dir="${1:-export_fixtures}"
mkdir -p "$output_dir"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

require_tool ffmpeg
require_tool ffprobe

common=( -hide_banner -loglevel error -y )

printf 'Generating progressive A/V fixture...\n'
ffmpeg "${common[@]}" \
  -f lavfi -i "testsrc2=size=640x360:rate=30000/1001" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000" \
  -t 2 \
  -map 0:v:0 -map 1:a:0 \
  -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
  -c:a aac -b:a 192k \
  -shortest \
  "$output_dir/progressive_av.mp4"

printf 'Generating interlaced A/V fixture...\n'
ffmpeg "${common[@]}" \
  -f lavfi -i "testsrc2=size=720x480:rate=60000/1001" \
  -f lavfi -i "sine=frequency=660:sample_rate=48000" \
  -filter_complex "[0:v]tinterlace=mode=interleave_top[v]" \
  -t 2 \
  -map "[v]" -map 1:a:0 \
  -c:v mpeg2video -flags +ilme+ildct -top 1 -b:v 8M -maxrate 8M -bufsize 16M \
  -c:a pcm_s16le \
  -shortest \
  "$output_dir/interlaced_av.mkv"

printf 'Generating video-only fixture...\n'
ffmpeg "${common[@]}" \
  -f lavfi -i "testsrc2=size=640x360:rate=24" \
  -t 2 \
  -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
  -an \
  "$output_dir/video_only.mp4"

printf 'Generating 1440x1080 anamorphic 16:9 fixture...\n'
ffmpeg "${common[@]}" \
  -f lavfi -i "testsrc2=size=1440x1080:rate=24" \
  -t 2 \
  -vf "setsar=4/3" \
  -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
  -an \
  "$output_dir/anamorphic_1440x1080_16x9.mp4"

printf 'Generating 24-bit PCM WAV fixture...\n'
ffmpeg "${common[@]}" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t 2 \
  -c:a pcm_s24le \
  "$output_dir/pcm24.wav"

printf '\nFixture summary:\n'
for file in \
  "$output_dir/progressive_av.mp4" \
  "$output_dir/interlaced_av.mkv" \
  "$output_dir/video_only.mp4" \
  "$output_dir/anamorphic_1440x1080_16x9.mp4" \
  "$output_dir/pcm24.wav"; do
  printf '\n%s\n' "$file"
  ffprobe -v error \
    -show_entries \
      stream=index,codec_type,codec_name,width,height,sample_aspect_ratio,display_aspect_ratio,field_order,sample_fmt,sample_rate,channels,bits_per_raw_sample \
    -of default=noprint_wrappers=1 \
    "$file"
done
