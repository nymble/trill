# lsm6ds3trc

`no_std` driver for the ST LSM6DS3TR-C accelerometer + gyroscope over I²C (`embedded-hal` 1.0), written from the ST datasheet (DocID030071 Rev 3). This is the IMU on the Seeed XIAO nRF52840 Sense (address 0x6A, internal bus P0.07/P0.27, power P1.08, INT1 P0.11).

Covers identification, software reset, ODR and full scale for both sensors, block data update, accelerometer data-ready on INT1, status, and a single 14-byte burst read of temperature + gyro + accel with scaling to g and dps. Default: 416 Hz, ±4 g, ±1000 dps.

Tested with mock I²C byte sequences (`cargo test -p lsm6ds3trc`). Not yet run against a sensor.
