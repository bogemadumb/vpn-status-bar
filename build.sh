#!/bin/bash
# Сборка VPNMonitor. По умолчанию кладёт .app в ./build, с флагом --install копирует в ~/Applications.
set -e
cd "$(dirname "$0")"
OUT="build"
SDK="${SDK_PATH:-}"
if [ -z "$SDK" ]; then
  for s in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    [ -d "$s" ] && { SDK="$s"; break; }
  done
fi
[ -n "$SDK" ] || SDK=$(xcrun --show-sdk-path)
APP="$OUT/VPNMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc app/Sources/*.swift -o "$APP/Contents/MacOS/VPNMonitor" -sdk "$SDK" -parse-as-library -swift-version 5 \
  -target arm64-apple-macos13 -O \
  -framework SwiftUI -framework AppKit -framework Security -framework Network -framework UserNotifications -lsqlite3
cp app/Info.plist "$APP/Contents/Info.plist"
SIGN_ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"VPNMonitor Local Signing"/{print $2; exit}')
if [ -n "$SIGN_ID" ]; then
  codesign --force --deep -s "$SIGN_ID" "$APP"
else
  echo "Сертификат VPNMonitor Local Signing не найден, подпись ad-hoc (Keychain будет спрашивать после каждой сборки)"
  codesign --force --deep -s - "$APP"
fi
echo "Собрано: $APP"
if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/VPNMonitor.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Установлено в ~/Applications"
fi
