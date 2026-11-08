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

#[test]
fn telemetry_fixtures_are_current_and_round_trip() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../protocol/telemetry-v1-frames.txt"
    );
    let committed = std::fs::read_to_string(path).expect("protocol/telemetry-v1-frames.txt");
    assert_eq!(
        committed,
        vectors_common::render_telemetry(),
        "regenerate with `make protocol-vectors`"
    );
    for (name, f) in vectors_common::telemetry_frames() {
        let bytes = trill_config::telemetry::encode(&f);
        assert_eq!(bytes.len(), trill_config::telemetry::FRAME_LEN, "{name}");
        assert!(bytes.len() <= trill_config::MAX_MESSAGE_LEN);
        assert_eq!(trill_config::telemetry::decode(&bytes), Some(f), "{name}");
    }
}
