/* Seeed XIAO nRF52840 Sense, application image for the Adafruit-derived
 * UF2 bootloader with SoftDevice S140 7.3.0 already in flash.
 *
 *   0x00000000  MBR + SoftDevice S140 v7      (156 KiB, never written)
 *   0x00027000  Application (this image)      (788 KiB)
 *   0x000EC000  Storage (reserved, unused)    (32 KiB)
 *   0x000F4000  UF2 bootloader + settings     (48 KiB, never written)
 *
 * Source: Zephyr dts/vendor/nordic/nrf52840_partition_uf2_sdv7.dtsi used by
 * the xiao_ble board (and therefore by the Omi DevKit firmware). The
 * SoftDevice is never enabled by this firmware, so RAM is ours except the
 * first 8 bytes the MBR keeps for interrupt forwarding.
 * tools/xiao_uf2.py refuses images outside 0x27000..0xEC000.
 */
MEMORY
{
  FLASH : ORIGIN = 0x00027000, LENGTH = 0xC5000
  RAM   : ORIGIN = 0x20000008, LENGTH = 256K - 8
}
