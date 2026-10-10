#!/usr/bin/env bash
# 构建标准 flat APT 源（iOS 越狱源）
# 用法: scripts/build_repo.sh [repo_root]   (默认当前目录)
#
# 目录约定:
#   debs/<arch>/*.deb     待收录的 deb（arch 目录名随意，脚本按 deb 内 control 的 Architecture 识别）
#   Packages / Packages.gz / Packages.bz2 / Packages.xz   （自动生成）
#   Release                                               （自动生成）
#   CydiaIcon.png          源图标（可选）
#   depictions/            Sileo depiction（可选）
set -euo pipefail

REPO="$(cd "${1:-.}" && pwd)"
cd "$REPO"

ORIGIN="${ORIGIN:-tomie iOS Repo}"
LABEL="${LABEL:-$ORIGIN}"
DESC="${DESC:-tomie personal iOS tweaks}"
SUITE="${SUITE:-stable}"
CODENAME="${CODENAME:-ios}"
REPO_VERSION="${REPO_VERSION:-1.0}"
ARCHS="${ARCHS:-iphoneos-arm iphoneos-arm64 iphoneos-arm64e}"

command -v dpkg-deb >/dev/null || { echo "need dpkg-deb"; exit 1; }

echo "[*] repo root: $REPO"

# ---- 生成 Packages ----
: > Packages
count=0
while IFS= read -r deb; do
  [ -n "$deb" ] || continue
  rel="./${deb#./}"
  arch=$(dpkg-deb -f "$deb" Architecture 2>/dev/null || echo "")
  if [ -z "$arch" ]; then echo "[!] skip (no control): $deb"; continue; fi
  size=$(stat -c%s "$deb")
  {
    dpkg-deb -f "$deb"
    echo "Filename: $rel"
    echo "Size: $size"
    echo "MD5sum: $(md5sum "$deb" | cut -d' ' -f1)"
    echo "SHA1: $(sha1sum "$deb" | cut -d' ' -f1)"
    echo "SHA256: $(sha256sum "$deb" | cut -d' ' -f1)"
    echo "SHA512: $(sha512sum "$deb" | cut -d' ' -f1)"
    echo ""
  } >> Packages
  count=$((count+1))
  echo "  + $rel"
done < <(find debs -type f -name '*.deb' 2>/dev/null | sort)

echo "[*] packages: $count"

# ---- 压缩 ----
command -v gzip  >/dev/null && gzip  -9 -k -f Packages
command -v bzip2 >/dev/null && bzip2 -9 -k -f Packages
command -v xz    >/dev/null && xz    -9 -k -f Packages

# ---- 生成 Release ----
gen_hash_block() {
  local algo="$1" cmd="$2"
  echo "$algo:"
  for f in Packages Packages.gz Packages.bz2 Packages.xz; do
    [ -f "$f" ] || continue
    printf " %s %16s %s\n" "$($cmd "$f" | cut -d' ' -f1)" "$(stat -c%s "$f")" "$f"
  done
}

{
  echo "Origin: $ORIGIN"
  echo "Label: $LABEL"
  echo "Description: $DESC"
  echo "Suite: $SUITE"
  echo "Version: $REPO_VERSION"
  echo "Codename: $CODENAME"
  echo "Architectures: $ARCHS"
  echo "Components: main"
  gen_hash_block MD5Sum md5sum
  gen_hash_block SHA256 sha256sum
} > Release

echo "[*] wrote Packages / Packages.gz / Packages.bz2 / Release"
ls -l Packages* Release 2>/dev/null | awk '{print "    "$5"\t"$9}'