// SPDX-License-Identifier: GPL-3.0-only
//! embedded-hal I²C adapter with a per-transaction timeout, so a stuck bus
//! or missing pull-ups produce an error instead of hanging a task.

use embassy_nrf::twim::{self, Twim};
use embassy_time::Duration;
use embedded_hal::i2c::{ErrorKind, ErrorType, I2c, NoAcknowledgeSource, Operation};

/// Error wrapper implementing `embedded_hal::i2c::Error`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BusError(pub twim::Error);

impl embedded_hal::i2c::Error for BusError {
    fn kind(&self) -> ErrorKind {
        match self.0 {
            twim::Error::AddressNack => ErrorKind::NoAcknowledge(NoAcknowledgeSource::Address),
            twim::Error::DataNack => ErrorKind::NoAcknowledge(NoAcknowledgeSource::Data),
            twim::Error::Overrun => ErrorKind::Overrun,
            _ => ErrorKind::Other,
        }
    }
}

/// Borrowing adapter: `Twim` + timeout.
pub struct TimeoutI2c<'a, 'd> {
    bus: &'a mut Twim<'d>,
    timeout: Duration,
}

impl<'a, 'd> TimeoutI2c<'a, 'd> {
    /// Wrap a bus.
    pub fn new(bus: &'a mut Twim<'d>, timeout: Duration) -> Self {
        Self { bus, timeout }
    }
}

impl ErrorType for TimeoutI2c<'_, '_> {
    type Error = BusError;
}

impl I2c for TimeoutI2c<'_, '_> {
    fn transaction(
        &mut self,
        address: u8,
        operations: &mut [Operation<'_>],
    ) -> Result<(), Self::Error> {
        self.bus
            .blocking_transaction_timeout(address, operations, self.timeout)
            .map_err(BusError)
    }
}
