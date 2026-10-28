#!/bin/bash
# Build-only: never installs a HAL plugin, restarts CoreAudio, or requests audio access.
set -euo pipefail
export COPYFILE_DISABLE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/build/RemoteAudio}"
WORK="$ROOT/build/audio-component"
DRIVER="$WORK/root/Library/Audio/Plug-Ins/HAL/CrispRemoteMicrophone.driver"
mkdir -p "$DRIVER/Contents/MacOS" "$DEST" "$WORK/install-scripts" "$WORK/uninstall-scripts" "$WORK/empty"
for ARCH in arm64 x86_64; do
    xcrun clang -arch "$ARCH" -std=c11 -fblocks -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
        -mmacosx-version-min=14.0 -bundle -framework CoreAudio -framework CoreFoundation \
        "$ROOT/AudioDriver/CrispRemoteMicrophone.c" -o "$WORK/driver-$ARCH"
done
xcrun lipo -create "$WORK/driver-arm64" "$WORK/driver-x86_64" -output "$DRIVER/Contents/MacOS/CrispRemoteMicrophone"
cp "$ROOT/AudioDriver/Info.plist" "$DRIVER/Contents/Info.plist"
SIGN_ID="${CRISP_AUDIO_SIGN_ID:-${CRISP_SIGN_ID:--}}"
if [ "$SIGN_ID" = - ]; then
    codesign --force --sign - "$DRIVER"
else
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$DRIVER"
fi
codesign --verify --strict "$DRIVER"
xattr -cr "$DRIVER"
cat > "$WORK/install-scripts/postinstall" <<'EOF'
#!/bin/bash
set -euo pipefail
DRIVER=/Library/Audio/Plug-Ins/HAL/CrispRemoteMicrophone.driver
/usr/sbin/chown -R root:wheel "$DRIVER"
/bin/chmod -R go-w "$DRIVER"
# No default input/output changes. This audio-only restart is disclosed in Crisp.
/usr/bin/killall -TERM coreaudiod 2>/dev/null || true
exit 0
EOF
cat > "$WORK/uninstall-scripts/postinstall" <<'EOF'
#!/bin/bash
# Used by UninstallCrisp.pkg. No user preferences, recordings or documents are deleted.
set -euo pipefail
APP=/Applications/Crisp.app
DRIVER=/Library/Audio/Plug-Ins/HAL/CrispRemoteMicrophone.driver
# Validate every target before modifying either of them.
if [ -d "$APP" ]; then
    IDENT=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
    [ "$IDENT" = com.crisp.app ] || exit 1
fi
if [ -d "$DRIVER" ]; then
    IDENT=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DRIVER/Contents/Info.plist")
    [ "$IDENT" = com.forvey.Crisp.RemoteMicrophone.driver ] || exit 1
fi
if [ "${1:-}" = --dry-run ]; then
    echo "Would uninstall $APP and $DRIVER; user preferences are preserved."
    exit 0
fi
[ "$EUID" -eq 0 ] || { echo "Use the macOS uninstaller to approve removal." >&2; exit 1; }
# Only the application at this exact path is stopped, including on a shared Mac.
PATTERN='^/Applications/Crisp[.]app/Contents/MacOS/Crisp($| )'
/usr/bin/pkill -TERM -f "$PATTERN" 2>/dev/null || true
for ATTEMPT in {1..10}; do
    /usr/bin/pgrep -f "$PATTERN" >/dev/null || break
    /bin/sleep 1
done
/usr/bin/pkill -KILL -f "$PATTERN" 2>/dev/null || true
if [ -L /usr/local/bin/crispctl ] && [ "$(/usr/bin/readlink /usr/local/bin/crispctl)" = "$APP/Contents/MacOS/crispctl" ]; then
    /bin/rm /usr/local/bin/crispctl
fi
/bin/rm -rf "$APP" "$DRIVER"
/usr/sbin/pkgutil --forget com.forvey.Crisp.install >/dev/null 2>&1 || true
/usr/sbin/pkgutil --forget com.forvey.Crisp.RemoteMicrophone.install >/dev/null 2>&1 || true
/usr/bin/killall -TERM coreaudiod 2>/dev/null || true
exit 0
EOF
chmod 755 "$WORK/install-scripts/postinstall" "$WORK/uninstall-scripts/postinstall"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DRIVER/Contents/Info.plist")
pkgbuild --root "$WORK/root" --ownership recommended --scripts "$WORK/install-scripts" \
    --identifier com.forvey.Crisp.RemoteMicrophone.install --version "$VERSION" \
    "$DEST/InstallCrispRemoteMicrophone.pkg" >/dev/null
pkgbuild --root "$WORK/empty" --scripts "$WORK/uninstall-scripts" \
    --identifier com.forvey.Crisp.uninstall --version 1.0.0 \
    "$DEST/UninstallCrisp.pkg" >/dev/null
# Retire the earlier component-only build artifact, never a system component.
rm -f "$DEST/UninstallCrispRemoteMicrophone.pkg"
if [ -n "${CRISP_AUDIO_INSTALLER_SIGN_ID:-}" ]; then
    for PACKAGE in InstallCrispRemoteMicrophone UninstallCrisp; do
        productsign --sign "$CRISP_AUDIO_INSTALLER_SIGN_ID" "$DEST/$PACKAGE.pkg" "$DEST/$PACKAGE.signed.pkg" >/dev/null
        mv "$DEST/$PACKAGE.signed.pkg" "$DEST/$PACKAGE.pkg"
    done
fi
echo "Audio component built at $DEST (not installed)"
