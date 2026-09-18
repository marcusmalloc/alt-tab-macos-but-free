#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Use Apple's SDK-matched Swift. No full Xcode installation is required.
#   CONFIGURATION=debug|release   build configuration (default: debug)
#   UNIVERSAL=1                   build a fat arm64 + x86_64 binary
#   APP_VERSION=x.y.z             override CFBundleShortVersionString in the built app
configuration="${CONFIGURATION:-debug}"
app="$PWD/.build/BareTab.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    # Build each slice separately and merge with lipo; `swift build --arch a --arch b`
    # needs a full Xcode install, this works with just the Command Line Tools.
    slices=()
    for triple in arm64-apple-macosx x86_64-apple-macosx; do
        xcrun swift build -c "$configuration" --triple "$triple"
        slices+=("$(xcrun swift build -c "$configuration" --triple "$triple" --show-bin-path)/BareTab")
    done
    lipo -create "${slices[@]}" -output "$app/Contents/MacOS/BareTab"
else
    xcrun swift build -c "$configuration"
    binary_dir="$(xcrun swift build -c "$configuration" --show-bin-path)"
    cp "$binary_dir/BareTab" "$app/Contents/MacOS/BareTab"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$app/Contents/Info.plist"
fi
# Sign with a stable identity so macOS keeps the Accessibility grant across rebuilds.
# Defaults to the self-signed "BareTab Dev" certificate when present, else ad-hoc.
if [[ -z "${CODE_SIGN_IDENTITY:-}" ]] && security find-identity -v -p codesigning | grep -q '"BareTab Dev"'; then
    CODE_SIGN_IDENTITY="BareTab Dev"
fi
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" "$app"
printf 'Built %s\n' "$app"
