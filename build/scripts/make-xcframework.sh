#!/bin/bash
# Assemble FFmpeg.xcframework from all built platform slices in build/output/.
#
# Each slice: merge lib*.a -> libffmpeg.a (libtool), stage headers + module map,
# then xcodebuild -create-xcframework into BinaryDependencies/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$BUILD_DIR")"
OUT_DIR="$REPO_DIR/BinaryDependencies"
STAGE="$BUILD_DIR/xcframework-stage"

rm -rf "$STAGE" && mkdir -p "$STAGE"

stage_slice() { # stage_slice <name> <libdir> <includedir>
    local slice="$STAGE/$1"
    # FFmpeg headers are nested under lume_ffmpeg/ and their includes rewritten,
    # so they can NEVER collide with another package shipping libav* headers at
    # the conventional paths (e.g. another engine embedding a different FFmpeg).
    mkdir -p "$slice/Headers/lume_ffmpeg"
    libtool -static -o "$slice/libffmpeg.a" "$2"/lib*.a 2> >(grep -v 'has no symbols' >&2 || true)
    cp -R "$3/" "$slice/Headers/lume_ffmpeg/"
    python3 - "$slice/Headers/lume_ffmpeg" <<'PYEOF'
import os, re, sys
root = sys.argv[1]
pattern = re.compile(r'#\s*include\s*(["<])(libav(?:util|codec|format|filter|device)|libsw(?:scale|resample))/')
for dirpath, _, files in os.walk(root):
    for name in files:
        if not name.endswith('.h'):
            continue
        path = os.path.join(dirpath, name)
        with open(path) as fh:
            text = fh.read()
        rewritten = pattern.sub(lambda m: f'#include {m.group(1)}lume_ffmpeg/{m.group(2)}/', text)
        if rewritten != text:
            with open(path, 'w') as fh:
                fh.write(rewritten)
PYEOF
    cp "$BUILD_DIR/support/CFFmpeg.h" "$slice/Headers/"
    cp "$BUILD_DIR/support/CFFmpegShim.h" "$slice/Headers/"
    cp "$BUILD_DIR/support/module.modulemap" "$slice/Headers/"
}

# xcodebuild rejects two libraries for the same platform+variant, so arm64 and
# x86_64 builds of the same destination are lipo'd into one fat slice.
merge_pair() { # merge_pair <combined> <a> <b>
    local combined="$STAGE/$1"
    if [ -d "$STAGE/$2" ] && [ -d "$STAGE/$3" ]; then
        mkdir -p "$combined"
        lipo -create "$STAGE/$2/libffmpeg.a" "$STAGE/$3/libffmpeg.a" -output "$combined/libffmpeg.a"
        cp -R "$STAGE/$2/Headers" "$combined/Headers"
        rm -rf "${STAGE:?}/$2" "${STAGE:?}/$3"
        echo "==> merged $2 + $3 -> $1"
    elif [ -d "$STAGE/$2" ]; then
        mv "$STAGE/$2" "$combined"
    elif [ -d "$STAGE/$3" ]; then
        mv "$STAGE/$3" "$combined"
    fi
}

for platform_dir in "$BUILD_DIR"/output/*/; do
    platform="$(basename "$platform_dir")"
    libdir="$platform_dir/lib"
    [ -d "$libdir" ] || continue
    stage_slice "$platform" "$libdir" "$platform_dir/include"
    echo "==> staged slice: $platform"
done

merge_pair macos-universal macos-arm64 macos-x86_64
merge_pair ios-sim-universal ios-sim-arm64 ios-sim-x86_64
merge_pair tvos-sim-universal tvos-sim-arm64 tvos-sim-x86_64

ARGS=()
for slice_dir in "$STAGE"/*/; do
    slice="$(basename "$slice_dir")"
    ARGS+=(-library "$slice_dir/libffmpeg.a" -headers "$slice_dir/Headers")
done

[ ${#ARGS[@]} -gt 0 ] || { echo "no built slices found in $BUILD_DIR/output"; exit 1; }

rm -rf "$OUT_DIR/FFmpeg.xcframework"
mkdir -p "$OUT_DIR"
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT_DIR/FFmpeg.xcframework"
echo "==> $OUT_DIR/FFmpeg.xcframework"
