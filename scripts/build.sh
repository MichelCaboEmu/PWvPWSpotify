#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
: "${THEOS:?Set THEOS to the Theos checkout}"
export THEOS
if [[ "$MODE" != "--compile-check" ]]; then
  [[ -f "$MODE" ]] || { echo 'Usage: scripts/build.sh clean.ipa | --compile-check' >&2; exit 1; }
  INPUT="$(cd "$(dirname "$MODE")" && pwd)/$(basename "$MODE")"
  python3 "$ROOT/scripts/validate_ipa.py" "$INPUT" --report "$ROOT/out/input-validation.json"
fi
python3 "$ROOT/scripts/prepare.py"
SG="$ROOT/build/spotipw"
EE="$ROOT/build/eevee"
mkdir -p "$ROOT/out"
# Match the upstream recipe, retaining the renamed SwiftProtobuf module.
export THEOS_PACKAGE_SCHEME=rootless SWIFTPROTOBUF_VERSION=1.29.0
export REPO_SLUG=MichelCaboEmu/PWvPWSpotify BRANCH_NAME=main
(cd "$EE" && bash Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh)
(cd "$EE" && env -u MAKELEVEL gmake package FINALPACKAGE=1)
DEB="$(find "$EE/packages" -name 'com.eevee.spotify_*.deb' -type f | sort | tail -1)"
[[ -n "$DEB" ]] || { echo 'Eevee package missing' >&2; exit 1; }
# Rootless install paths cannot resolve on a non-jailbroken phone. Rewrite
# dependencies before cyan sees them (cyan does not inspect /var/jb paths).
STAGE="$ROOT/build/eevee-package"
mkdir -p "$STAGE"
dpkg-deb -R "$DEB" "$STAGE"
python3 "$ROOT/scripts/normalize_dependencies.py" "$STAGE"
DEB="$ROOT/build/eevee-fusion.deb"
dpkg-deb -b "$STAGE" "$DEB"
unset THEOS_PACKAGE_SCHEME
if [[ "$MODE" == "--compile-check" ]]; then
  # Compile-only fixture, NEVER used in an IPA. Real IPA builds regenerate the
  # complete flag table from their validated executable in pipeline.sh.
  cat > "$SG/tweak/Sources/Shared/Flags/SGFlagList.m" <<'EOF'
#import "Flags.h"
const SGFlagDef SGFlagTable[] = {{NULL, SGFlagUnknown, 0, 0, 0}};
const NSUInteger SGFlagCount = 0;
EOF
  env -u MAKELEVEL gmake -C "$SG/tweak" package
  echo 'Both fusion modules compiled. No IPA was produced in compile-check mode.'
  exit 0
fi
export PW_EEVEE_DEB="$DEB"
OUT="$ROOT/out/PWvPWSpotify-9.1.78.ipa"
bash "$SG/scripts/pipeline.sh" "$INPUT" --no-flex --name PWvPWSpotify -o "$OUT"
bash "$EE/Tools/alt-icons.sh" "$OUT"
# Keep both the Live Activity and native widget. Add the same Safari extension
# that Eevee documents, pinned to an inspected upstream revision.
python3 "$ROOT/scripts/add_safari_extension.py" "$OUT" "$ROOT/safari/OpenSpotifySafariExtension.appex"
python3 "$ROOT/scripts/validate_ipa.py" "$OUT" --output --report "$ROOT/out/output-validation.json"
cp "$ROOT/upstreams.json" "$ROOT/out/upstreams.json"
# GPL corresponding source for the exact patched modules; no Spotify executable
# or generated flag table is included in this archive.
python3 "$ROOT/scripts/package_sources.py"
