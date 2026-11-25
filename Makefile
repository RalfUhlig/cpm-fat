# Build CP/M for the Z80 Playground with Pasmo (https://pasmo.speccy.org/).
#
#   sudo apt install pasmo      # Debian/Ubuntu, version 0.5.3 is known to work
#   make                        # results go to build/
#   make PASMO=/path/to/pasmo   # use a pasmo binary that is not on the PATH
#
# Results:
#   build/cpm.hex     boot loader + monitor + Tiny BASIC for the EEPROM (Intel HEX)
#   build/disk/CPM/   files for the /CPM folder of the USB stick:
#                     CORE.BIN BIOS.BIN BDOS.BIN CCP.BIN Z80CCP.BIN CPM.CFG UART.CFG

PASMO ?= pasmo
OUT   := build
DISK  := $(OUT)/disk/CPM

# Every module includes several of the other files, so rebuild on any change.
SOURCES := $(wildcard *.asm *.ASM)

BINS := $(OUT)/core.bin $(OUT)/bios.bin $(OUT)/bdos.bin $(OUT)/ccp.bin $(OUT)/z80ccp.bin
CFGS := $(OUT)/cpm.cfg $(OUT)/uart.cfg

.PHONY: all disk clean

all: $(OUT)/cpm.hex $(BINS) $(CFGS) disk

$(OUT):
	mkdir -p $@

# Boot loader / monitor for the EEPROM, as Intel HEX.
# A plain binary image is built as well, for EEPROM programmers that want one.
$(OUT)/cpm.hex: cpm.asm $(SOURCES) | $(OUT)
	$(PASMO) --hex cpm.asm $@
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

clean:
	rm -rf $(OUT)
