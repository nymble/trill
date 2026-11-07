// SPDX-License-Identifier: GPL-3.0-only
//! Print the protocol test vectors (protocol/config-v1-vectors.txt).
//! Every vector is run through the full device path: USB-MIDI packets ->
//! reassembly -> request handling -> reply. `make protocol-vectors`
//! regenerates the file; `cargo test -p trill-config` checks it is current.

fn main() {
    print!("{}", trill_config_vectors::render());
}

#[path = "../tests/support/vectors.rs"]
mod trill_config_vectors;
