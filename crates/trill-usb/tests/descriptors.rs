// SPDX-License-Identifier: GPL-3.0-only
//! Build the firmware's exact USB layout against a mock driver that enforces
//! the nRF52840 USBD endpoint budget, then check the configuration
//! descriptor against USB 2.0 ch. 9, the IAD ECN and USB-MIDI 1.0. This is a
//! structural check only; it does not prove that a given host accepts the
//! device (see docs/usb-midi.md for the hardware acceptance procedure).

use embassy_usb::class::cdc_acm::State;
use embassy_usb::driver::{
    Bus, ControlPipe, Driver, Endpoint, EndpointAddress, EndpointAllocError, EndpointError,
    EndpointIn, EndpointInfo, EndpointOut, EndpointType, Event, Unsupported,
};
use embassy_usb::Builder;
use trill_usb::*;

/// nRF52840 USBD: EP0 control + 7 bulk/interrupt IN + 7 bulk/interrupt OUT,
/// max 64 bytes each (plus isochronous EP8, unused).
const NRF_EPS: u8 = 7;

struct MockDriver {
    ins: u8,
    outs: u8,
}

struct Ep(EndpointInfo);
impl Endpoint for Ep {
    fn info(&self) -> &EndpointInfo {
        &self.0
    }
    async fn wait_enabled(&mut self) {}
}
impl EndpointIn for Ep {
    async fn write(&mut self, _buf: &[u8]) -> Result<(), EndpointError> {
        Err(EndpointError::Disabled)
    }
}
impl EndpointOut for Ep {
    async fn read(&mut self, _buf: &mut [u8]) -> Result<usize, EndpointError> {
        Err(EndpointError::Disabled)
    }
}
struct MockBus;
impl Bus for MockBus {
    async fn enable(&mut self) {}
    async fn disable(&mut self) {}
    async fn poll(&mut self) -> Event {
        Event::PowerRemoved
    }
    fn endpoint_set_enabled(&mut self, _a: EndpointAddress, _e: bool) {}
    fn endpoint_set_stalled(&mut self, _a: EndpointAddress, _s: bool) {}
    fn endpoint_is_stalled(&mut self, _a: EndpointAddress) -> bool {
        false
    }
    async fn remote_wakeup(&mut self) -> Result<(), Unsupported> {
        Err(Unsupported)
    }
}
struct MockPipe;
impl ControlPipe for MockPipe {
    fn max_packet_size(&self) -> usize {
        64
    }
    async fn setup(&mut self) -> [u8; 8] {
        [0; 8]
    }
    async fn data_out(
        &mut self,
        _b: &mut [u8],
        _f: bool,
        _l: bool,
    ) -> Result<usize, EndpointError> {
        Err(EndpointError::Disabled)
    }
    async fn data_in(&mut self, _d: &[u8], _f: bool, _l: bool) -> Result<(), EndpointError> {
        Err(EndpointError::Disabled)
    }
    async fn accept(&mut self) {}
    async fn reject(&mut self) {}
    async fn accept_set_address(&mut self, _a: u8) {}
}

impl MockDriver {
    fn alloc(
        &mut self,
        dir_in: bool,
        ep_type: EndpointType,
        mps: u16,
        interval_ms: u8,
    ) -> Result<Ep, EndpointAllocError> {
        assert!(mps <= 64, "nRF52840 bulk/interrupt max packet is 64");
        assert_ne!(ep_type, EndpointType::Isochronous);
        let n = if dir_in {
            &mut self.ins
        } else {
            &mut self.outs
        };
        if *n >= NRF_EPS {
            return Err(EndpointAllocError);
        }
        *n += 1;
        let addr = if dir_in {
            EndpointAddress::from(0x80 | *n)
        } else {
            EndpointAddress::from(*n)
        };
        Ok(Ep(EndpointInfo {
            addr,
            ep_type,
            max_packet_size: mps,
            interval_ms,
        }))
    }
}

impl<'a> Driver<'a> for MockDriver {
    type EndpointOut = Ep;
    type EndpointIn = Ep;
    type ControlPipe = MockPipe;
    type Bus = MockBus;
    fn alloc_endpoint_out(
        &mut self,
        t: EndpointType,
        _a: Option<EndpointAddress>,
        mps: u16,
        i: u8,
    ) -> Result<Ep, EndpointAllocError> {
        self.alloc(false, t, mps, i)
    }
    fn alloc_endpoint_in(
        &mut self,
        t: EndpointType,
        _a: Option<EndpointAddress>,
        mps: u16,
        i: u8,
    ) -> Result<Ep, EndpointAllocError> {
        self.alloc(true, t, mps, i)
    }
    fn start(self, _mps: u16) -> (MockBus, MockPipe) {
        (MockBus, MockPipe)
    }
}

/// Build the layout and return the configuration descriptor bytes and the
/// (the mock driver panics or fails allocation beyond the nRF52840 budget).
fn build(pcm: bool) -> Vec<u8> {
    let mut config = [0u8; CONFIG_DESC_LEN];
    let mut bos = [0u8; BOS_DESC_LEN];
    let mut msos = [0u8; 0];
    let mut ctrl = [0u8; CONTROL_BUF_LEN];
    let mut diag_state = State::new();
    let mut pcm_state = State::new();
    {
        let mut builder = Builder::new(
            MockDriver { ins: 0, outs: 0 },
            device_config(pcm),
            &mut config,
            &mut bos,
            &mut msos,
            &mut ctrl,
        );
        let f = add_functions(&mut builder, &mut diag_state, pcm.then_some(&mut pcm_state));
        assert_eq!(f.pcm.is_some(), pcm);
        let _dev = builder.build();
        let _ = f;
    }
    let total = u16::from_le_bytes([config[2], config[3]]) as usize;
    assert!(total <= CONFIG_DESC_LEN);
    config[..total].to_vec()
}

fn descriptors(cfg: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < cfg.len() {
        let len = cfg[i] as usize;
        assert!(
            len >= 2 && i + len <= cfg.len(),
            "malformed descriptor at {i}"
        );
        out.push(&cfg[i..i + len]);
        i += len;
    }
    assert_eq!(i, cfg.len(), "descriptors exactly fill wTotalLength");
    out
}

const INTERFACE: u8 = 4;
const ENDPOINT: u8 = 5;
const IAD: u8 = 11;
const CS_INTERFACE: u8 = 0x24;
const CS_ENDPOINT: u8 = 0x25;

fn check(pcm: bool) {
    let cfg = build(pcm);
    let ds = descriptors(&cfg);
    let c = ds[0];
    assert_eq!(c[1], 2, "configuration descriptor first");
    let n_if = if pcm { 6 } else { 4 };
    assert_eq!(c[4], n_if, "bNumInterfaces");
    assert_eq!(c[5], 1, "bConfigurationValue");
    assert_eq!(c[7] & 0x80, 0x80, "bmAttributes bit 7 reserved-set");
    assert_eq!(c[8] as u16 * 2, MAX_POWER_MA, "bMaxPower in 2 mA units");

    // Interfaces contiguous from 0, each preceded by its IAD.
    let ifaces: Vec<&[u8]> = ds.iter().copied().filter(|d| d[1] == INTERFACE).collect();
    assert_eq!(ifaces.len(), n_if as usize);
    for (i, d) in ifaces.iter().enumerate() {
        assert_eq!(d[2] as usize, i, "bInterfaceNumber");
        assert_eq!(d[3], 0, "no alternate settings");
    }
    let iads: Vec<&[u8]> = ds.iter().copied().filter(|d| d[1] == IAD).collect();
    assert_eq!(iads.len(), if pcm { 3 } else { 2 });
    // Diagnostics CDC = interfaces 0-1, MIDI = 2-3, PCM = 4-5.
    assert_eq!(&iads[0][2..6], &[0, 2, 0x02, 0x02], "CDC ACM IAD");
    assert_eq!(&iads[1][2..6], &[2, 2, 0x01, 0x01], "Audio IAD for MIDI");
    if pcm {
        assert_eq!(&iads[2][2..6], &[4, 2, 0x02, 0x02]);
    }

    // Audio Control interface: class 1 / subclass 1, no endpoints,
    // CS header bcdADC 1.00 listing the MIDIStreaming interface.
    let ac = ifaces[2];
    assert_eq!((ac[4], ac[5], ac[6]), (0, 0x01, 0x01));
    let ac_pos = ds.iter().position(|d| d.as_ptr() == ac.as_ptr()).unwrap();
    let ach = ds[ac_pos + 1];
    assert_eq!(ach, &[9, CS_INTERFACE, 0x01, 0x00, 0x01, 9, 0, 1, 3]);

    // MIDIStreaming interface: class 1 / subclass 3, two endpoints.
    let ms = ifaces[3];
    assert_eq!((ms[4], ms[5], ms[6]), (2, 0x01, 0x03));
    let ms_pos = ds.iter().position(|d| d.as_ptr() == ms.as_ptr()).unwrap();
    let next_if = ds[ms_pos + 1..]
        .iter()
        .position(|d| d[1] == INTERFACE || d[1] == IAD)
        .map_or(ds.len(), |p| ms_pos + 1 + p);
    let body = &ds[ms_pos + 1..next_if];
    let hdr = body[0];
    assert_eq!(
        &hdr[..5],
        &[7, CS_INTERFACE, 0x01, 0x00, 0x01],
        "MS header bcdMSC 1.00"
    );
    let w_total = u16::from_le_bytes([hdr[5], hdr[6]]) as usize;
    let body_len: usize = body.iter().map(|d| d.len()).sum();
    assert_eq!(
        w_total, body_len,
        "MS wTotalLength = header + jacks + endpoints"
    );

    // Jacks: IDs unique, every OUT jack source exists.
    let mut in_emb = Vec::new();
    let mut out_emb = Vec::new();
    let mut ids = Vec::new();
    for d in body.iter().filter(|d| d[1] == CS_INTERFACE && d[2] != 0x01) {
        let (sub, kind, id) = (d[2], d[3], d[4]);
        assert!(!ids.contains(&id), "duplicate jack id");
        ids.push(id);
        match (sub, kind) {
            (0x02, 0x01) => in_emb.push(id),
            (0x03, 0x01) => out_emb.push(id),
            (0x02, 0x02) | (0x03, 0x02) => {}
            _ => panic!("unexpected jack {d:?}"),
        }
    }
    for d in body.iter().filter(|d| d[1] == CS_INTERFACE && d[2] == 0x03) {
        assert_eq!(d[5], 1, "one input pin");
        assert!(ids.contains(&d[6]), "source jack exists");
    }
    let cables = MIDI_CABLES as usize;
    assert_eq!((in_emb.len(), out_emb.len()), (cables, cables));

    // Bulk endpoints, 64 bytes, each followed by a CS MS_GENERAL endpoint
    // descriptor associating the right embedded jack.
    let eps: Vec<usize> = (0..body.len())
        .filter(|&i| body[i][1] == ENDPOINT)
        .collect();
    assert_eq!(eps.len(), 2);
    let mut dirs = Vec::new();
    for &i in &eps {
        let e = body[i];
        assert!(
            e.len() == 7 || e.len() == 9,
            "standard (7) or audio (9) endpoint descriptor"
        );
        assert_eq!(e[3] & 0x03, 0x02, "bulk");
        assert_eq!(u16::from_le_bytes([e[4], e[5]]), MAX_PACKET);
        let cs = body[i + 1];
        assert_eq!(&cs[1..4], &[CS_ENDPOINT, 0x01, MIDI_CABLES]);
        assert_eq!(cs[0] as usize, 4 + cables, "bLength = 4 + bNumEmbMIDIJack");
        let is_in = e[2] & 0x80 != 0;
        // Host->device (OUT) feeds the embedded IN jacks; device->host (IN)
        // is sourced from the embedded OUT jacks. The n-th listed jack is
        // virtual cable n, so cable order = jack order.
        let jacks = &cs[4..4 + cables];
        if is_in {
            assert_eq!(jacks, &out_emb[..]);
        } else {
            assert_eq!(jacks, &in_emb[..]);
        }
        dirs.push(is_in);
    }
    dirs.sort();
    assert_eq!(dirs, vec![false, true]);

    // Endpoint budget for the whole device (nRF52840: 7 IN + 7 OUT).
    let all_eps: Vec<u8> = ds
        .iter()
        .filter(|d| d[1] == ENDPOINT)
        .map(|d| d[2])
        .collect();
    let n_in = all_eps.iter().filter(|a| *a & 0x80 != 0).count();
    let n_out = all_eps.len() - n_in;
    let mut uniq = all_eps.clone();
    uniq.sort();
    uniq.dedup();
    assert_eq!(uniq.len(), all_eps.len(), "endpoint addresses unique");
    // CDC: notification IN + data IN/OUT each; MIDI: IN + OUT.
    let cdc = if pcm { 2 } else { 1 };
    assert_eq!(n_in, 2 * cdc + 1);
    assert_eq!(n_out, cdc + 1);
    assert!(n_in <= NRF_EPS as usize && n_out <= NRF_EPS as usize);
}

#[test]
fn default_layout_diag_plus_midi() {
    check(false);
}

#[test]
fn pcm_layout_diag_midi_pcm() {
    check(true);
}

#[test]
fn layouts_use_distinct_pid_codes_test_ids() {
    let a = device_config(false);
    assert_eq!(USB_VID, 0x1209);
    assert_ne!(product_id(false), product_id(true));
    for p in [product_id(false), product_id(true)] {
        assert!((0x0001..=0x0010).contains(&p), "pid.codes test range");
    }
    // Composite with IADs => device class EF/02/01.
    assert_eq!(
        (a.device_class, a.device_sub_class, a.device_protocol),
        (0xEF, 0x02, 0x01)
    );
    assert!(a.composite_with_iads);
}

#[test]
fn cables_and_release_are_documented_values() {
    assert_eq!((CABLE_INSTRUMENT, CABLE_CONFIG, MIDI_CABLES), (0, 1, 2));
    for pcm in [false, true] {
        assert_eq!(device_config(pcm).device_release, DEVICE_RELEASE);
    }
}

#[test]
fn descriptor_buffer_has_headroom() {
    for pcm in [false, true] {
        let cfg = build(pcm);
        eprintln!("pcm={pcm}: configuration descriptor {} bytes", cfg.len());
        assert!(cfg.len() + 32 <= CONFIG_DESC_LEN, "{} bytes", cfg.len());
    }
}
