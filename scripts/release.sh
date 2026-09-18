#!/bin/bash
# Builds a universal, ad-hoc signed BareTab.app and zips it for a GitHub Release.
# Usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: scripts/release.sh <version>}"

CONFIGURATION=release UNIVERSAL=1 APP_VERSION="$version" CODE_SIGN_IDENTITY=- ./scripts/build.sh

rm -rf dist && mkdir -p dist
zip="dist/BareTab-$version.zip"
# ditto preserves the bundle structure and signature; plain `zip` does not.
ditto -c -k --keepParent .build/BareTab.app "$zip"
(cd dist && shasum -a 256 "BareTab-$version.zip" > "BareTab-$version.zip.sha256")
lipo -info .build/BareTab.app/Contents/MacOS/BareTab
cat "$zip.sha256"
