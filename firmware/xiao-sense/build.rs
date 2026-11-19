// SPDX-License-Identifier: GPL-3.0-only
//! Put the memory layout on the linker search path as `memory.x` (the
//! sources live in `link/` so the package root never shadows the copy):
//! `link/memory-ble.x` for the `ble-midi` build (SoftDevice RAM reserved),
//! otherwise `link/memory.x`.
use std::{env, fs, path::PathBuf};

fn main() {
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let src = if env::var_os("CARGO_FEATURE_BLE_MIDI").is_some() {
        "link/memory-ble.x"
    } else {
        "link/memory.x"
    };
    fs::copy(src, out.join("memory.x")).unwrap();
    println!("cargo:rustc-link-search={}", out.display());
    println!("cargo:rerun-if-changed=link/memory.x");
    println!("cargo:rerun-if-changed=link/memory-ble.x");
    println!("cargo:rerun-if-changed=build.rs");
}
