#!/usr/bin/env bash
# Check the changed Objective-C/Logos sources before the lengthy Swift build.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${THEOS:?Set THEOS to the pinned Theos checkout}"
python3 "$ROOT/scripts/prepare.py"
SOURCE="$ROOT/build/spotipw/tweak/Sources"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
STAGE="$(mktemp -d)"
SOURCES=(
  Core/PWAppleParsing.m Core/PWProviderSupport.m Core/PWDiagnostics.m
  Shared/Player/PWAppleArtwork.m Shared/Player/PWArtworkEngine.x
  Shared/Player/PWLockScreenArtwork.m Shared/Genius/PWGenius.m
  Shared/LockScreenLyrics/LockScreenLyrics.x App/PWFeatureSettings.m
  Redesigned/Lyrics/SGRKaraokeView.m Native/Lyrics/LyricsPage.x
)
for relative in "${SOURCES[@]}"; do
  input="$SOURCE/$relative"
  if [[ "$relative" == *.x ]]; then
    input="$STAGE/$(basename "$relative").m"
    perl "$THEOS/bin/logos.pl" -c generator=internal "$SOURCE/$relative" > "$input"
  fi
  xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" \
    -fobjc-arc -fblocks -fsyntax-only -Werror \
    -I "$SOURCE" -I "$(dirname "$SOURCE/$relative")" \
    -I "$THEOS/include" -I "$THEOS/vendor/include" \
    '-DSG_VERSION="feature-check"' "$input"
done
