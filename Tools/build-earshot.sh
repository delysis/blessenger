#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source="${1:-$root/.build/earshot}"
revision=ffd32d426f556c55a8c84490c12745743ee4bd79
if [[ ! -e "$source" ]]; then
  git clone https://github.com/pykeio/earshot.git "$source"
  git -C "$source" checkout --detach "$revision"
fi
[[ "$(git -C "$source" rev-parse HEAD)" == "$revision" ]]
git -C "$source" diff --exit-code
cmp "$source/bindings/c/earshot.h" "$root/Reference/Earshot/earshot.h"
shim="$root/.build/earshot-shim"
mkdir -p "$shim"
cp "$root/Native/Earshot/lib.rs" "$shim/lib.rs"
cat > "$shim/Cargo.toml" <<EOF
[package]
name = "callgemma-earshot"
version = "0.1.0"
edition = "2024"
[lib]
name = "earshot_ffi"
path = "lib.rs"
crate-type = ["staticlib"]
[dependencies]
earshot = { path = "$source", default-features = false, features = ["libm"] }
[profile.release]
panic = "abort"
opt-level = 3
codegen-units = 1
EOF
for pair in aarch64-apple-darwin:macosx aarch64-apple-ios:iphoneos aarch64-apple-ios-sim:iphonesimulator; do
  target="${pair%%:*}"
  platform="${pair##*:}"
  cargo build --manifest-path "$shim/Cargo.toml" --release --target "$target"
  mkdir -p "$root/Vendor/earshot/$platform"
  cp "$shim/target/$target/release/libearshot_ffi.a" "$root/Vendor/earshot/$platform/libearshot.a"
done
{
  echo "revision $revision"
  rustc --version
  shasum -a 256 "$root"/Vendor/earshot/*/libearshot.a
} > "$root/Vendor/earshot/receipt.txt"
