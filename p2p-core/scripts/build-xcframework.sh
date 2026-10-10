#!/usr/bin/env bash
# Cross-compiles p2p_core for iOS device + Apple-silicon simulator, generates Swift bindings, packs an XCFramework.
# Output: <repo>/Vendor/P2PCore.xcframework  and  <repo>/MediaHub/P2P/Generated/p2p_core.swift
set -euo pipefail
cd "$(dirname "$0")/.."
CRATE_DIR="$PWD"
ROOT="$(cd .. && pwd)"
LIB=libp2p_core.a
OUT="$ROOT/Vendor/P2PCore.xcframework"
GEN="$ROOT/MediaHub/P2P/Generated"
STAGE="$CRATE_DIR/build"

# Rust's iOS floor; lower than the app's iOS 26 target on purpose (a static lib may target older than its host app).
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
DEVICE=aarch64-apple-ios
SIM=aarch64-apple-ios-sim

for t in "$DEVICE" "$SIM"; do
  rustup target add "$t" >/dev/null
  cargo build --release --lib --target "$t"
done

# Put headers inside a namespaced 'p2p_coreFFI' subfolder to prevent collision with LibDovi/Dovi.xcframework
rm -rf "$STAGE" && mkdir -p "$STAGE/bindings" "$STAGE/headers/p2p_coreFFI" "$GEN"

# Library mode: bindings are read from the compiled artifact's metadata, so Swift can never drift from the Rust API.
cargo run --release --manifest-path uniffi-bindgen/Cargo.toml -- generate \
  --library "target/$DEVICE/release/$LIB" --language swift --out-dir "$STAGE/bindings"

cp "$STAGE/bindings/p2p_coreFFI.h" "$STAGE/headers/p2p_coreFFI/"
cp "$STAGE/bindings/p2p_coreFFI.modulemap" "$STAGE/headers/p2p_coreFFI/module.modulemap"
cp "$STAGE/bindings/p2p_core.swift" "$GEN/p2p_core.swift"

rm -rf "$OUT" && mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -library "target/$DEVICE/release/$LIB" -headers "$STAGE/headers" \
  -library "target/$SIM/release/$LIB"    -headers "$STAGE/headers" \
  -output "$OUT"

echo "OK  $OUT"
echo "OK  $GEN/p2p_core.swift"
