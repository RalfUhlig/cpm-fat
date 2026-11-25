# Building CP/M for the Z80 Playground

## Assembler: Pasmo

The source code is written for **Pasmo**. This is evident from Pasmo-specific directives such as `.WARNING`/`.ERROR` inside `IF` blocks, the `MACRO` syntax in `tiny-basic.asm`, and the note "Use PASMO" in that file. Pasmo 0.5.3 (Ubuntu package) assembles `bios.bin`, `bdos.bin`, `ccp.bin` and `z80ccp.bin` **byte-identical** to the files in `releases/cpm v2.2 rel 1.10.zip`. `core.bin` differs because of the changes to the CH376 driver (see below); the unmodified source code (tag `upstream-final`) also assembles it byte-identical. `cpm.hex` (Intel HEX, 16-byte records, CRLF) differs from the one in that release, because the monitor has changed since then.

Installation:

```sh
sudo apt install pasmo          # Debian/Ubuntu
```

On Windows, `pasmo.exe` is available as a ready-made program. vasm is not needed.

## Building

Run `make` in the project directory (where the `Makefile` and the `.asm` files are):

```sh
make                            # or: make PASMO=/path/to/pasmo
make clean
```

Output in `build/`:

| File | Purpose |
| --- | --- |
| `cpm.hex` | Boot loader, monitor and Tiny BASIC for the EEPROM (Intel HEX, starting at address 0000H) |
| `cpm.bin` | The same as a raw binary file, for programmers that require one |
| `core.bin`, `bios.bin`, `bdos.bin`, `ccp.bin`, `z80ccp.bin` | CP/M components, loaded from the USB stick |
| `cpm.cfg`, `uart.cfg` | Configuration; hand-written, sources are in `cfg/` (taken from `releases/cpm v2.2 rel 1.10.zip`) |
| `disk/CPM/` | All files for the `/CPM` folder on the USB stick, with upper-case names |
| `sd.com`, `chk16550.com` | CP/M programs from `utils/` |
| `disk/CPM/DISKS/A/` | The CP/M programs for drive A: on the USB stick, with upper-case names |

Size limits are checked during the build. The CORE must end below the variables at the end of RAM (FFAEH); if it exceeds this, Pasmo aborts with an error message. The old check against "3072 bytes" was too generous, because F600H–FFFFH is only 2560 bytes. The CORE currently ends at FF2AH.

## Programming the EEPROM

The boot loader, monitor and Tiny BASIC (`build/cpm.hex`) go into the EEPROM, an Atmel AT28C256 (DIP28). With a TL866II+ or another programmer supported by [minipro](https://gitlab.com/DavidGriffith/minipro):

```sh
make eeprom                     # builds cpm.hex if necessary, then writes and verifies it
make eeprom EEPROM=<type>       # a different chip type, as listed by: minipro -l
```

This runs `minipro -p AT28C256 -u -w build/cpm.hex`. minipro finds the programmer on USB by itself, but the chip type must be given. minipro erases the chip before writing, so it does not need to be empty. `-u` disables the chip's software data protection first, in case it was enabled before; it is not enabled again afterwards (that would need `-P`). After writing, minipro verifies the chip against the file. With minipro 0.7.3, the whole run takes less than 10 s.

## CP/M programs in `utils/`

`utils/` contains stand-alone CP/M programs (`ORG 100H`) that do not include any of the system sources. `make` builds them as well; `make utils` builds only them:

| Source | Program |
| --- | --- |
| `sd.asm` | `SD.COM`, Super Directory: sorted directory listing with file sizes |
| `chk16550.asm` | `CHK16550.COM`, checks which type of 16C550 UART is fitted |
| `mload.asm` | Multi-file HEX load utility; 8080 code that Pasmo cannot assemble, so it is not built |

`SD.COM` and `CHK16550.COM` are byte-identical to the files in `releases/master disk.zip` (`CPM/DISKS/A/`).

## Changes to the CH376 driver

Compared with the upstream code (tag `upstream-final`). The timings below apply to the Z80 Playground's 10 MHz CPU clock; the pause routines are plain delay loops, so they scale with the clock.

`memorystick_low_level.asm`:

- **`read_status_byte` now waits for the interrupt bit** (bit 7 of the status port, active low) before sending `GET_STATUS`. The timeout is about 5 s and is reported as `[USB INT TIMEOUT]`. Previously only the busy bit was taken into account.
- **New: `clear_pending_interrupt`.** Discards a pending interrupt event, e.g. `USB_INT_CONNECT` after plugging in the stick, after the mode change and before `DISK_CONNECT` and `DISK_MOUNT`.
- **`set_usb_host_mode`** sets mode 6 as before, but now reads the return byte `CMD_RET_SUCCESS` (51H) as per datasheet section 5.9, instead of immediately waiting for `USB_INT_CONNECT`. Whether a stick is connected is checked later by `connect_to_disk`.
- **`connect_to_usb_drive`** waits about 0.3 s after the mode change so that the stick can power up.
- **`connect_to_disk`** retries up to 10 times, about 0.16 s apart.
- **`mount_disk`** retries up to 25 times, about 0.16 s apart (datasheet section 5.17: some sticks only report success after several attempts). On status codes of 80H and above, and on `USB_INT_DISCONNECT`, it aborts immediately, because retrying would not help in that case.
- **Errors are now detected:** Previously the Z flag was always set after `GET_STATUS`, so errors during connecting and mounting were never noticed. Now `connect_to_disk` and `mount_disk` return Z on success and NZ otherwise, and print the status code in hex, e.g. `ERROR mounting USB Disk, status $A1`.
- **`configure_memorystick`** aborts on connection or mount errors and repeats the complete sequence (reset, host mode, connect, mount) up to 3 times. It now returns Z on success and NZ on failure.
- **`read_from_file`** reads the status after `BYTE_RD_GO` via `read_status_byte`, so it waits for the interrupt and clears it.

`memorystick.asm`, `monitor.asm`, `tiny-basic.asm`:

- Replaced inline sequences of `GET_STATUS` + `read_data_byte` after `BYTE_READ`/`BYTE_RD_GO` with `read_status_byte`.
- `dir_info_write`: After `DIR_INFO_SAVE`, the data port was read instead of the status, and the interrupt remained pending. Now `read_status_byte` is called.

`core.asm`: Size check against the real limit FFAEH, as `.ERROR`.

Unchanged and still byte-identical to `releases/cpm v2.2 rel 1.10.zip`: `bios.bin`, `bdos.bin`, `ccp.bin`, `z80ccp.bin`. The entries of the CORE jump table remain at the same offsets; only their jump targets have moved.

### Status codes when mounting

| Code | Meaning | Remedy |
| --- | --- | --- |
| 1FH | Stick not ready / USB error | Retried automatically; if it persists, the stick or the power supply is the cause |
| 82H | No disk | Check the stick |
| 84H | Sector size is not 512 bytes | Use a different medium |
| 92H | Partition type not supported | MBR, one primary partition, type 0x0C |
| A1H | Not FAT12/16/32 (e.g. exFAT/NTFS) | Format with FAT32 |

### Testing on hardware

The changes have been assembled and statically checked, but have **not yet been tested on real hardware**. Please first check with the known 120 MB stick that everything works as before: booting, `DIR`, loading and saving files, `REN`, Tiny BASIC `LOAD`/`SAVE`. Then test with the large sticks. If `[USB INT TIMEOUT]` appears, a command is not producing an interrupt; in that case, please report during which action it occurred.
