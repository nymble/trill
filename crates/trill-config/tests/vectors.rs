// SPDX-License-Identifier: GPL-3.0-only
//! The committed vectors file matches the implementation.
#[path = "support/vectors.rs"]
mod vectors_common;

#[test]
fn vectors_file_is_current() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../protocol/config-v1-vectors.txt"
    );
    let committed = std::fs::read_to_string(path).expect("protocol/config-v1-vectors.txt");
    assert_eq!(
        committed,
        vectors_common::render(),
        "regenerate with `make protocol-vectors`"
    );
}
