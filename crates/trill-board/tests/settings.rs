// SPDX-License-Identifier: GPL-3.0-only
use trill_board::settings::*;

#[test]
fn page_is_inside_storage_and_never_the_bootloader() {
    const {
        assert!(PAGE_ADDR >= 0xEC000);
        assert!(PAGE_ADDR + PAGE_SIZE <= BOOTLOADER_ADDR);
        assert!(PAGE_ADDR >= APP_ADDR);
    }
    assert_eq!(
        slot_addr(SLOTS - 1) + RECORD_LEN as u32,
        PAGE_ADDR + PAGE_SIZE
    );
    assert_eq!(SLOTS, 512);
}

#[test]
fn records_round_trip() {
    for d in [false, true] {
        for m in [false, true] {
            let s = BleSettings {
                discoverable: d,
                ble_midi: m,
            };
            assert_eq!(BleSettings::decode(s.encode()), Some(s));
            let b = s.encode_bytes();
            let w = [
                u32::from_le_bytes(b[..4].try_into().unwrap()),
                u32::from_le_bytes(b[4..].try_into().unwrap()),
            ];
            assert_eq!(w, s.encode());
        }
    }
    assert_eq!(
        BleSettings::DEFAULT,
        BleSettings {
            discoverable: true,
            ble_midi: true
        }
    );
}

#[test]
fn torn_or_foreign_records_are_rejected() {
    let good = BleSettings::DEFAULT.encode();
    assert_eq!(BleSettings::decode([0xFFFF_FFFF, 0xFFFF_FFFF]), None);
    assert_eq!(
        BleSettings::decode([good[0], 0xFFFF_FFFF]),
        None,
        "second word not written"
    );
    assert_eq!(BleSettings::decode([good[0] ^ 1, good[1]]), None, "magic");
    assert_eq!(
        BleSettings::decode([good[0], good[1] ^ 0x100]),
        None,
        "check byte"
    );
    assert_eq!(
        BleSettings::decode([good[0], 0x0000_F807]),
        None,
        "unknown flag"
    );
}

fn page(records: &[[u32; 2]]) -> impl Fn(usize) -> [u32; 2] + '_ {
    move |i| records.get(i).copied().unwrap_or([0xFFFF_FFFF; 2])
}

#[test]
fn scan_finds_the_last_record_and_the_next_slot() {
    assert_eq!(
        scan(page(&[])),
        Scan {
            latest: None,
            next_slot: Some(0)
        }
    );
    let off = BleSettings {
        discoverable: false,
        ble_midi: true,
    };
    let both_off = BleSettings {
        discoverable: false,
        ble_midi: false,
    };
    let recs = [
        BleSettings::DEFAULT.encode(),
        off.encode(),
        [0x1234, 0x5678],
        both_off.encode(),
    ];
    assert_eq!(
        scan(page(&recs)),
        Scan {
            latest: Some(both_off),
            next_slot: Some(4)
        }
    );
    // A torn last record keeps the previous value and is skipped.
    let recs = [off.encode(), [MAGIC, 0xFFFF_FFFF]];
    assert_eq!(
        scan(page(&recs)),
        Scan {
            latest: Some(off),
            next_slot: Some(2)
        }
    );
}

#[test]
fn a_full_page_needs_an_erase() {
    let full = vec![BleSettings::DEFAULT.encode(); SLOTS];
    assert_eq!(
        scan(page(&full)),
        Scan {
            latest: Some(BleSettings::DEFAULT),
            next_slot: None
        }
    );
}
