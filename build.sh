#!/usr/bin/env bash
# Builds "Mac Cleaner.app" with just the Command Line Tools (no Xcode project needed).
#   ./build.sh            build into this folder
#   ./build.sh --install  also copy it into /Applications, ready to keep in the Dock
#   ./build.sh --setup-signing  one-time: create a local code-signing certificate in your login
#                               keychain, so macOS keeps permissions (Full Disk Access) across rebuilds
set -euo pipefail
cd "$(dirname "$0")"
APP="Mac Cleaner.app"
IDENTITY="Mac Cleaner Local Signing"

if [[ "${1:-}" == "--setup-signing" ]]; then
  if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "\"$IDENTITY\" already exists in your keychain"
    exit 0
  fi
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT   # the private key only ever lives in the keychain
  cat > "$tmp/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[dn]
CN = $IDENTITY
[codesign]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem"
  pass=$(openssl rand -hex 16)   # throwaway password protecting the file only during import
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY" \
    -out "$tmp/identity.p12" -passout "pass:$pass"
  security import "$tmp/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign
  echo "Created \"$IDENTITY\". Rebuild with ./build.sh --install, then grant Full Disk Access one last time."
  exit 0
fi

mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/MacCleaner"

# Icon: render a 1024px master, scale it into an .iconset, pack as .icns.
swiftc -O Tools/make_icon.swift -o build/make_icon
build/make_icon build/icon_1024.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp Info.plist "$APP/Contents/Info.plist"
# A stable certificate keeps macOS privacy permissions across rebuilds; ad-hoc signatures change every build.
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
  echo "Note: ad-hoc signed. Run ./build.sh --setup-signing once so permissions survive rebuilds."
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x MacCleaner 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/$APP"
fi
