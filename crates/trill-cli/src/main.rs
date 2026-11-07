// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nymble (https://github.com/nymble)

//! `trill`: Linux bring-up tool for Trill sensors on an i2c-dev bus.

use clap::{Parser, Subcommand, ValueEnum};
use std::process::ExitCode;
use trill_driver::{noise_threshold_counts, Config, Device, Mode, Speed};

#[derive(Parser, Debug)]
#[command(
    version,
    about = "Identify and read a Bela Trill sensor over Linux i2c-dev"
)]
struct Cli {
    /// I2C character device.
    #[arg(long, default_value = "/dev/i2c-1", global = true)]
    bus: String,
    /// 7-bit I2C address, hex (0x48) or decimal (72).
    #[arg(long, default_value = "0x48", value_parser = parse_address, global = true)]
    address: u8,
    /// Expected device type; `any` accepts whatever answers Identify.
    #[arg(long, value_enum, default_value_t = Expect::Flex, global = true)]
    device: Expect,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Send Identify and print device type and firmware revision.
    Identify,
    /// Configure the sensor and stream readings until Ctrl-C or --count.
    Read(ReadArgs),
}

#[derive(clap::Args, Debug)]
struct ReadArgs {
    /// Acquisition mode. Default: centroid (Craft: diff).
    #[arg(long, value_enum)]
    mode: Option<CliMode>,
    /// Prescaler index 0..=8. Default per device (Flex: 4).
    #[arg(long, value_parser = clap::value_parser!(u8).range(0..=8))]
    prescaler: Option<u8>,
    /// Scan resolution in bits, 9..=16.
    #[arg(long, default_value_t = 12, value_parser = clap::value_parser!(u8).range(9..=16))]
    bits: u8,
    /// Scan speed 0 (ultra fast) ..= 3 (slow).
    #[arg(long, default_value_t = 0, value_parser = clap::value_parser!(u8).range(0..=3))]
    speed: u8,
    /// Noise threshold as a fraction of full scale (Flex default 0.03).
    #[arg(long)]
    threshold: Option<f32>,
    /// Delay between reads in milliseconds.
    #[arg(long, default_value_t = 20)]
    interval_ms: u64,
    /// Stop after this many frames (default: run until Ctrl-C).
    #[arg(long)]
    count: Option<u64>,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Expect {
    Any,
    Bar,
    Square,
    Craft,
    Ring,
    Hex,
    Flex,
}

impl Expect {
    fn device(self) -> Option<Device> {
        match self {
            Expect::Any => None,
            Expect::Bar => Some(Device::Bar),
            Expect::Square => Some(Device::Square),
            Expect::Craft => Some(Device::Craft),
            Expect::Ring => Some(Device::Ring),
            Expect::Hex => Some(Device::Hex),
            Expect::Flex => Some(Device::Flex),
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum CliMode {
    Centroid,
    Raw,
    Baseline,
    Diff,
}

impl From<CliMode> for Mode {
    fn from(m: CliMode) -> Self {
        match m {
            CliMode::Centroid => Mode::Centroid,
            CliMode::Raw => Mode::Raw,
            CliMode::Baseline => Mode::Baseline,
            CliMode::Diff => Mode::Diff,
        }
    }
}

fn parse_address(s: &str) -> Result<u8, String> {
    let v = if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        u8::from_str_radix(hex, 16)
    } else {
        s.parse::<u8>()
    }
    .map_err(|_| format!("`{s}` is not a valid address"))?;
    if !(0x08..=0x77).contains(&v) {
        return Err(format!("0x{v:02X} is outside the 7-bit range 0x08..=0x77"));
    }
    Ok(v)
}

fn speed(n: u8) -> Speed {
    match n {
        0 => Speed::UltraFast,
        1 => Speed::Fast,
        2 => Speed::Normal,
        _ => Speed::Slow,
    }
}

/// Build the configuration for a detected device from CLI arguments.
fn build_config(device: Device, args: &ReadArgs) -> Config {
    let mut cfg = Config::for_device(device);
    if let Some(m) = args.mode {
        cfg.mode = m.into();
    }
    if let Some(p) = args.prescaler {
        cfg.prescaler = p;
    }
    cfg.bits = args.bits;
    cfg.speed = speed(args.speed);
    let fraction = args.threshold.unwrap_or(if device == Device::Flex {
        0.03
    } else {
        40.0 / 4096.0
    });
    cfg.noise_threshold = noise_threshold_counts(fraction, args.bits);
    cfg
}

#[cfg(target_os = "linux")]
mod run {
    use super::*;
    use linux_embedded_hal::{Delay, I2cdev};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::Duration;
    use trill_driver::Trill;

    pub fn main(cli: Cli) -> Result<(), String> {
        let i2c = I2cdev::new(&cli.bus).map_err(|e| {
            format!(
                "cannot open {}: {e}. Is I2C enabled (dtparam=i2c_arm=on) and are you in the i2c group?",
                cli.bus
            )
        })?;
        let mut delay = Delay;
        let mut trill = Trill::new(i2c, cli.address);
        let ctx = |e: trill_driver::Error<_>| format!("{} at 0x{:02X}: {e}", cli.bus, cli.address);
        let id = trill.identify(&mut delay).map_err(ctx)?;
        if let Some(expected) = cli.device.device() {
            if expected != id.device {
                return Err(format!(
                    "expected Trill {expected}, found Trill {} (use --device any to accept it)",
                    id.device
                ));
            }
        }
        println!(
            "Trill {} at 0x{:02X} on {}, firmware {}",
            id.device, cli.address, cli.bus, id.firmware
        );
        let args = match cli.command {
            Command::Identify => return Ok(()),
            Command::Read(a) => a,
        };

        let cfg = build_config(id.device, &args);
        trill.init(&mut delay, Some(id.device), &cfg).map_err(ctx)?;
        println!(
            "mode={} prescaler={} speed={} bits={} noise_threshold={} (keep hands off during baseline)",
            cfg.mode, cfg.prescaler, args.speed, cfg.bits, cfg.noise_threshold
        );

        let stop = Arc::new(AtomicBool::new(false));
        {
            let stop = stop.clone();
            ctrlc::set_handler(move || stop.store(true, Ordering::SeqCst))
                .map_err(|e| format!("cannot install Ctrl-C handler: {e}"))?;
        }

        let mut frame: u64 = 0;
        while !stop.load(Ordering::SeqCst) && args.count.is_none_or(|c| frame < c) {
            if cfg.mode == Mode::Centroid {
                let t = trill.read_touches(&mut delay).map_err(ctx)?;
                let mut line = format!("{frame} touches={}", t.len());
                for (i, touch) in t.iter().enumerate() {
                    match touch.normalised(id.device) {
                        Some(p) => line.push_str(&format!(
                            " [{i}] pos={p:.4} loc={} size={}",
                            touch.location, touch.size
                        )),
                        None => line.push_str(&format!(
                            " [{i}] loc={} size={}",
                            touch.location, touch.size
                        )),
                    }
                }
                println!("{line}");
            } else {
                let ch = trill.read_channels(&mut delay).map_err(ctx)?;
                let values: Vec<String> = ch.as_slice().iter().map(|v| v.to_string()).collect();
                println!("{frame} {}", values.join(" "));
            }
            frame += 1;
            std::thread::sleep(Duration::from_millis(args.interval_ms));
        }
        eprintln!("stopped after {frame} frames");
        Ok(())
    }
}

#[cfg(not(target_os = "linux"))]
mod run {
    use super::*;
    pub fn main(_cli: Cli) -> Result<(), String> {
        Err("the trill CLI needs Linux i2c-dev; build it for a Linux target".into())
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run::main(cli) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses() {
        assert_eq!(parse_address("0x48"), Ok(0x48));
        assert_eq!(parse_address("72"), Ok(0x48));
        assert!(parse_address("0x80").is_err());
        assert!(parse_address("zz").is_err());
    }

    #[test]
    fn flex_defaults_match_reference_library() {
        let cli = Cli::parse_from(["trill", "read"]);
        let Command::Read(args) = cli.command else {
            panic!()
        };
        let cfg = build_config(Device::Flex, &args);
        assert_eq!(cfg.mode, Mode::Centroid);
        assert_eq!(cfg.prescaler, 4);
        assert_eq!(cfg.bits, 12);
        assert_eq!(cfg.noise_threshold, 123);
        assert_eq!(cli.address, 0x48);
        assert_eq!(cli.bus, "/dev/i2c-1");
    }

    #[test]
    fn custom_sensor_diff_mode() {
        let cli = Cli::parse_from(["trill", "--address", "0x49", "read", "--mode", "diff"]);
        let Command::Read(args) = cli.command else {
            panic!()
        };
        assert_eq!(build_config(Device::Flex, &args).mode, Mode::Diff);
    }

    #[test]
    fn clap_definition_is_valid() {
        use clap::CommandFactory;
        Cli::command().debug_assert();
    }
}
