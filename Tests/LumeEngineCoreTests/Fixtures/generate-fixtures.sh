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
#   replay.ts      — 8 s TS whose bytes jump back ~3 s at ~6 s, as a reconnect replays them
#   ac4.ts         — TS whose first audio (ger) is declared AC-4, which no decoder here plays, then eng AAC
#   hdr10.mp4      — HEVC Main 10, BT.2020 PQ, mastering display + content light level SEI, HDR10+ per frame
#   surround51.ts  — 20 s H.264 + AC-3 5.1 MPEG-TS, tone in the centre channel only
#   captions.ts    — H.264 TS with CEA-608 captions in A/53 SEI (1–3 s, 4–6 s; needs python3)
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

# What a live channel's byte stream looks like across a reconnect: the server
# answers the new request with seconds the client already received. Cut at
# three quarters of the file and continue from three eighths (on 188-byte TS
# packet boundaries), so about 3 s arrive twice.
if [ ! -f "$OUT/replay.ts" ]; then
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=duration=8:size=320x180:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=8" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 25 \
        -c:a aac -shortest -muxdelay 0 -output_ts_offset 600 -f mpegts \
        "$OUT/replay-source.ts"
    packets=$(( $(wc -c < "$OUT/replay-source.ts") / 188 ))
    {
        dd if="$OUT/replay-source.ts" bs=188 count=$(( packets * 3 / 4 )) 2>/dev/null
        dd if="$OUT/replay-source.ts" bs=188 skip=$(( packets * 3 / 8 )) 2>/dev/null
    } > "$OUT/replay.ts"
    rm -f "$OUT/replay-source.ts"
    echo "generated: $OUT/replay.ts"
fi

# A DVB mux whose first audio track is AC-4, which this FFmpeg build has no
# decoder (or parser) for. No encoder writes AC-4, so an AC-3 track is
# re-declared in every PMT: stream_type 0x06 plus an "AC-4" registration
# descriptor (the language descriptor is kept), with the section CRC redone.
# The payload stays AC-3; nothing ever decodes it.
if [ ! -f "$OUT/ac4.ts" ]; then
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=duration=6:size=320x180:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=6" \
        -f lavfi -i "sine=frequency=880:duration=6" \
        -map 0:v -map 1:a -map 2:a \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 25 \
        -c:a:0 ac3 -c:a:1 aac -metadata:s:a:0 language=ger -metadata:s:a:1 language=eng \
        -shortest -muxdelay 0 -f mpegts "$OUT/ac4-source.ts"
    python3 -I - "$OUT/ac4-source.ts" "$OUT/ac4.ts" <<'PATCH'
import sys
PMT_PID, TARGET_PID = 0x1000, 0x101  # the muxer's defaults: PMT, first audio

def crc32_mpeg(data):
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7 if crc & 0x80000000 else crc << 1) & 0xFFFFFFFF
    return crc

data = bytearray(open(sys.argv[1], "rb").read())
patched = 0
for off in range(0, len(data), 188):
    pkt = data[off:off + 188]
    if ((pkt[1] & 0x1F) << 8 | pkt[2]) != PMT_PID or not pkt[1] & 0x40:
        continue
    p = 4 + (1 + pkt[4] if pkt[3] & 0x20 else 0)
    p += 1 + pkt[p]  # pointer field
    sec = pkt[p:]
    body = sec[3:3 + ((sec[1] & 0x0F) << 8 | sec[2]) - 4]
    info_len = (body[7] & 0x0F) << 8 | body[8]
    head, es = body[:9 + info_len], body[9 + info_len:]
    out, i = bytearray(), 0
    while i < len(es):
        stream_type, pid = es[i], (es[i + 1] & 0x1F) << 8 | es[i + 2]
        desc_len = (es[i + 3] & 0x0F) << 8 | es[i + 4]
        desc = bytes(es[i + 5:i + 5 + desc_len])
        if pid == TARGET_PID:
            kept, j = b"", 0
            while j < len(desc):  # drop AC-3/E-AC-3/registration descriptors
                if desc[j] not in (0x05, 0x6A, 0x7A, 0x81):
                    kept += desc[j:j + 2 + desc[j + 1]]
                j += 2 + desc[j + 1]
            stream_type, desc = 0x06, kept + b"\x05\x04AC-4"
            patched += 1
        out += bytes([stream_type, es[i + 1], es[i + 2], 0xF0 | len(desc) >> 8, len(desc) & 0xFF]) + desc
        i += 5 + desc_len
    new = bytes(head) + bytes(out)
    new = bytes([sec[0], (sec[1] & 0xF0) | (len(new) + 4) >> 8, (len(new) + 4) & 0xFF]) + new
    new += crc32_mpeg(new).to_bytes(4, "big")
    assert len(new) <= 188 - p
    data[off + p:off + 188] = new + b"\xff" * (188 - p - len(new))
if not patched:
    sys.exit("ac4.ts: no PMT entry for the first audio track")
open(sys.argv[2], "wb").write(data)
PATCH
    rm -f "$OUT/ac4-source.ts"
    echo "generated: $OUT/ac4.ts"
fi

# HDR10 the way a streaming encode ships it: HEVC Main 10 tagged BT.2020 PQ,
# with the mastering display (a P3-D65 grading monitor, 1000 cd/m² peak) and
# content light level SEI on every keyframe, plus HDR10+ dynamic metadata
# (one scene, which x265 repeats on every frame). libx265 ships with
# Homebrew's ffmpeg.
if [ ! -f "$OUT/hdr10.mp4" ]; then
    cat > "$OUT/hdr10plus.json" <<'JSON'
{"JSONInfo": {"HDR10plusProfile": "B", "Version": "1.0"},
 "SceneInfo": [{
   "SceneFrameIndex": 0, "SceneId": 0, "SequenceFrameIndex": 0,
   "NumberOfWindows": 1, "TargetedSystemDisplayMaximumLuminance": 400,
   "LuminanceParameters": {
     "AverageRGB": 1000, "MaxScl": [5000, 6000, 7000],
     "LuminanceDistributions": {
       "DistributionIndex": [1, 5, 10, 25, 50, 75, 90, 95, 99],
       "DistributionValues": [0, 100, 200, 300, 400, 500, 600, 700, 800]}},
   "BezierCurveData": {"KneePointX": 0, "KneePointY": 0,
     "Anchors": [256, 512, 768, 1023, 1023, 1023, 1023, 1023, 1023]}}]}
JSON
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=duration=2:size=320x180:rate=25" \
        -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -tag:v hvc1 \
        -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
        -x265-params "log-level=error:keyint=25:hdr10=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400:dhdr10-info=$OUT/hdr10plus.json" \
        "$OUT/hdr10.mp4"
    rm -f "$OUT/hdr10plus.json"
    echo "generated: $OUT/hdr10.mp4"
fi

# Broadcast surround the way IPTV carries it: H.264 + AC-3 5.1 in MPEG-TS,
# long enough to change the output route mid-playback. The tone sits in the
# centre channel alone, so a fold-down that drops channels instead of mixing
# them goes silent.
gen surround51.ts \
    -f lavfi -i "testsrc2=duration=20:size=320x180:rate=25" \
    -f lavfi -i "sine=frequency=440:duration=20" \
    -filter_complex "[1:a]pan=5.1(side)|FC=c0[a]" -map 0:v -map "[a]" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 25 \
    -c:a ac3 -b:a 384k -shortest -f mpegts

# Closed captions the way US broadcast and much IPTV carry them: CEA-608
# byte pairs inside the video, as A/53 user data in an SEI message on every
# frame — not as a subtitle stream. No ffmpeg CLI option writes captions from
# a caption file into the video, so a short script puts the SEI in front of
# each picture of a B-frame-free encode, so the n-th picture in the file is
# the n-th on screen. Two pop-on captions, each loaded off screen first:
# "HELLO CAPTIONS" shown at 1 s and erased at 3 s, "SECOND CAPTION" at 4–6 s.
if [ ! -f "$OUT/captions.ts" ]; then
    if command -v python3 >/dev/null 2>&1; then
        "$FFMPEG" -hide_banner -loglevel error -y \
            -f lavfi -i "testsrc2=duration=8:size=320x180:rate=30" \
            -c:v libx264 -preset ultrafast -pix_fmt yuv420p -bf 0 -g 30 \
            -f h264 "$OUT/captions-source.h264"
        python3 -I - "$OUT/captions-source.h264" "$OUT/captions.h264" <<'PY'
import sys

source, destination = sys.argv[1], sys.argv[2]
stream = open(source, 'rb').read()

def nal_units(data):
    starts = []
    index = 0
    while True:
        found = data.find(b'\x00\x00\x01', index)
        if found < 0:
            break
        starts.append(found + 3)
        index = found + 3
    for position, start in enumerate(starts):
        end = starts[position + 1] - 3 if position + 1 < len(starts) else len(data)
        yield data[start:end].rstrip(b'\x00')

def odd_parity(value):
    value &= 0x7F
    return value | (0x80 if bin(value).count('1') % 2 == 0 else 0)

# frame -> CEA-608 byte pair for CC1 (field 1); every other frame carries nulls.
script = {}
def pop_on(load, text, show, clear):
    pairs = [(0x14, 0x20), (0x14, 0x70)]  # resume caption loading, row 15
    for i in range(0, len(text), 2):
        pairs.append((ord(text[i]), ord(text[i + 1]) if i + 1 < len(text) else 0))
    for offset, pair in enumerate(pairs):
        script[load + offset] = pair
    script[show] = (0x14, 0x2F)   # end of caption: swap it on screen
    script[clear] = (0x14, 0x2C)  # erase displayed memory

pop_on(5, 'HELLO CAPTIONS', 30, 90)
pop_on(100, 'SECOND CAPTION', 120, 180)

def sei(frame):
    first, second = script.get(frame, (0, 0))
    cc_data = bytes([0xFC, odd_parity(first), odd_parity(second), 0xFD, 0x80, 0x80])
    # ITU-T T.35: United States, ATSC, 'GA94', cc_data with two triples.
    payload = bytes([0xB5, 0x00, 0x31]) + b'GA94' + bytes([0x03, 0x40 | 2, 0xFF]) + cc_data + bytes([0xFF])
    rbsp = bytes([4, len(payload)]) + payload + bytes([0x80])
    nal = bytearray([0x06])
    zeros = 0
    for byte in rbsp:
        if zeros >= 2 and byte <= 3:
            nal.append(3)  # emulation prevention
            zeros = 0
        nal.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return bytes(nal)

out = bytearray()
frame = 0
for nal in nal_units(stream):
    # First slice of a picture: a slice NAL whose first_mb_in_slice is 0.
    if nal and nal[0] & 0x1F in (1, 5) and len(nal) > 1 and nal[1] & 0x80:
        out += b'\x00\x00\x00\x01' + sei(frame)
        frame += 1
    out += b'\x00\x00\x00\x01' + nal
open(destination, 'wb').write(out)
PY
        "$FFMPEG" -hide_banner -loglevel error -y \
            -framerate 30 -i "$OUT/captions.h264" -c:v copy -f mpegts \
            "$OUT/captions.ts"
        rm -f "$OUT/captions-source.h264" "$OUT/captions.h264"
        echo "generated: $OUT/captions.ts"
    else
        echo "skipped: $OUT/captions.ts (needs python3)" >&2
    fi
fi

echo "fixtures ready in $OUT"
