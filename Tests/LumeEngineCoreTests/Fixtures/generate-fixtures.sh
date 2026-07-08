#!/bin/bash
# Generates deterministic test media into TestStreams/generated/ using the host
# ffmpeg CLI (brew). Idempotent: skips files that already exist.
#
# Fixture matrix (PLAN.md §8.2):
#   basic.mp4      — H.264 + AAC, 10 s VOD
#   wrap.ts        — MPEG-TS whose raw 33-bit timestamps wrap mid-file
#   multitrack.mkv — video + 2 audio languages + SRT subtitles + chapters
#   surround71.mkv — FLAC 7.1 audio-only
#   truehd.mkv     — TrueHD 5.1 audio-only (40-sample access units)
set -euo pipefail

FFMPEG="${FFMPEG:-ffmpeg}"
OUT="${1:?usage: generate-fixtures.sh <output-dir>}"
mkdir -p "$OUT"

gen() { # gen <file> <args...>
    local file="$OUT/$1"; shift
    [ -f "$file" ] && return 0
    "$FFMPEG" -hide_banner -loglevel error -y "$@" "$file"
    echo "generated: $file"
}

gen basic.mp4 \
    -f lavfi -i "testsrc2=duration=10:size=640x360:rate=30" \
    -f lavfi -i "sine=frequency=440:duration=10" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 30 \
    -c:a aac -shortest

# 2^33 / 90000 = 95443.7 s. Starting at 95440 s makes raw PTS/DTS wrap ~3.7 s in.
gen wrap.ts \
    -f lavfi -i "testsrc2=duration=12:size=320x180:rate=25" \
    -f lavfi -i "sine=frequency=440:duration=12" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 25 \
    -c:a aac -shortest \
    -muxdelay 0 -output_ts_offset 95440 -f mpegts

# 7.1 FLAC: exercises the multichannel path (channel layout must survive
# decode → resample → CMSampleBuffer, or the renderer plays noise).
gen surround71.mkv \
    -f lavfi -i "sine=frequency=440:duration=4" \
    -af "aformat=channel_layouts=7.1" \
    -c:a flac

# TrueHD decodes to 40-sample access units (0.83 ms at 48 kHz, 1200 frames/s) —
# the extreme small-frame case the audio decoder must coalesce, or downstream
# frame queues hold almost no audio. Encoder is experimental, hence -strict -2.
gen truehd.mkv \
    -f lavfi -i "sine=frequency=440:duration=4" \
    -af "aformat=channel_layouts=5.1(side):sample_rates=48000" \
    -c:a truehd -strict -2

if [ ! -f "$OUT/multitrack.mkv" ]; then
    cat > "$OUT/subs.srt" <<'SRT'
1
00:00:01,000 --> 00:00:03,000
Hello from LumeEngine

2
00:00:04,000 --> 00:00:06,000
Second cue
SRT
    cat > "$OUT/chapters.txt" <<'CHAPTERS'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=4000
title=Intro
[CHAPTER]
TIMEBASE=1/1000
START=4000
END=8000
title=Middle
CHAPTERS
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=duration=8:size=320x180:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=8" \
        -f lavfi -i "sine=frequency=880:duration=8" \
        -i "$OUT/subs.srt" \
        -i "$OUT/chapters.txt" \
        -map 0:v -map 1:a -map 2:a -map 3:s -map_metadata 4 -map_chapters 4 \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        -c:a aac -c:s srt \
        -metadata:s:a:0 language=eng -metadata:s:a:1 language=ger \
        -metadata:s:s:0 language=eng \
        "$OUT/multitrack.mkv"
    echo "generated: $OUT/multitrack.mkv"
fi

echo "fixtures ready in $OUT"
