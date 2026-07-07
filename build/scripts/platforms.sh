#!/bin/bash
# Platform definitions for LumeEngine binary builds.
# Each platform maps to: SDK name, clang -target triple, FFmpeg arch.
#
# Usage: source platforms.sh; platform_env <platform-id>

MACOS_MIN="15.0"
IOS_MIN="18.0"
TVOS_MIN="18.0"
XROS_MIN="2.0"

ALL_PLATFORMS=(macos-arm64 macos-x86_64 ios-arm64 ios-sim-arm64 ios-sim-x86_64 tvos-arm64 tvos-sim-arm64 tvos-sim-x86_64 xros-arm64 xros-sim-arm64)

platform_env() {
    local platform="$1"
    case "$platform" in
        macos-arm64)    SDK=macosx;           TARGET="arm64-apple-macosx${MACOS_MIN}";        FF_ARCH=arm64  ;;
        macos-x86_64)   SDK=macosx;           TARGET="x86_64-apple-macosx${MACOS_MIN}";       FF_ARCH=x86_64 ;;
        ios-arm64)      SDK=iphoneos;         TARGET="arm64-apple-ios${IOS_MIN}";             FF_ARCH=arm64  ;;
        ios-sim-arm64)  SDK=iphonesimulator;  TARGET="arm64-apple-ios${IOS_MIN}-simulator";   FF_ARCH=arm64  ;;
        ios-sim-x86_64) SDK=iphonesimulator;  TARGET="x86_64-apple-ios${IOS_MIN}-simulator";  FF_ARCH=x86_64 ;;
        tvos-arm64)     SDK=appletvos;        TARGET="arm64-apple-tvos${TVOS_MIN}";           FF_ARCH=arm64  ;;
        tvos-sim-arm64) SDK=appletvsimulator; TARGET="arm64-apple-tvos${TVOS_MIN}-simulator"; FF_ARCH=arm64  ;;
        tvos-sim-x86_64) SDK=appletvsimulator; TARGET="x86_64-apple-tvos${TVOS_MIN}-simulator"; FF_ARCH=x86_64 ;;
        xros-arm64)     SDK=xros;             TARGET="arm64-apple-xros${XROS_MIN}";           FF_ARCH=arm64  ;;
        xros-sim-arm64) SDK=xrsimulator;      TARGET="arm64-apple-xros${XROS_MIN}-simulator"; FF_ARCH=arm64  ;;
        *) echo "unknown platform: $platform" >&2; return 1 ;;
    esac
    SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
    export SDK TARGET FF_ARCH SYSROOT
}
