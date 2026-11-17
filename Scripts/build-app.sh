#!/bin/bash
# Builds Porthole.app into ./build.
#
#   Scripts/build-app.sh               # release build for this Mac
#   Scripts/build-app.sh debug         # debug build
#   UNIVERSAL=1 Scripts/build-app.sh   # one app for both Apple silicon and Intel
#
# The version is 0.1.<number of commits>, so every commit gets its own; set VERSION or
# BUILD_NUMBER to override. Signs with your "Apple Development" certificate when one is
# installed, so macOS keeps the local-network permission across rebuilds. Set CODESIGN_IDENTITY
# to override, or "-" for ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCHS=""
if [[ "${UNIVERSAL:-0}" == 1 ]]; then ARCHS="--arch arm64 --arch x86_64"; fi
# shellcheck disable=SC2086  # ARCHS is meant to split into separate flags
swift build -c "$CONFIG" --product Porthole $ARCHS
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path $ARCHS)"

BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
VERSION="${VERSION:-0.1.$BUILD_NUMBER}"

APP="build/Porthole.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Porthole" "$APP/Contents/MacOS/Porthole"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # made by Scripts/make-icon.swift
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$APP/Contents/Info.plist"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP $VERSION (signed with: ${IDENTITY:-ad hoc})"
