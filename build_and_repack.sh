#!/bin/bash

# Get ALVR submodule
#git submodule update --init --recursive

# Check if Rust is installed
if command -v rustc &> /dev/null; then
    echo "Rust is already installed."
else
    echo "Rust is not installed. Installing..."
    curl --proto '=https' --tlsv1.2 https://sh.rustup.rs -sSf | sh
fi

unset SDKROOT

# Install or update cbindgen
cargo install cbindgen

# Add iOS target 
rustup target add aarch64-apple-ios

rm -rf ALVR/target
rm -rf ALVR/build

CARGO_TARGET_DIR=ALVR/target cargo build --manifest-path ALVR/Cargo.toml --target=aarch64-apple-ios -p alvr_client_core --profile distribution
mkdir -p ALVR/build
cd ALVR/alvr/client_core
cbindgen --config cbindgen.toml --crate alvr_client_core --output ../../build/alvr_client_core.h
cd ../../../
rm -rf ALVR/alvr/server

CARGO_TARGET_DIR=ALVR/target cargo build --manifest-path ALVR/Cargo.toml --target=aarch64-apple-ios -p alvr_client_core --profile distribution && \
mkdir -p ALVR/build && \
cd ALVR/alvr/client_core && \
cbindgen --config cbindgen.toml --crate alvr_client_core --output ../../build/alvr_client_core.h && \
cd ../../../ && \
sh repack_alvr_client.sh
