#!/bin/sh
# Builds libgit2 as static libraries for iOS device + simulator into
# ThirdParty/libgit2/ (not committed), mirroring build_codex.sh's layout.
# TLS uses the system SecureTransport, SSH is disabled (HTTPS + token only),
# per docs/superpowers/specs/2026-11-18-github-sync-design.md.
set -e

VER=1.9.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ThirdParty/libgit2-src"
OUT="$ROOT/ThirdParty/libgit2"

if [ ! -d "$SRC" ]; then
    echo "==> fetching libgit2 v$VER"
    curl -L "https://github.com/libgit2/libgit2/archive/refs/tags/v$VER.tar.gz" -o /tmp/libgit2.tgz
    mkdir -p "$SRC"
    tar -xzf /tmp/libgit2.tgz -C "$SRC" --strip-components 1
fi

build() {
    SDK="$1"; ARCHDIR="$2"
    B="$SRC/build-$ARCHDIR"
    rm -rf "$B"   # a stale dir pins the old generator
    SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
    CLANG="$(xcrun --sdk "$SDK" -f clang)"
    echo "==> building $ARCHDIR ($SDK)"
    cmake -S "$SRC" -B "$B" -G "Unix Makefiles" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_C_COMPILER="$CLANG" \
        -DCMAKE_OSX_SYSROOT="$SYSROOT" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF -DBUILD_FUZZERS=OFF \
        -DUSE_SSH=OFF \
        -DUSE_HTTPS=SecureTransport \
        -DUSE_ICONV=OFF \
        -DUSE_BUNDLED_ZLIB=ON \
        -DREGEX_BACKEND=builtin \
        -DUSE_HTTP_PARSER=builtin > /dev/null
    cmake --build "$B" --target libgit2package -j8 > /dev/null 2>&1 || cmake --build "$B" -j8 > /dev/null
    mkdir -p "$OUT/$ARCHDIR"
    cp "$B/libgit2.a" "$OUT/$ARCHDIR/libgit2.a"
    echo "    -> $OUT/$ARCHDIR/libgit2.a ($(du -h "$OUT/$ARCHDIR/libgit2.a" | cut -f1))"
}

build iphoneos device
build iphonesimulator simulator

# One copy of the headers for the bridging header to include.
mkdir -p "$OUT/include"
cp -R "$SRC/include/." "$OUT/include/"
echo "OK: libgit2 $VER built (device + simulator)"
