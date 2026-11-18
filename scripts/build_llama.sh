#!/bin/sh
# 編譯 llama.cpp(含 llama-server-impl 的 /v1/responses 伺服器)為 iOS 靜態庫,
# 輸出到 ThirdParty/llama/。需求:~/Documents/research/llama.cpp(ggml-org/llama.cpp)。
# 用法:sh scripts/build_llama.sh
set -e
cd "$(dirname "$0")/.."
SRC=../research/llama.cpp
[ -d "$SRC" ] || { echo "缺少 llama.cpp 原始碼:git clone https://github.com/ggml-org/llama.cpp ~/Documents/research/llama.cpp" >&2; exit 1; }

build() { # $1=build dir  $2=cmake system/sysroot flags…
    DIR="$1"; shift
    cmake -S "$SRC" -B "$SRC/$DIR" -G Xcode \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_MACOSX_BUNDLE=OFF \
        -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
        -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_COMMON=ON -DLLAMA_BUILD_SERVER=ON -DLLAMA_CURL=OFF \
        "$@" >/dev/null
    for T in llama ggml server-context llama-server-impl; do
        cmake --build "$SRC/$DIR" --config Release --target "$T" -- -quiet >/dev/null
    done
}

build build-ios-device
build build-ios-sim -DCMAKE_OSX_SYSROOT=iphonesimulator

collect() { # $1=build dir  $2=dest
    mkdir -p "$2"
    find "$SRC/$1" -name "*.a" -path "*Release-*" -exec cp {} "$2/" \;
}
collect build-ios-device ThirdParty/llama/device
collect build-ios-sim    ThirdParty/llama/simulator
echo OK: && ls -lh ThirdParty/llama/device | tail -n +2 | awk '{print $9, $5}'
