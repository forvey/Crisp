#!/bin/bash
# Build one installer for the app and its virtual microphone. Never installs it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: package-local-install.sh /path/to/signed/Crisp.app [output-directory]}"
DEST="${2:-$ROOT/build/LocalInstaller}"
DRIVER="$ROOT/build/audio-component/root/Library/Audio/Plug-Ins/HAL/CrispRemoteMicrophone.driver"
IDENT=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
[ "$IDENT" = com.crisp.app ] || { echo "Expected the Crisp application." >&2; exit 1; }
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$DRIVER"
mkdir -p "$DEST"
WORK=$(mktemp -d "$ROOT/build/crisp-installer.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/Applications" "$WORK/root/Library/Audio/Plug-Ins/HAL" "$WORK/scripts"
ditto "$APP" "$WORK/root/Applications/Crisp.app"
ditto "$DRIVER" "$WORK/root/Library/Audio/Plug-Ins/HAL/CrispRemoteMicrophone.driver"
cp "$ROOT/build/audio-component/install-scripts/postinstall" "$WORK/scripts/postinstall"
chmod 755 "$WORK/scripts/postinstall"
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist"
# Do not let Installer relocate the update into one of the user's backup apps.
python3 - "$WORK/components.plist" <<'PY'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
components = plistlib.loads(path.read_bytes())
for component in components:
    component['BundleIsRelocatable'] = False
path.write_bytes(plistlib.dumps(components))
PY
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
COPYFILE_DISABLE=1 pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
    --ownership recommended --scripts "$WORK/scripts" --identifier com.forvey.Crisp.install \
    --version "$VERSION" "$DEST/Crisp.pkg"
if [ -n "${CRISP_AUDIO_INSTALLER_SIGN_ID:-}" ]; then
    productsign --sign "$CRISP_AUDIO_INSTALLER_SIGN_ID" "$DEST/Crisp.pkg" "$DEST/Crisp.signed.pkg"
    mv "$DEST/Crisp.signed.pkg" "$DEST/Crisp.pkg"
fi
cp "$APP/Contents/Resources/RemoteAudio/UninstallCrisp.pkg" "$DEST/UninstallCrisp.pkg"
echo "Built $DEST/Crisp.pkg (app + microphone) and UninstallCrisp.pkg (neither executed)."
