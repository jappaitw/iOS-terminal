#!/bin/sh
# 編譯 pocket-codex(內嵌 Codex app-server 的 Rust staticlib)到 ThirdParty/codex/。
# 需求:rustup(含 aarch64-apple-ios 與 aarch64-apple-ios-sim target)、
#       ~/Documents/research/codex(openai/codex 原始碼)與 ~/Documents/research/mxc-patched。
# 用法:sh scripts/build_codex.sh
set -e
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

CRATE=native/pocket-codex
CODEX=../research/codex/codex-rs
[ -d "$CODEX" ] || { echo "缺少 codex 原始碼:請 clone openai/codex 到 ~/Documents/research/codex" >&2; exit 1; }

# 版本偏移防呆:一定要用 codex 自己的 Cargo.lock 當基準(見 ON_DEVICE_AI_CLI_FEASIBILITY.md)。
[ -f "$CRATE/Cargo.lock" ] || cp "$CODEX/Cargo.lock" "$CRATE/Cargo.lock"

for TARGET in aarch64-apple-ios aarch64-apple-ios-sim; do
    rustup target add "$TARGET" >/dev/null 2>&1 || true
    (cd "$CRATE" && cargo build --release --target "$TARGET")
done

mkdir -p ThirdParty/codex/device ThirdParty/codex/simulator
cp "$CRATE/target/aarch64-apple-ios/release/libpocket_codex.a" ThirdParty/codex/device/
cp "$CRATE/target/aarch64-apple-ios-sim/release/libpocket_codex.a" ThirdParty/codex/simulator/
echo "OK:"
ls -lh ThirdParty/codex/device/libpocket_codex.a ThirdParty/codex/simulator/libpocket_codex.a
