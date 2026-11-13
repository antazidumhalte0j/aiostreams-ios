#!/usr/bin/env bash
# Builds unsigned IPAs on macOS, for signing at install time:
#   build/AIOStreams.ipa        iPhone and iPad (AltStore, SideStore, Sideloadly, or your own certificate)
#   build/AIOStreams-tvOS.ipa   Apple TV (Xcode, or a signing tool that supports tvOS)
#
#   scripts/make-ipa.sh            # both
#   scripts/make-ipa.sh ios        # one of them
#   scripts/make-ipa.sh tvos
#   HEIGHT_CHANNELS=on scripts/make-ipa.sh   # with TrueHD Atmos and DTS:X height channels
#
# The version comes from the release tags: v0.2.7 on the commit built makes 0.2.7, and a commit
# after it builds as 0.2.7 too, told apart by its build number, which is the commit count (it only
# rises along main, and a rerun or a local build of the same commit gets the same one). APP_VERSION
# and BUILD_NUMBER override them; RELEASE_TAG, set by the workflow for a tag build, names the
# version where two tags share a commit. A shallow clone has no count, so it needs BUILD_NUMBER.
#
# Height channels are off unless asked for: AetherEngine notes they may be subject to third-party
# patent licensing, so public releases leave them out. Dolby Vision FEL (curve fold) is in both.
#
# Needs Xcode 27 (AetherEngine's supported toolchain; 26.3 is best effort) and XcodeGen.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
which="${1:-all}"

# The release this commit is, else the last one it follows.
if [ -z "${APP_VERSION:-}" ] && [ -n "${RELEASE_TAG:-}" ]; then
  APP_VERSION="${RELEASE_TAG#v}"
fi
if [ -z "${APP_VERSION:-}" ]; then
  tag=$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null \
    || git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
  APP_VERSION="${tag#v}"
fi
if [ -z "${BUILD_NUMBER:-}" ]; then
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "a shallow clone can't count its commits: fetch the full history or set BUILD_NUMBER" >&2
    exit 1
  fi
  BUILD_NUMBER=$(git rev-list --count HEAD)
fi
# What CFBundleShortVersionString and CFBundleVersion take: up to three numbers with dots.
for value in "$APP_VERSION" "$BUILD_NUMBER"; do
  [[ "$value" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "not a bundle version: '$value' (no v* tag found? set APP_VERSION)" >&2; exit 1; }
done
echo "version $APP_VERSION ($BUILD_NUMBER)"
mkdir -p build
echo "$APP_VERSION" > build/version.txt

# The engine package to build with: the same module, with or without height channels.
if [ "${HEIGHT_CHANNELS:-off}" = on ]; then
  engine=AetherEngineHeights
  echo "building with height channels"
else
  engine=AetherEngineFeatures
fi
sed "s#path: Packages/AetherEngineFeatures#path: Packages/$engine#" project.yml > project.gen.yml
xcodegen generate --spec project.gen.yml
rm -f project.gen.yml
derived="$here/build/DerivedData"

build() {
  local scheme="$1" platform="$2" products="$3" ipa="$4"
  xcodebuild build \
    -project AIOStreams.xcodeproj \
    -scheme "$scheme" \
    -configuration Release \
    -destination "generic/platform=$platform" \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    MARKETING_VERSION="$APP_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

  local app="$derived/Build/Products/$products/$scheme.app"
  [ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }
  # The packaged app must say the version it's released as.
  local plist="$app/Info.plist" short number
  short=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
  number=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
  if [ "$short" != "$APP_VERSION" ] || [ "$number" != "$BUILD_NUMBER" ]; then
    echo "$scheme.app says $short ($number), expected $APP_VERSION ($BUILD_NUMBER)" >&2
    exit 1
  fi
  local staging="$here/build/ipa-$scheme"
  rm -rf "$staging" "$here/build/$ipa"
  mkdir -p "$staging/Payload"
  cp -R "$app" "$staging/Payload/"
  (cd "$staging" && zip -qry "$here/build/$ipa" Payload)
  echo "built $here/build/$ipa"
}

if [ "$which" = all ] || [ "$which" = ios ]; then
  [ -f AIOStreams/Resources/web/index.html ] || scripts/build-web.sh
  build AIOStreams iOS Release-iphoneos AIOStreams.ipa
fi
if [ "$which" = all ] || [ "$which" = tvos ]; then
  build AIOStreamsTV tvOS Release-appletvos AIOStreams-tvOS.ipa
fi
