#!/bin/sh
# Populate Chromium's empty placeholder crates in the crates.io rusty_v8 source
# tree with the real crates from crates.io, so V8_FROM_SOURCE can build on iOS.
#
# Chromium vendors the ICU4X / diplomat / zerovec ecosystem as `is_placeholder`
# stubs (it generates ICU data its own way). rusty_v8's bundled BUILD.gn still
# references the real crates' sources, so the from-source build fails one crate
# at a time with "src/lib.rs ... missing". We fetch each referenced crate and
# copy it over the placeholder, keeping Chromium's epoch-suffixed dir name.
#
# Platform-only placeholders (windows*, wasm*, winapi, etc.) are NOT in the
# arm64 host/target build graph, so we skip fetching them (they never block).
set -e

V8SRC="$HOME/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/v8-152.2.0"
VEND="$V8SRC/third_party/rust/chromium_crates_io/vendor"
REG="$HOME/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f"
# A gclient V8 checkout pinned to the SAME revision rusty_v8 152.2.0 bundles
# (V8 15.2.124.1). Its vendored crate versions (diplomat v0_15, icu -v2, …)
# match the crate's bundled BUILD.gn exactly — a HEAD checkout does not.
FETCHED="$HOME/v8src/v8"
export PATH="$HOME/.cargo/bin:$HOME/depot_tools:$PATH"

echo "=== 0. copy the version-matched chromium_crates_io tree into the crate ==="
rm -rf "$V8SRC/third_party/rust/chromium_crates_io"
cp -R "$FETCHED/third_party/rust/chromium_crates_io" "$V8SRC/third_party/rust/"
echo "vendor dirs: $(ls "$VEND" | wc -l)"

# Denylist: platform / build-tool placeholders that the arm64 build never needs.
is_platform() {
  case "$1" in
    windows*|winapi*|wasm-bindgen*|js-sys|web-sys|redox_syscall|r-efi \
    |iana-time-zone-haiku|bumpalo|cc|cxx-build|link-cplusplus|scratch \
    |zerocopy-derive|find-msvc-tools|embedded-io) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== 1. collect non-platform placeholders and fetch each from crates.io ==="
NEED=""
for d in "$VEND"/*/; do
  grep -q "is_placeholder = true" "$d/Cargo.toml" 2>/dev/null || continue
  name=$(grep -m1 '^name = ' "$d/Cargo.toml" | sed 's/name = "//;s/"//')
  ver=$(grep -m1 '^version = ' "$d/Cargo.toml" | sed 's/version = "//;s/"//')
  is_platform "$name" && continue
  [ -d "$REG/$name-$ver" ] && continue   # already in registry
  NEED="$NEED $name@$ver"
done
echo "to fetch:$NEED"
for spec in $NEED; do
  name="${spec%@*}"; ver="${spec#*@}"
  TMP="$(mktemp -d)"; cd "$TMP"
  cargo init --name f -q 2>/dev/null || true
  printf '%s = "=%s"\n' "$name" "$ver" >> Cargo.toml
  if cargo fetch >/dev/null 2>&1; then echo "  fetched $name-$ver"; else echo "  FAILED  $name-$ver"; fi
  cd - >/dev/null; rm -rf "$TMP"
done

echo "=== 2. copy real crates over placeholders (all with a registry match) ==="
POP=0; SKIP=0
for d in "$VEND"/*/; do
  grep -q "is_placeholder = true" "$d/Cargo.toml" 2>/dev/null || continue
  name=$(grep -m1 '^name = ' "$d/Cargo.toml" | sed 's/name = "//;s/"//')
  ver=$(grep -m1 '^version = ' "$d/Cargo.toml" | sed 's/version = "//;s/"//')
  real="$REG/$name-$ver"
  if [ -d "$real" ]; then
    rm -rf "$d"/*
    cp -R "$real"/. "$d"/
    printf '{"files":{}}' > "$d/.cargo-checksum.json"
    POP=$((POP+1))
  else
    is_platform "$name" || echo "  still missing (non-platform): $name-$ver"
    SKIP=$((SKIP+1))
  fi
done
echo "populated=$POP skipped=$SKIP"

echo "=== 3. ensure icudtl.dat present ==="
mkdir -p "$V8SRC/third_party/icu/common"
[ -f "$V8SRC/third_party/icu/common/icudtl.dat" ] || \
  cp ~/v8src/v8/third_party/icu/common/icudtl.dat "$V8SRC/third_party/icu/common/icudtl.dat"

echo "=== 4. rebuild v8 crate (sim, i18n on) ==="
cd "/Users/soulfyai/Documents/iphone vscode/native/pocket-codex"
rm -rf target/aarch64-apple-ios-sim/release/build/gn_out
export V8_FROM_SOURCE=1
cargo build -p v8 --release --target aarch64-apple-ios-sim -vv
echo "V8_BUILD_EXIT=$?"
