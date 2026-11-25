# Building CP/M for the Z80 Playground

## Assembler: Pasmo

The source code is written for **Pasmo**. This is evident from Pasmo-specific directives such as `.WARNING`/`.ERROR` inside `IF` blocks, the `MACRO` syntax in `tiny-basic.asm`, and the note "Use PASMO" in that file. Pasmo 0.5.3 (Ubuntu package) assembles the source code into `core.bin`, `bios.bin`, `bdos.bin`, `ccp.bin` and `z80ccp.bin`, all **byte-identical** to the files in `cpm v2.2 rel 1.10.zip`. `cpm.hex` (Intel HEX, 16-byte records, CRLF) differs from the one in that release, because the monitor has changed since then.

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
| `cpm.cfg`, `uart.cfg` | Configuration; hand-written, sources are in `cfg/` (taken from `cpm v2.2 rel 1.10.zip`) |
| `disk/CPM/` | All files for the `/CPM` folder on the USB stick, with upper-case names |

During the build, `core.asm` checks the size of the CORE and issues a warning (`.WARNING`) if it exceeds 3072 bytes.
