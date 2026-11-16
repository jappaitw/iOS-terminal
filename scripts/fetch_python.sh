#!/bin/sh
# 下載官方 CPython iOS XCframework 到 ThirdParty/（不進 git）。
# 用法：sh scripts/fetch_python.sh
set -e
VER=3.15.2
SIZE=86187886
URL="https://www.python.org/ftp/python/$VER/python-$VER-iOS-XCframework.tar.gz"
cd "$(dirname "$0")/.."
mkdir -p ThirdParty/download
TGZ="ThirdParty/download/python-$VER-iOS-XCframework.tar.gz"
if [ ! -f "$TGZ" ]; then curl -fL --retry 3 -o "$TGZ" "$URL"; fi
ACTUAL=$(stat -f %z "$TGZ")
[ "$ACTUAL" = "$SIZE" ] || { echo "大小不符：$ACTUAL ≠ $SIZE"; exit 1; }
rm -rf ThirdParty/Python.xcframework ThirdParty/python-extract
mkdir -p ThirdParty/python-extract
tar -xzf "$TGZ" -C ThirdParty/python-extract
FW=$(find ThirdParty/python-extract -maxdepth 2 -name Python.xcframework -type d | head -1)
mv "$FW" ThirdParty/Python.xcframework
rm -rf ThirdParty/python-extract
echo "OK: ThirdParty/Python.xcframework ($VER)"
