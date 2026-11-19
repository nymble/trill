// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nymble (https://github.com/nymble)

//! MIDI over Bluetooth LE (feature `ble-midi`), on the S140 SoftDevice that
//! the factory bootloader already keeps in flash. The SoftDevice and the
//! bootloader are never written; this image only enables the SoftDevice
//! at run time.
//!
//! * One peripheral link, the standard BLE-MIDI service and MIDI I/O
//!   characteristic (`ble-midi` crate), notifications of the same
//!   instrument MIDI the USB writer sends on cable 0.
//! * Writes from the central (MIDI in) are accepted and ignored; the
//!   configuration protocol and telemetry stay on USB.
//! * Advertised name `Trillium XXXX`, where `XXXX` is the low 16 bits of
//!   the chip's factory BLE address (FICR DEVICEADDR), so two boards in
//!   one room are distinguishable and the name matches the address shown
//!   by hosts.
//! * No pairing or bonding (open link, like most BLE-MIDI controllers);
//!   hosts connect through their Bluetooth MIDI panels.
//! * The SoftDevice reports USB power events, so USB keeps working:
//!   VBUS is fed to embassy-usb through a software detector.

use core::fmt::Write as _;
use core::mem;
use core::sync::atomic::Ordering;

use embassy_futures::select::select;
use embassy_nrf::usb::vbus_detect::SoftwareVbusDetect;
use embassy_time::{Instant, Timer};
use heapless::String;
use nrf_softdevice::ble::advertisement_builder::{
    Flag, LegacyAdvertisementBuilder, LegacyAdvertisementPayload, ServiceList,
};
use nrf_softdevice::ble::gatt_server::builder::ServiceBuilder;
use nrf_softdevice::ble::gatt_server::characteristic::{Attribute, Metadata, Properties};
use nrf_softdevice::ble::gatt_server::{self, NotifyValueError, RegisterError, WriteOp};
use nrf_softdevice::ble::{peripheral, Connection, Uuid};
use nrf_softdevice::{raw, Softdevice};
use static_cell::StaticCell;

use crate::shared::*;

/// Name buffer: "Trillium " + 4 hex digits.
pub type Name = String<16>;

/// ATT MTU offered to centrals (notification payload = MTU − 3).
const ATT_MTU: u16 = ble_midi::MAX_PACKET_LEN as u16 + 3;
/// Preferred connection interval 7.5–15 ms (1.25 ms units), as the
/// BLE-MIDI specification recommends; Apple hosts grant 11.25–15 ms.
const CONN_INTERVAL_MIN: u16 = 6;
const CONN_INTERVAL_MAX: u16 = 12;
/// Supervision timeout 2 s (10 ms units).
const SUPERVISION_TIMEOUT: u16 = 200;
/// Advertising interval 100 ms (0.625 ms units): quick discovery, low cost.
const ADV_INTERVAL: u32 = 160;

/// `sd_power_usbregstatus_get` bits (nRF52840 POWER.USBREGSTATUS).
const USBREGSTATUS_VBUSDETECT: u32 = 1 << 0;
const USBREGSTATUS_OUTPUTRDY: u32 = 1 << 1;

static NAME: StaticCell<Name> = StaticCell::new();
static VBUS: StaticCell<SoftwareVbusDetect> = StaticCell::new();
static SERVER: StaticCell<MidiServer> = StaticCell::new();
static ADV: StaticCell<LegacyAdvertisementPayload> = StaticCell::new();
static SCAN: StaticCell<LegacyAdvertisementPayload> = StaticCell::new();

/// The advertised and GAP device name for this chip.
pub fn device_name() -> Name {
    let addr0 = embassy_nrf::pac::FICR.deviceaddr(0).read();
    let mut n = Name::new();
    let _ = write!(n, "Trillium {:04X}", addr0 & 0xFFFF);
    n
}

/// First address after MBR + S140 7.3.0: the application vector table.
const APP_BASE: u32 = raw::MBR_SIZE + raw::SD_FLASH_SIZE;
/// SoftDevice base (right after the 4 KiB MBR).
const SD_BASE: u32 = raw::MBR_SIZE;

/// The SoftDevice's information struct in flash (read only).
#[derive(Clone, Copy)]
pub struct SoftDeviceInfo {
    /// Firmware ID (S140 7.3.0 = 0x0123).
    pub fwid: u16,
    /// SoftDevice ID (140).
    pub id: u32,
    /// Version as `major * 1_000_000 + minor * 1_000 + bugfix`.
    pub version: u32,
}

/// Read the SoftDevice information struct below the application. `None`
/// when no SoftDevice is present (wrong magic): the BLE build then runs
/// USB-only instead of calling into empty flash.
pub fn softdevice_info() -> Option<SoftDeviceInfo> {
    const MAGIC: u32 = 0x51B1_E5DB;
    let at = |off: u32| -> u32 {
        // SAFETY: aligned reads of on-chip flash inside the MBR/SoftDevice
        // region, which is always mapped.
        unsafe { core::ptr::read_volatile((SD_BASE + off) as *const u32) }
    };
    if at(raw::SOFTDEVICE_INFO_STRUCT_OFFSET + 4) != MAGIC {
        return None;
    }
    Some(SoftDeviceInfo {
        fwid: at(raw::SD_FWID_OFFSET) as u16,
        id: at(raw::SD_ID_OFFSET),
        version: at(raw::SD_VERSION_OFFSET),
    })
}

/// Hand interrupt dispatch back to the MBR -> SoftDevice -> application
/// chain the SoftDevice needs (its own RADIO/TIMER0/RTC0/POWER/SVC
/// handlers must run first). The reset handler pointed VTOR at this image;
/// here VTOR goes back to 0 (MBR), the MBR forwards to the SoftDevice, and
/// the SoftDevice forwards everything else to this image's table.
///
/// Both MBR and SoftDevice calls only set RAM variables: no flash is
/// written and the MBR's copy commands are never used. Must run at the
/// very start of `main` with interrupts enabled (SVC) and no peripheral
/// interrupt enabled yet.
pub fn route_interrupts_through_softdevice() {
    // SAFETY: early boot, no interrupt is enabled, so nothing is taken
    // between the VTOR write and the forwarding setup.
    unsafe {
        (*cortex_m::peripheral::SCB::PTR).vtor.write(0);
        cortex_m::asm::dsb();
        cortex_m::asm::isb();
        let mut cmd = raw::sd_mbr_command_t {
            command: raw::NRF_MBR_COMMANDS_SD_MBR_COMMAND_IRQ_FORWARD_ADDRESS_SET,
            params: raw::sd_mbr_command_t__bindgen_ty_1 {
                irq_forward_address_set: raw::sd_mbr_command_irq_forward_address_set_t {
                    address: SD_BASE,
                },
            },
        };
        raw::sd_mbr_command(&mut cmd);
        raw::sd_softdevice_vector_table_base_set(APP_BASE);
    }
}

/// Everything `main` needs after the SoftDevice is enabled.
pub struct Started {
    pub server: Option<&'static MidiServer>,
    pub vbus: &'static SoftwareVbusDetect,
    pub name: &'static Name,
}

/// Enable the SoftDevice (after the RNG has been used and before any
/// peripheral the SoftDevice protects is touched), register the BLE-MIDI
/// service and start USB power reporting. `server` is `None` (and the
/// state [`BLE_FAILED`]) if the service cannot be registered; USB still
/// works. a SoftDevice configuration error
/// panics inside `nrf-softdevice` and counts towards safe mode.
pub fn start() -> Started {
    let name: &'static Name = NAME.init(device_name());
    let config = nrf_softdevice::Config {
        // XIAO nRF52840 has the 32.768 kHz crystal (also used by RTC1).
        clock: Some(raw::nrf_clock_lf_cfg_t {
            source: raw::NRF_CLOCK_LF_SRC_XTAL as u8,
            rc_ctiv: 0,
            rc_temp_ctiv: 0,
            accuracy: raw::NRF_CLOCK_LF_ACCURACY_20_PPM as u8,
        }),
        conn_gap: Some(raw::ble_gap_conn_cfg_t {
            conn_count: 1,
            event_length: 6,
        }),
        conn_gatt: Some(raw::ble_gatt_conn_cfg_t { att_mtu: ATT_MTU }),
        conn_gatts: Some(raw::ble_gatts_conn_cfg_t {
            hvn_tx_queue_size: 4,
        }),
        gatts_attr_tab_size: Some(raw::ble_gatts_cfg_attr_tab_size_t {
            attr_tab_size: 1024,
        }),
        gap_role_count: Some(raw::ble_gap_cfg_role_count_t {
            adv_set_count: 1,
            periph_role_count: 1,
            central_role_count: 0,
            central_sec_count: 0,
            _bitfield_1: raw::ble_gap_cfg_role_count_t::new_bitfield_1(0),
        }),
        gap_device_name: Some(raw::ble_gap_cfg_device_name_t {
            p_value: name.as_ptr() as _,
            current_len: name.len() as u16,
            max_len: name.len() as u16,
            // SAFETY: an all-zero security mode is "no access" for writes.
            write_perm: unsafe { mem::zeroed() },
            _bitfield_1: raw::ble_gap_cfg_device_name_t::new_bitfield_1(
                raw::BLE_GATTS_VLOC_STACK as u8,
            ),
        }),
        ..Default::default()
    };
    let sd = Softdevice::enable(&config);

    // SAFETY: plain SoftDevice calls with valid arguments after enable.
    let usb_status = unsafe {
        // USB needs the 64 MHz crystal; ask the SoftDevice to keep it on.
        raw::sd_clock_hfclk_request();
        raw::sd_power_usbdetected_enable(1);
        raw::sd_power_usbremoved_enable(1);
        raw::sd_power_usbpwrrdy_enable(1);
        let ppcp = raw::ble_gap_conn_params_t {
            min_conn_interval: CONN_INTERVAL_MIN,
            max_conn_interval: CONN_INTERVAL_MAX,
            slave_latency: 0,
            conn_sup_timeout: SUPERVISION_TIMEOUT,
        };
        raw::sd_ble_gap_ppcp_set(&ppcp);
        let mut status = 0u32;
        raw::sd_power_usbregstatus_get(&mut status);
        status
    };
    let vbus = VBUS.init(SoftwareVbusDetect::new(
        usb_status & USBREGSTATUS_VBUSDETECT != 0,
        usb_status & USBREGSTATUS_OUTPUTRDY != 0,
    ));

    let server = match MidiServer::new(sd) {
        Ok(s) => Some(&*SERVER.init(s)),
        Err(_) => {
            BLE_STATE.store(BLE_FAILED, Ordering::Relaxed);
            None
        }
    };
    Started { server, vbus, name }
}

/// The BLE-MIDI GATT service.
pub struct MidiServer {
    io_handle: u16,
    cccd_handle: u16,
}

impl MidiServer {
    fn new(sd: &mut Softdevice) -> Result<Self, RegisterError> {
        let mut sb = ServiceBuilder::new(
            sd,
            Uuid::new_128(&ble_midi::uuid_le(&ble_midi::SERVICE_UUID)),
        )?;
        // Read returns an empty packet (required by the specification).
        let attr = Attribute::new(&[] as &[u8]).variable_len(ble_midi::MAX_PACKET_LEN as u16);
        let md = Metadata::new(Properties::new().read().write_without_response().notify());
        let ch = sb
            .add_characteristic(
                Uuid::new_128(&ble_midi::uuid_le(&ble_midi::CHARACTERISTIC_UUID)),
                attr,
                md,
            )?
            .build();
        let _ = sb.build();
        Ok(Self {
            io_handle: ch.value_handle,
            cccd_handle: ch.cccd_handle,
        })
    }
}

impl gatt_server::Server for MidiServer {
    type Event = bool;

    fn on_write(
        &self,
        _conn: &Connection,
        handle: u16,
        _op: WriteOp,
        _offset: usize,
        data: &[u8],
    ) -> Option<bool> {
        if handle == self.cccd_handle && !data.is_empty() {
            // Notifications on or off.
            return Some(data[0] & 0x01 != 0);
        }
        // MIDI in from the central (handle == io_handle): ignored.
        None
    }
}

/// The enabled SoftDevice. Tasks take it here because `&Softdevice` is
/// not `Send` (interrupt-executor spawners require it).
fn sd() -> &'static Softdevice {
    // SAFETY: only called from tasks spawned after `start` enabled the
    // SoftDevice; no `&mut Softdevice` exists after that.
    unsafe { Softdevice::steal() }
}

/// SoftDevice event loop. USB power events drive the software VBUS
/// detector used by embassy-usb.
#[embassy_executor::task]
pub async fn softdevice_task(vbus: &'static SoftwareVbusDetect) -> ! {
    let sd = sd();
    sd.run_with_callback(|e| match e {
        nrf_softdevice::SocEvent::PowerUsbDetected => vbus.detected(true),
        nrf_softdevice::SocEvent::PowerUsbRemoved => vbus.detected(false),
        nrf_softdevice::SocEvent::PowerUsbPowerReady => vbus.ready(),
        _ => {}
    })
    .await
}

/// Advertise, accept one central, stream instrument MIDI while it has
/// notifications enabled, and advertise again after it leaves.
#[embassy_executor::task]
pub async fn ble_midi_task(server: &'static MidiServer, name: &'static Name) {
    let sd = sd();
    let service_le = ble_midi::uuid_le(&ble_midi::SERVICE_UUID);
    // Flags + complete 128-bit service list (21 bytes) in the advertisement,
    // the name in the scan response: hosts filter on the service UUID.
    let adv: &'static LegacyAdvertisementPayload = ADV.init(
        LegacyAdvertisementBuilder::new()
            .flags(&[Flag::GeneralDiscovery, Flag::LE_Only])
            .services_128(ServiceList::Complete, &[service_le])
            .build(),
    );
    let scan: &'static LegacyAdvertisementPayload =
        SCAN.init(LegacyAdvertisementBuilder::new().full_name(name).build());
    let config = peripheral::Config {
        interval: ADV_INTERVAL,
        ..Default::default()
    };
    loop {
        BLE_STATE.store(BLE_ADVERTISING, Ordering::Relaxed);
        let adv_kind = peripheral::ConnectableAdvertisement::ScannableUndirected {
            adv_data: adv,
            scan_data: scan,
        };
        let conn = match peripheral::advertise_connectable(sd, adv_kind, &config).await {
            Ok(c) => c,
            Err(_) => {
                Timer::after_millis(500).await;
                continue;
            }
        };
        BLE_STATE.store(BLE_CONNECTED, Ordering::Relaxed);
        let _ = conn.set_conn_params(raw::ble_gap_conn_params_t {
            min_conn_interval: CONN_INTERVAL_MIN,
            max_conn_interval: CONN_INTERVAL_MAX,
            slave_latency: 0,
            conn_sup_timeout: SUPERVISION_TIMEOUT,
        });
        let gatt = gatt_server::run(&conn, server, |notify| {
            drain();
            BLE_STATE.store(
                if notify { BLE_STREAMING } else { BLE_CONNECTED },
                Ordering::Relaxed,
            );
            // Let the MIDI writer start (or stop) feeding BLE.
            MIDI_WAKE.signal(());
        });
        let _ = select(gatt, notifier(&conn, server)).await;
        BLE_STATE.store(BLE_ADVERTISING, Ordering::Relaxed);
        drain();
        MIDI_WAKE.signal(());
    }
}

fn drain() {
    while BLE_TX.try_receive().is_ok() {}
}

/// Send queued instrument messages as BLE-MIDI packets: one packet per
/// wake-up with everything that is pending and fits, one timestamp each.
async fn notifier(conn: &Connection, server: &MidiServer) -> ! {
    let mut held: Option<BleMessage> = None;
    loop {
        let first = match held.take() {
            Some(m) => m,
            None => BLE_TX.receive().await,
        };
        let max = (conn.att_mtu() as usize).saturating_sub(3);
        let mut p = ble_midi::Packet::new(Instant::now().as_millis() as u32, max);
        let _ = p.push(&first.bytes[..first.len as usize]);
        while let Ok(m) = BLE_TX.try_receive() {
            if !p.fits(m.len as usize) {
                held = Some(m);
                break;
            }
            let _ = p.push(&m.bytes[..m.len as usize]);
        }
        if p.is_empty() {
            continue;
        }
        // The SoftDevice queue holds a few notifications; when it is full,
        // wait one connection interval and try again (bounded).
        let mut tries = 0;
        loop {
            match gatt_server::notify_value(conn, server.io_handle, p.as_bytes()) {
                Ok(()) => {
                    BLE_PACKETS.fetch_add(1, Ordering::Relaxed);
                    break;
                }
                Err(NotifyValueError::Disconnected) => {
                    // gatt_server::run ends the connection loop.
                    Timer::after_millis(50).await;
                    break;
                }
                Err(_) if tries < 20 => {
                    tries += 1;
                    Timer::after_millis(5).await;
                }
                Err(_) => {
                    BLE_DROPPED.fetch_add(p.messages() as u32, Ordering::Relaxed);
                    break;
                }
            }
        }
    }
}

/// Request UF2 bootloader mode with the SoftDevice enabled (GPREGRET is
/// protected while it runs).
pub fn set_gpregret(value: u8) {
    // SAFETY: SoftDevice API with valid arguments.
    unsafe {
        raw::sd_power_gpregret_clr(0, 0xFF);
        raw::sd_power_gpregret_set(0, value as u32);
    }
}
