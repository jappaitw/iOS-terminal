#!/bin/sh
# Populate the real ICU (and other) crates over Chromium's empty placeholders in
# the crates.io rusty_v8 source tree, so V8_FROM_SOURCE can build on iOS.
#
# Chromium vendors big data crates as `is_placeholder = true` stubs (it generates
# ICU data its own way). rusty_v8's bundled BUILD.gn still references the real
# crates' build.rs, so the from-source build fails with "build.rs ... missing".
# We fetch the real crates from crates.io and copy them over the placeholders,
# keeping Chromium's epoch-suffixed dir names (e.g. icu_calendar_data-v2).
set -e

V8SRC="$HOME/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/v8-152.2.0"
VEND="$V8SRC/third_party/rust/chromium_crates_io/vendor"
REG="$HOME/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f"
export PATH="$HOME/.cargo/bin:$HOME/depot_tools:$PATH"

echo "=== 1. fetch all ICU crates referenced as placeholders ==="
TMP="$(mktemp -d)"
cd "$TMP"
cargo init --name icufetch -q
# ICU4X data + logic crates that Chromium placeholders. Versions from the scan.
cat >> Cargo.toml <<'EOF'
icu_calendar_data = "=2.4.0"
icu_casemap_data = "=2.4.0"
icu_collator_data = "=2.4.0"
icu_datetime_data = "=2.4.0"
icu_decimal_data = "=2.4.0"
icu_list_data = "=2.4.0"
icu_locale_data = "=2.4.0"
icu_normalizer_data = "=2.4.0"
icu_plurals_data = "=2.4.0"
icu_properties_data = "=2.4.0"
icu_segmenter_data = "=2.4.0"
icu_time_data = "=2.4.0"
icu_locale_fallback_data = "=2.4.0"
icu_experimental_data = "=0.7.0"
icu_collator = "=2.4.0"
icu_datetime = "=2.4.0"
icu_segmenter = "=2.4.0"
icu_time = "=2.4.0"
EOF
cargo fetch 2>&1 | tail -3 || echo "(cargo fetch had resolution issues — continuing with what downloaded)"
cd - >/dev/null
rm -rf "$TMP"

echo "=== 2. copy real crates over placeholders ==="
POP=0; SKIP=0
for d in "$VEND"/*/; do
  grep -q "is_placeholder = true" "$d/Cargo.toml" 2>/dev/null || continue
  name=$(grep -m1 '^name = ' "$d/Cargo.toml" | sed 's/name = "//;s/"//')
  ver=$(grep -m1 '^version = ' "$d/Cargo.toml" | sed 's/version = "//;s/"//')
  real="$REG/$name-$ver"
  if [ -d "$real" ]; then
    # Replace the stub contents with the real crate, keep the -vN dir name.
    rm -rf "$d"/*
    cp -R "$real"/. "$d"/
    printf '{"files":{}}' > "$d/.cargo-checksum.json"
    POP=$((POP+1))
  else
    SKIP=$((SKIP+1))
    echo "  still missing: $name-$ver"
  fi
done
echo "populated=$POP skipped=$SKIP"

echo "=== 3. rebuild v8 crate (sim, i18n on) ==="
cd "/Users/soulfyai/Documents/iphone vscode/native/pocket-codex"
rm -rf target/aarch64-apple-ios-sim/release/build/gn_out
export V8_FROM_SOURCE=1
cargo build -p v8 --release --target aarch64-apple-ios-sim -vv
echo "V8_BUILD_EXIT=$?"
