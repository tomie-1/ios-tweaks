#!/usr/bin/env bash
# 通用 iOS tweak 构建脚本（需 macOS + Xcode 命令行工具）
# 用法: bash scripts/build_tweak.sh <tweak目录> <输出目录>
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <tweak_dir> <out_dir>" >&2
  exit 2
fi

TWEAK_DIR="$(cd "$1" && pwd)"
mkdir -p "$2"
OUT="$(cd "$2" && pwd)"

# shellcheck disable=SC1090
source "$TWEAK_DIR/tweak.env"

: "${TWEAK_NAME:?tweak.env 缺少 TWEAK_NAME}"
: "${PKG_ID:?tweak.env 缺少 PKG_ID}"
: "${PKG_NAME:?tweak.env 缺少 PKG_NAME}"
: "${SRC:?tweak.env 缺少 SRC}"

DESC="${DESC:-$PKG_NAME}"
MAINTAINER="${MAINTAINER:-unknown}"
AUTHOR="${AUTHOR:-$MAINTAINER}"
MIN_IOS="${MIN_IOS:-15.0}"
KILL_APP="${KILL_APP:-}"
VERSION="${VERSION:-1.0.0}"
FILTER="${FILTER:-}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
INSTALL_PATH="/Library/MobileSubstrate/DynamicLibraries/$TWEAK_NAME.dylib"

COMMON=(-isysroot "$SDK" -dynamiclib -fobjc-arc -fmodules -Os
        -Wno-deprecated-declarations -Wno-unused-function
        -framework Foundation -framework UIKit -framework WebKit)

echo "[*] $TWEAK_NAME  sdk=$SDK  ios>=$MIN_IOS"

xcrun --sdk iphoneos clang -target "arm64-apple-ios$MIN_IOS" "${COMMON[@]}" \
    -install_name "$INSTALL_PATH" -o "$OUT/$TWEAK_NAME.dylib" "$TWEAK_DIR/$SRC"

strip -x "$OUT/$TWEAK_NAME.dylib" 2>/dev/null || true
if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT/$TWEAK_NAME.dylib"          # ad-hoc；codesign 会多约 19KB
else
  codesign -s - --force --timestamp=none "$OUT/$TWEAK_NAME.dylib"
fi

makedeb() {
  local arch="$1" dest="$2"
  local d="$WORK/deb_$arch"
  rm -rf "$d"
  mkdir -p "$d/DEBIAN" "$d$dest"
  cp "$OUT/$TWEAK_NAME.dylib" "$d$dest/$TWEAK_NAME.dylib"
  if [ -n "$FILTER" ] && [ -f "$TWEAK_DIR/$FILTER" ]; then
    cp "$TWEAK_DIR/$FILTER" "$d$dest/$TWEAK_NAME.plist"
  fi
  cat > "$d/DEBIAN/control" <<EOF
Package: $PKG_ID
Name: $PKG_NAME
Version: $VERSION
Architecture: $arch
Description: $DESC
Maintainer: $MAINTAINER
Author: $AUTHOR
Section: Tweaks
Depends: mobilesubstrate
EOF
  if [ -n "$KILL_APP" ]; then
    printf '#!/bin/bash\nkillall -9 %s 2>/dev/null || true\nexit 0\n' "$KILL_APP" > "$d/DEBIAN/postinst"
    chmod 755 "$d/DEBIAN/postinst"
  fi
  dpkg-deb -b "$d" "$OUT/${PKG_ID}_${arch}.deb" >/dev/null
  echo "[*] ${PKG_ID}_${arch}.deb"
}

makedeb iphoneos-arm    "/Library/MobileSubstrate/DynamicLibraries"
makedeb iphoneos-arm64  "/var/jb/Library/MobileSubstrate/DynamicLibraries"
makedeb iphoneos-arm64e "/Library/MobileSubstrate/DynamicLibraries"

echo "[*] done -> $OUT"
ls -l "$OUT"
