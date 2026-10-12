#!/bin/bash
# Generates deterministic test media into TestStreams/generated/ using the host
# ffmpeg CLI (brew). Idempotent: skips files that already exist.
#
# Fixture matrix (PLAN.md §8.2):
#   basic.mp4      — H.264 + AAC, 10 s VOD
#   wrap.ts        — MPEG-TS whose raw 33-bit timestamps wrap mid-file
#   multitrack.mkv — video + 2 audio languages + SRT subtitles + chapters
#   multilang.mkv  — video + eng (default disposition) + ger audio
#   forcedsubs.mkv — video + eng audio + a FORCED eng subtitle track
#   surround71.mkv — FLAC 7.1 audio-only
#   truehd.mkv     — TrueHD 5.1 audio-only (40-sample access units)
#   interlaced.ts  — 1080i-style MPEG-TS, field-coded, TFF (deinterlacer input)
#   av1.mkv        — AV1 Main 10-bit + AAC (software AV1 via dav1d on most hosts)
#   catchup.ts     — two TS chunks concatenated, each restarting its timestamps
#   anamorphic.ts  — 720x576i PAL SD, pixel aspect 64:45 (a 16:9 picture), untagged colour
#   hls-live/      — 12 s as six 2 s HLS segments + playlist (served live by the tests)
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

# 60 s MKV: matroska writes its cues at end-of-file, so over an HTTP server
# that ignores Range requests every seek falls back to the earliest cluster —
# the session must re-anchor to the delivered position instead of wedging.
gen seekcues.mkv \
    -f lavfi -i "testsrc2=duration=60:size=320x180:rate=25" \
    -f lavfi -i "sine=frequency=440:duration=60" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 50 \
    -c:a aac -shortest -f matroska

# TrueHD decodes to 40-sample access units (0.83 ms at 48 kHz, 1200 frames/s) —
# the extreme small-frame case the audio decoder must coalesce, or downstream
# frame queues hold almost no audio. Encoder is experimental, hence -strict -2.
gen truehd.mkv \
    -f lavfi -i "sine=frequency=440:duration=4" \
    -af "aformat=channel_layouts=5.1(side):sample_rates=48000" \
    -c:a truehd -strict -2

# Interlaced MPEG-TS, the shape European broadcast (and therefore IPTV) sport
# arrives in: 50 fields/s woven into 25 flagged interlaced frames, top field
# first. `interlace` halves the 50p source into 25i; +ilme+ildct makes the
# encoder code the fields rather than quietly encoding a combed progressive
# frame, so the decoder actually sets AV_FRAME_FLAG_INTERLACED.
#
# Field order comes from the `interlace` filter, which flags every frame TFF.
# Do not re-assert it with the encoder's `-top 1`: that was AVCodecContext's
# deprecated top_field_first, and an FFmpeg 9 host CLI rejects it outright
# ("Codec AVOption top (top field first) is not a encoding option"), which
# fails fixture generation and with it every deinterlace test.
# AV1 in 10 bit, as streaming services and Dolby Vision profile 10 ship it.
# Most Apple chips have no AV1 hardware decoder, and FFmpeg's native AV1
# decoder cannot decode without one — this fixture is what proves the
# software path (dav1d) exists. SVT-AV1 ships with Homebrew's ffmpeg.
gen av1.mkv \
    -f lavfi -i "testsrc2=duration=4:size=320x180:rate=24" \
    -f lavfi -i "sine=frequency=440:duration=4" \
    -c:v libsvtav1 -preset 12 -pix_fmt yuv420p10le -g 24 \
    -c:a aac -shortest

gen interlaced.ts \
    -f lavfi -i "testsrc2=duration=4:size=640x360:rate=50" \
    -vf "interlace=scan=tff" \
    -c:v mpeg2video -flags +ilme+ildct -g 25 -f mpegts

# Two audio languages where the container's own default flag (eng) is the
# *wrong* answer for a German-preferring viewer: the ordered preference must
# beat the disposition, and an empty/unmatched preference must leave it alone.
gen multilang.mkv \
    -f lavfi -i "testsrc2=duration=5:size=320x180:rate=25" \
    -f lavfi -i "sine=frequency=440:duration=5" \
    -f lavfi -i "sine=frequency=880:duration=5" \
    -map 0:v -map 1:a -map 2:a \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac \
    -metadata:s:a:0 language=eng -metadata:s:a:1 language=ger \
    -disposition:a:0 default -f matroska

# A forced subtitle track under English-only audio: the one case where the
# engine enables subtitles by itself (viewer prefers another audio language,
# so the dialogue they get is foreign and the signs/foreign-speech track is
# what the mux author meant them to see).
if [ ! -f "$OUT/forcedsubs.mkv" ]; then
    cat > "$OUT/forced.srt" <<'SRT'
1
00:00:01,000 --> 00:00:03,000
[speaking another language]
SRT
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=duration=5:size=320x180:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=5" \
        -i "$OUT/forced.srt" \
        -map 0:v -map 1:a -map 2:s \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        -c:a aac -c:s srt \
        -metadata:s:a:0 language=eng -metadata:s:s:0 language=eng \
        -disposition:s:0 forced \
        "$OUT/forcedsubs.mkv"
    echo "generated: $OUT/forcedsubs.mkv"
fi

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

# Catch-up archives are served as TS chunks glued end to end, and every chunk
# restarts its timestamps: 6 s of media at 600 s, then 6 s more starting back
# at 1.4 s. Without folding, the second chunk lands ten minutes before the
# clock and everything in it is late.
if [ ! -f "$OUT/catchup.ts" ]; then
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=duration=6:size=320x180:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=6" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 25 \
        -c:a aac -shortest -muxdelay 0 -output_ts_offset 600 -f mpegts \
        "$OUT/catchup-a.ts"
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=duration=6:size=320x180:rate=25" \
        -f lavfi -i "sine=frequency=660:duration=6" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 25 \
        -c:a aac -shortest -f mpegts \
        "$OUT/catchup-b.ts"
    cat "$OUT/catchup-a.ts" "$OUT/catchup-b.ts" > "$OUT/catchup.ts"
    rm -f "$OUT/catchup-a.ts" "$OUT/catchup-b.ts"
    echo "generated: $OUT/catchup.ts"
fi

# PAL SD the way a broadcast channel carries 16:9: 720x576 interlaced with
# 64:45 pixels, and no colour description in the stream. Interlaced, so it
# goes through the deinterlacer and an engine-filled pixel buffer.
gen anamorphic.ts \
    -f lavfi -i "testsrc2=duration=2:size=720x576:rate=50" \
    -vf "interlace=scan=tff,setsar=64/45" \
    -c:v mpeg2video -flags +ilme+ildct -g 25 -f mpegts

# HLS segments for a live channel. The tests serve the playlist without its
# end marker first, so FFmpeg opens it as live, and with it on every refresh —
# a provider ending the broadcast, or appending the marker during an outage.
if [ ! -f "$OUT/hls-live/index.m3u8" ]; then
    mkdir -p "$OUT/hls-live"
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=duration=12:size=320x180:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=12" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 50 -keyint_min 50 \
        -c:a aac -shortest \
        -f hls -hls_time 2 -hls_list_size 0 \
        -hls_segment_filename "$OUT/hls-live/seg%d.ts" \
        "$OUT/hls-live/index.m3u8"
    echo "generated: $OUT/hls-live/index.m3u8"
fi

echo "fixtures ready in $OUT"
