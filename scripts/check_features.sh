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
  Shared/Downloads/PWDownloadButton.x Native/Playlist/Playlist.x
  Redesigned/Playlist/PlaylistHeader.x Redesigned/Kit/SGRHeaderInfo.m
)
failed=0
for relative in "${SOURCES[@]}"; do
  input="$SOURCE/$relative"
  if [[ "$relative" == *.x ]]; then
    input="$STAGE/$(basename "$relative").m"
    if ! perl "$THEOS/bin/logos.pl" -c generator=internal "$SOURCE/$relative" > "$input"; then
      failed=1
      continue
    fi
  fi
  if ! xcrun --sdk iphoneos clang -target arm64-apple-ios16.0 -isysroot "$SDK" \
    -fobjc-arc -fblocks -fsyntax-only -Werror \
    -I "$SOURCE" -I "$(dirname "$SOURCE/$relative")" \
    -I "$THEOS/include" -I "$THEOS/vendor/include" \
    '-DSG_VERSION="feature-check"' "$input"; then
    failed=1
  fi
done
# Type-check the actual iOS sources and extractor before the lengthy fusion build.
SWIFT_SOURCES=()
while IFS= read -r file; do SWIFT_SOURCES+=("$file"); done < <(find "$SOURCE/Shared/Downloads" -name '*.swift' | sort)
if ! xcrun --sdk iphoneos swiftc -typecheck -swift-version 5 -target arm64-apple-ios16.0 \
  -sdk "$SDK" -module-name PWDownloadsCheck "${SWIFT_SOURCES[@]}"; then
  failed=1
fi
exit "$failed"
