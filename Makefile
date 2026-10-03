program=out/a

# Emulator options
BUILD = hunk
MODEL = A500
FASTMEM = 0
CHIPMEM = 512
SLOWMEM = 512

BIN_DIR = ~/amiga/bin

# Binaries
CC = $(BIN_DIR)/bartman/opt/bin/m68k-amiga-elf-gcc
ELF2HUNK = $(BIN_DIR)/bartman/elf2hunk
VASM = $(BIN_DIR)/bartman/vasmm68k_mot
VLINK = $(BIN_DIR)/vlink
FSUAE = /Applications/FS-UAE.app/Contents/MacOS/fs-uae
KINGCON = $(BIN_DIR)/kingcon
AMIGECONV = $(BIN_DIR)/amigeconv
SALVADOR = $(BIN_DIR)/salvador
VASM_BB = $(BIN_DIR)/vasmm68k_mot
MKADF = $(BIN_DIR)/mkadf
ADFCREATE = $(BIN_DIR)/adfcreate
ADFINSTALL = $(BIN_DIR)/adfinst
ADFCOPY = $(BIN_DIR)/adfcopy

# Flags:
VASMFLAGS = -m68000 -x
VLINKFLAGS = -bamigahunk -Bstatic
BBFLAGS = -m68000 -x -opt-size -nosym -pic
CCFLAGS = -g -MP -MMD -m68000 -Ofast -nostdlib -Wextra -fomit-frame-pointer -fno-tree-loop-distribution -flto -fwhole-program
LDFLAGS = -Wl,--emit-relocs,-Ttext=0
FSUAEFLAGS = --floppy_drive_0_sounds=off --automatic_input_grab=0  --chip_memory=$(CHIPMEM) --fast_memory=$(FASTMEM) --slow_memory=$(SLOWMEM) --amiga_model=$(MODEL)

sources := main.asm
deps := $(addprefix out/, $(sources:.asm=.d)) # generated dependency makefiles

build_exe = $(program).$(BUILD).exe # unique exe filename for current build type
prog_exe = $(program).exe # generic name used in startup-sequence
# hunk build
hunk_exe = $(program).hunk.exe
hunk_debug = $(program).hunk-debug.exe
hunk_objects := $(addprefix out/, $(sources:.asm=.hunk))
# elf build
elf_exe = $(program).elf.exe
elf_linked = $(program).elf
elf_objects := $(addprefix out/, $(sources:.asm=.elf))

data = data/tables.i

.PHONY: all
all: $(build_exe)

.PHONY: run
run: $(build_exe)
	cp $< $(program).exe
	$(FSUAE) $(FSUAEFLAGS) --hard_drive_0=./out

# Bootblock: main.asm as a flat binary, packed with zx0, unpacked by boot.asm
.PHONY: packed
packed: $(program).bb
	@echo "unpacked: $$(wc -c < $(program).bin) bytes, packed: $$(wc -c < $(program).zx0) bytes, bootblock: $$(wc -c < $(program).bb)/1024 bytes"

.PHONY: runbb
runbb: $(program).adf
	$(FSUAE) $(FSUAEFLAGS) --floppy_drive_0=$<

# Copy the bootblock to a DOS ADF
$(program).adf: $(program)-bb.adf $(wildcard disk/*)
	-$(ADFCREATE) $@
	-$(ADFINSTALL) --install=$< $@
	-$(ADFCOPY) $@ disk/logo.txt /
	-$(ADFCOPY) $@ disk/C /
	-$(ADFCOPY) $@ disk/S /

# mkadf sets the checksum, but doesn't give us a DOS disk
$(program)-bb.adf: $(program).bb
	$(MKADF) $< > $@

$(program).bb: boot.asm $(program).zx0
	$(VASM_BB) $(BBFLAGS) -quiet -Fbin -o $@ $<
	@test $$(wc -c < $@) -le 1024 || (echo "bootblock is $$(wc -c < $@) bytes, over 1024"; rm $@; false)

$(program).zx0: $(program).bin
	$(SALVADOR) $< $@ > /dev/null

$(program).bin: $(sources) $(data)
	$(VASM_BB) $(BBFLAGS) -DBOOTBLOCK=1 -quiet -Fbin -o $@ $<
	@test $$(wc -c < $@) -le 65536 || (echo "$@ is over the 64K between the unpack address and the screen"; rm $@; false)

.PHONY: clean
clean:
	$(RM) out/*.*

# BUILD=hunk (vasm/vlink)
$(hunk_exe): $(hunk_objects) $(hunk_debug)
	$(VLINK) $(VLINKFLAGS) -s $(hunk_objects) -o $@
	cp $@ $(prog_exe)
$(hunk_debug): $(hunk_objects)
	$(VLINK) $(VLINKFLAGS) $(hunk_objects) -o $@
out/%.hunk : %.asm $(data)
	$(VASM) $(VASMFLAGS) -Fhunk -linedebug -o $@ $<

# BUILD=elf (GCC/Bartman)
$(elf_exe): $(elf_linked)
	$(ELF2HUNK) $< $@ -s
	cp $@ $(prog_exe)
$(elf_linked): $(elf_objects)
	$(CC) $(CCFLAGS) $(LDFLAGS) $(elf_objects) -o $@
out/%.elf : %.asm $(data)
	$(VASM) $(VASMFLAGS) -Felf -dwarf=3 -o $@ $<

-include $(deps)

out/%.d : %.asm
	$(VASM) $(VASMFLAGS) -quiet -dependall=make -o "$(patsubst %.d,%.\$$(BUILD),$@)" $(CURDIR)/$< > $@

data/tables.i: scripts/genTables.js
	node scripts/genTables.js > $@