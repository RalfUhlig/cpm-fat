# Analysis: CH376 module and large USB flash drives

Analysis date: 2026-11-22, test results added 2026-11-25. The driver changes that resulted from it are described in [BUILD.md](../BUILD.md#changes-to-the-ch376-driver).

**Summary:** Larger USB flash drives (4–8 GB) did not work reliably with the Z80 Playground, while an old 120 MB stick did. The question was whether the CH376 is to blame, and whether the module should be replaced with a compatible design based on a different microcontroller. The analysis found that the chip does have real limitations, but 4–8 GB sticks are within its specification. Suspected causes were a weak driver and an electrically marginal interface (3.3 V against the 5 V bus), so the driver was fixed first.

**Test result:** An 8 GB stick formatted with MBR and FAT32 works with the fixed driver, with modules reporting v1, v2 and v3 (see [section 5](#5-test-results)). However, it also works with the original driver, including several cold starts. The original failures can therefore not be attributed to the driver. The most likely cause is the way the sticks were formatted (see [section 1](#1-does-the-chip-really-have-such-limitations)). The fixed driver is kept, because it handles the CH376 as the datasheet describes and reports errors with their status code. A replacement with a different MCU is not needed.

---

## 1. Does the chip really have such limitations?

According to the datasheet (`CH376DS1.PDF`), there are these fixed limits. The firmware is in mask ROM and cannot be updated.

| Limit | Source in the datasheet | Consequence |
| --- | --- | --- |
| FAT12/16/32 only, **no exFAT** | Chapter 2: "supports 32GB USB flash disk and SD card" | Sticks and cards of 64 GB and above (SDXC) come formatted with exFAT and are not recognised as they are |
| **512-byte sectors** only | Error code 84H `ERR_LARGE_SECTOR` | Rare, but some new media report 4K sectors |
| Only certain partition types | 92H `ERR_TYPE_ERROR` | GPT partitioning or an unusual MBR partition fails |
| Full speed only (12 Mbit/s), no hub | Chapter 2 | USB 3 sticks must fall back cleanly to full speed; most can, but some are fussy about it |

So for 4 and 8 GB sticks there is **no capacity limit**. New sticks often come with exFAT, GPT, or no partition table at all, which the CH376 may not accept. Format them with an MBR partition table, a single primary partition of type 0x0C and FAT32, e.g. on Linux:

```sh
sudo parted /dev/sdX mklabel msdos
sudo parted /dev/sdX mkpart primary fat32 1MiB 100%
sudo mkfs.vfat -F 32 /dev/sdX1
```

## 2. Is it driven incorrectly? In part, yes

The original driver `memorystick_low_level.asm` (tag `upstream-final`) has several weaknesses that could explain "old stick works, new one doesn't". The tests in section 5 did not confirm that they caused the failures, but they are deviations from the datasheet all the same:

1. **Mount errors are never detected.** In `connect_to_disk` and `mount_disk`, the result is checked with `ret z` after `GET_STATUS`. But the Z flag comes from `and %00010000` in `wait_til_not_busy`, and `in a,(n)` does not change any flags. Z is therefore always set. Whether the mount succeeds or not, the code simply carries on.
2. **`DISK_MOUNT` is not repeated.** The datasheet says explicitly in 5.17: *"Some USB storage devices may return USB_INT_SUCCESS after being initialized for several times."* Modern sticks in particular report "not ready" at first, right after power-up. WCH's own example code (not verified) waits about 200 ms before the mount and then tries the mount up to 100 times at 50 ms intervals. `configure_memorystick` only retries if setting the host mode fails, never after a failed mount.
3. **The host mode sequence is shortened.** According to 5.9, mode 5 should be set while no device is attached, and after plugging in, first mode 7 (USB bus reset), then mode 6. `set_usb_host_mode` sets mode 6 directly. The code then reads the status straight away and expects `USB_INT_CONNECT`. The return byte `CMD_RET_SUCCESS` (51H) is not read, and the stick gets no time to power up.
4. **Only the busy bit (bit 4) is waited for, never the interrupt bit (bit 7).** Commands marked "Generate interrupt" (`DISK_MOUNT`, `FILE_OPEN`, `BYTE_READ` …) signal their completion via INT, which can be read as bit 7 of the status port (chapter 6.2). That it still works with the 120 MB stick is probably because the chip only accepts the next command byte once the operation has finished. The datasheet does not confirm this, and it should not be relied on with slower media.

### What the fixed driver does

Points 1, 2 and 4 are fixed as recommended. Point 3 only in part: the driver still sets mode 6 directly, but now reads `CMD_RET_SUCCESS`, gives the stick time to power up, and then checks for a connected stick with `DISK_CONNECT`. The mode sequence 5→7→6 has not been implemented. If sticks still fail to connect, it is the next thing to try.

`DISK_MOUNT` is tried up to 25 times, about 0.16 s apart at 10 MHz. With about 4 s in total, that is in the same range as the 100 × 50 ms of the WCH example.

**Quickest diagnostic step:** The driver now prints the status codes of `DISK_CONNECT` and `DISK_MOUNT`. With a large stick, they show directly what the problem is (full table in [BUILD.md](../BUILD.md#status-codes-when-mounting)):

- 1FH: stick not ready yet, so retries are needed
- 84H or 92H: medium or partitioning
- A1H: formatting

## 3. Hardware: 3.3 V against 5 V, and the versions

- **The warning is justified.** The page [USB mit CH376-Modul](https://hc-ddr.hucki.net/wiki/doku.php/elektronik/ch376) (in German) points out that the module runs the CH376 at 3.3 V, which is not permitted when the peripherals run at 5 V, and recommends removing the AMS1117 voltage regulator on the module and bridging it. The datasheet confirms the problem: at 3.3 V supply, it allows at most VCC + 0.5 V, i.e. 3.8 V, on the pins (chapter 7.1). A 5 V Z80 bus then feeds current through the protection diodes into the 3.3 V rail. This can lead to sporadic malfunctions. In the other direction, the chip outputs about 2.8–3.3 V as a high level. That is enough for NMOS Z80s and 74LS/HCT, but marginal for 74HC inputs (VIH ≈ 3.5 V). The same page also asks why other projects (RookieDrive, RC2014) use these modules without modification.
- **Take care when converting to 5 V.** At 5 V, V3 (pin 9) must *not* be connected to VCC according to chapters 4 and 7.2; it then only gets a 0.01 µF capacitor. On a 3.3 V module, V3 is probably connected to VCC. Before bridging the AMS1117, measure whether pin 9 is connected to pin 28 or to the regulator output. If so, cut the connection. Otherwise V3 gets 5 V, which is outside the specification. The page mentioned above does not cover this.
- **Measure VBUS.** Measure the voltage at pin 1 of the USB socket with a large stick plugged in. It must be a clean 5 V or so. Larger sticks draw noticeably more current when plugged in, and long, thin supply wires make the voltage drop.
- **V1/V2/V3:** At start-up, the Z80 Playground prints `Found CH376S vX`. This is the value of `GET_IC_VER` (41H/42H/43H) masked to the lower bits, i.e. the revision of the chip firmware, not a board variant. Modules with V1, V2 and V3 chips have been seen with the same connector pinout. It is claimed that only V3 works properly with USB flash drives. The datasheet does not confirm this: the chip should handle all USB flash drives up to 32 GB, and no known bugs of particular firmware revisions are documented. The tests confirm the datasheet: modules reporting v1, v2 and v3 all work with an 8 GB FAT32 stick (section 5).
- **Pinout:** Similar modules exist with a different pinout of the 16-pin connector (see the page mentioned above). Check the pinout before swapping a module for one from another source.

## 4. Considered alternative: replacement with a different MCU

Not pursued, as large sticks work with the existing module once they are formatted correctly (section 5). This section is kept in case problems turn up with other sticks.

Towards the outside, a replacement would only need to reproduce the following: two I/O addresses (A0 selects command or data), the status port with bit 7 (INT) and bit 4 (busy), optionally INT#, and the commands that the CP/M code uses. These are 24: `CHECK_EXIST`, `GET_IC_VER`, `RESET_ALL`, `SET_USB_MODE`, `GET_STATUS`, `RD_USB_DATA0`, `WR_REQ_DATA`, `WR_OFS_DATA`, `SET_FILE_NAME`, `DISK_CONNECT/MOUNT`, `FILE_OPEN/ENUM_GO/CREATE/ERASE/CLOSE`, `DIR_INFO_READ/SAVE`, `BYTE_LOCATE/READ/RD_GO/WRITE/WR_GO` and `DIR_CREATE`. The status codes and protocol behaviour must match exactly.

### Suggestion: RP2040 or RP2350

- The built-in USB controller can act as host (full speed). TinyUSB host plus FatFs gives FAT12/16/32, **exFAT** and long file names. An SD card connected directly via SPI would also be possible.
- The PIO can meet the Z80 bus timing. At 10 MHz, an I/O read takes about 250 ns; the PIO can latch write accesses and present read data in time. If necessary, the /WAIT line helps.
- The RP2040 is not 5 V tolerant. Level shifters such as the 74LVC245 are therefore needed, which have 5 V tolerant inputs and TTL compatible outputs. The RP2350 is 5 V tolerant to a limited extent.
- The busy bit provides natural flow control: busy stays set until the MCU is done.

**The hardest part:** The CP/M code works with *raw 32-byte FAT directory entries*. This affects the directory listing via `FILE_OPEN "*"` and `FILE_ENUM_GO` (`memorystick.asm`, routine `dir`) and writing back via `DIR_INFO_SAVE` (`dir_info_write`). FatFs does not provide raw data. An emulator would therefore have to assemble these entries from FatFs data and translate changes into matching FatFs calls. That is doable, but detailed work.

No ready-made CH376-compatible replacement was found during research.

## 5. Test results

Tested on 2026-11-25 on a Z80 Playground (10 MHz). All modules are unmodified 3.3 V modules.

| Driver | USB stick | Layout | Module (start-up message) | Result |
| --- | --- | --- | --- | --- |
| fixed | 960 MB | MBR, type 0x0E, FAT16 | v3 | OK, full tests |
| fixed | 8 GB | MBR, type 0x0C, FAT32 | v3, v2 | OK, full tests |
| fixed | 8 GB | as above | v1 | OK, quick tests |
| original | 8 GB | as above | v2 | OK, also after several cold starts |

The full and quick tests are listed in [BUILD.md](../BUILD.md#testing-on-hardware). No error messages appeared, in particular no `[USB INT TIMEOUT]`, so every command used does produce the interrupt that the fixed driver waits for.

Conclusions:

- Neither the capacity (8 GB), nor FAT32, nor the firmware revision of the chip is a problem.
- The original driver also works with a correctly formatted 8 GB stick. The fixed driver was not needed for that, so the original failures were most likely due to the formatting of the sticks or to the particular sticks used. Those sticks were not available for the tests.
- The 3.3 V operation on the 5 V bus caused no visible problems in these tests. It is still outside the specification.

## Next steps

1. Fix the way the module is driven (software only): wait for bit 7, evaluate status codes correctly, wait after the mode change, retry `DISK_MOUNT` several times, print error codes. **Done and tested** (section 5).
2. Measure V3 and VBUS.
3. If a stick fails: first format it as described in section 1, then check the status code that the fixed driver prints. A replacement is only worthwhile if correctly formatted sticks still fail.

## References

- [CH376 datasheet part 1 (cpcwiki)](https://www.cpcwiki.eu/imgs/5/5b/Ch376ds1.pdf)
- [Homecomputer DDR: USB mit CH376-Modul](https://hc-ddr.hucki.net/wiki/doku.php/elektronik/ch376) (German)
- [rc2014-z80: USB disk interface](https://groups.google.com/g/rc2014-z80/c/Z6DCmyKAqn4)
- [Hackaday: USB Host on RP2040 with PIO](https://hackaday.com/2022/12/28/usb-host-on-rp2040-with-pio)
- [Adafruit Feather RP2040 USB Host](https://learn.adafruit.com/adafruit-feather-rp2040-with-usb-type-a-host/overview)
