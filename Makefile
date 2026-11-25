# Build CP/M for the Z80 Playground with Pasmo (https://pasmo.speccy.org/).
#
#   sudo apt install pasmo      # Debian/Ubuntu, version 0.5.3 is known to work
#   make                        # results go to build/
#   make PASMO=/path/to/pasmo   # use a pasmo binary that is not on the PATH
#   make eeprom                 # write build/cpm.hex to the EEPROM with minipro
#
# Results:
#   build/cpm.hex     boot loader + monitor + Tiny BASIC for the EEPROM (Intel HEX)
#   build/cpm.symbols its symbol table, for debugging
#   build/disk/CPM/   files for the /CPM folder of the USB stick:
#                     CORE.BIN BIOS.BIN BDOS.BIN CCP.BIN Z80CCP.BIN CPM.CFG UART.CFG
#   build/disk/CPM/DISKS/A/
#                     CP/M programs from utils/ for drive A: (make utils):
#                     SD.COM CHK16550.COM

PASMO ?= pasmo
# Programming the EEPROM (an Atmel AT28C256 in DIP28) with a TL866II+ or
# similar programmer. minipro finds the programmer on USB by itself; the
# chip type must be given.
MINIPRO ?= minipro
EEPROM  ?= AT28C256
OUT   := build
DISK  := $(OUT)/disk/CPM
DISKA := $(DISK)/DISKS/A

# Every module includes several of the other files, so rebuild on any change.
SOURCES := $(wildcard *.asm *.ASM)

BINS := $(OUT)/core.bin $(OUT)/bios.bin $(OUT)/bdos.bin $(OUT)/ccp.bin $(OUT)/z80ccp.bin
CFGS := $(OUT)/cpm.cfg $(OUT)/uart.cfg

# Stand-alone CP/M programs (ORG 100H) in utils/. They include nothing from the
# system sources above, so they only depend on their own source file.
# utils/mload.asm is 8080 code that Pasmo cannot assemble; it is not built.
UTILS := $(OUT)/sd.com $(OUT)/chk16550.com

.PHONY: all disk utils eeprom clean

all: $(OUT)/cpm.hex $(BINS) $(CFGS) disk utils

$(OUT):
	mkdir -p $@

# Boot loader / monitor for the EEPROM, as Intel HEX.
# A plain binary image is built as well, for EEPROM programmers that want one,
# and the symbol table (label = address), which helps when debugging.
$(OUT)/cpm.hex: cpm.asm $(SOURCES) | $(OUT)
	$(PASMO) --hex cpm.asm $@ $(OUT)/cpm.symbols
	$(PASMO) cpm.asm $(OUT)/cpm.bin

$(OUT)/core.bin: core.asm $(SOURCES) | $(OUT)
	$(PASMO) core.asm $@

$(OUT)/bios.bin: bios.asm $(SOURCES) | $(OUT)
	$(PASMO) bios.asm $@

$(OUT)/bdos.bin: bdos.asm $(SOURCES) | $(OUT)
	$(PASMO) bdos.asm $@

$(OUT)/ccp.bin: ccp.asm $(SOURCES) | $(OUT)
	$(PASMO) ccp.asm $@

$(OUT)/z80ccp.bin: Z80CCP.ASM $(SOURCES) | $(OUT)
	$(PASMO) Z80CCP.ASM $@

# The configuration files are hand-written; they are only copied.
$(OUT)/%.cfg: cfg/%.cfg | $(OUT)
	cp $< $@

# Ready-to-copy folder for the USB stick, with the 8.3 names in upper case.
disk: $(BINS) $(CFGS)
	mkdir -p $(DISK)
	for f in $(notdir $(BINS) $(CFGS)); do \
	    cp $(OUT)/$$f $(DISK)/$$(echo $$f | tr a-z A-Z); \
	done

$(OUT)/%.com: utils/%.asm | $(OUT)
	$(PASMO) $< $@

# The programs go to drive A: on the USB stick, with the 8.3 names in upper case.
utils: $(UTILS)
	mkdir -p $(DISKA)
	for f in $(notdir $(UTILS)); do \
	    cp $(OUT)/$$f $(DISKA)/$$(echo $$f | tr a-z A-Z); \
	done

# Write the boot loader / monitor to the EEPROM, then verify it (minipro's default).
# -u disables the software data protection first, in case it was enabled before.
eeprom: $(OUT)/cpm.hex
	$(MINIPRO) -p $(EEPROM) -u -w $<

clean:
	rm -rf $(OUT)
