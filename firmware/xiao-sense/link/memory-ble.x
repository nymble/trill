/* Seeed XIAO nRF52840 Sense, application image with MIDI over Bluetooth LE
 * (feature `ble-midi`). Same flash layout as link/memory.x; nothing outside the
 * application range is ever written:
 *
 *   0x00000000  MBR + SoftDevice S140 v7      (156 KiB, never written)
 *   0x00027000  Application (this image)      (788 KiB)
 *   0x000EC000  Storage                       (32 KiB; the ble-midi build keeps
 *               its Bluetooth settings in the first 4 KiB page, 0xEC000)
 *   0x000F4000  UF2 bootloader + settings     (48 KiB, never written)
 *
 * This build enables the SoftDevice at run time, so RAM from 0x20000000
 * to 0x20008000 belongs to it (one peripheral link, 131-byte ATT MTU,
 * 1 KiB attribute table needs well under 32 KiB; the margin keeps a
 * configuration change from failing at boot).
 * tools/xiao_uf2.py refuses images outside 0x27000..0xEC000.
 */
MEMORY
{
  FLASH : ORIGIN = 0x00027000, LENGTH = 0xC5000
  RAM   : ORIGIN = 0x20008000, LENGTH = 256K - 0x8000
}
