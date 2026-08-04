# Target
TARGET := awboot
CROSS_COMPILE ?= arm-none-eabi-

# Output directory. Unset (the default) builds in tree, exactly as before; set
# O=<dir> to redirect every generated file there instead. Make keeps running
# from the source tree either way, so all source paths stay relative to it.
O ?=
OUT_DIR := $(or $(patsubst %/,%,$(O)),.)
# Path prefix for generated files: empty in tree, "<dir>/" out of tree.
OUT_PREFIX := $(patsubst ./%,%,$(OUT_DIR)/)

# Log level defaults to info
LOG_LEVEL ?= 30

SRCS := main.c board.c

# Build revision: <short commit hash>-{dirty,clean}, or UNKNOWN outside a git repo
GIT_HASH := $(shell git rev-parse --short HEAD 2>/dev/null)
ifeq ($(GIT_HASH),)
BUILD_REVISION := UNKNOWN
else
BUILD_REVISION := $(GIT_HASH)-$(if $(shell git status --porcelain 2>/dev/null),dirty,clean)
endif

INCLUDE_DIRS :=-I . -I include -I lib
LIB_DIR := -L ./
LIBS := -lgcc -nostdlib
DEFINES := -DLOG_LEVEL=$(LOG_LEVEL) -DBUILD_REVISION='"$(BUILD_REVISION)"'

# A literal '#' for use inside shell/grep patterns. Writing '\#' directly leaks
# the backslash through to the command, which GNU grep >= 3.12 warns about.
HASH := \#

include arch/arch.mk
include lib/lib.mk

CFLAGS += -mcpu=cortex-a7 -mthumb-interwork -mthumb -mno-unaligned-access -mfpu=neon-vfpv4 -mfloat-abi=hard
CFLAGS += -fno-tree-vectorize -ffreestanding -fno-builtin
CFLAGS += -ffunction-sections -fdata-sections -Os -std=c2x -Wall -Werror -Wno-unused-function $(INCLUDES) $(DEFINES)

ASFLAGS += $(CFLAGS)

# The SPL is a flat blob copied into SRAM and executed in place with no MMU, so
# its single PT_LOAD segment is legitimately RWX. Silence the binutils >= 2.39
# warning about that, but only if this linker understands the option.
RWX_FLAG := -Wl,--no-warn-rwx-segments
LDFLAGS += $(shell $(CC) $(RWX_FLAG) -nostdlib -x c /dev/null -o /dev/null >/dev/null 2>&1 && echo $(RWX_FLAG))

LDFLAGS += $(CFLAGS) $(LIBS) -Wl,--gc-sections

STRIP=$(CROSS_COMPILE)strip
CC=$(CROSS_COMPILE)gcc
SIZE=$(CROSS_COMPILE)size
OBJCOPY=$(CROSS_COMPILE)objcopy

HOSTCC=gcc
HOSTSTRIP=strip

MAKE=make

# The tools sub-make runs from tools/, so hand it absolute paths.
TOOLS_OUT_DIR := $(abspath $(OUT_DIR)/tools)
MKSUNXI := $(TOOLS_OUT_DIR)/mksunxi

SUPPORTED_VARIANTS := fel spi sdmmc emmc all
VARIANT ?= emmc
comma := ,
VARIANT_LIST := $(strip $(subst $(comma), ,$(VARIANT)))

ifneq ($(filter all,$(VARIANT_LIST)),)
BUILD_VARIANTS := $(SUPPORTED_VARIANTS)
else
BUILD_VARIANTS := $(VARIANT_LIST)
endif

INVALID_VARIANTS := $(filter-out $(SUPPORTED_VARIANTS),$(BUILD_VARIANTS))
ifneq ($(INVALID_VARIANTS),)
$(error Unknown VARIANT(s): $(INVALID_VARIANTS). Supported: $(SUPPORTED_VARIANTS))
endif

DTB ?= sun8i-t113-mangopi-dual.dtb
KERNEL ?= zImage

all: git begin build mkboot

begin:
	@echo "---------------------------------------------------------------"
	@echo -n "Compiler version: "
	@$(CC) -v 2>&1 | tail -1

build_revision:
	mkdir -p $(OUT_DIR)
	echo "$(BUILD_REVISION)" > $(OUT_PREFIX).build_revision

.PHONY: tools git begin build build_revision mkboot clean format
.SILENT:

git:
	if [ -d .git ]; then cp -f tools/hooks/* .git/hooks/; fi

build:: build_revision

# $(1): variant name
# $(2): key=value overrides applied to board.h
define REGISTER_VARIANT =

# Objects
$(1)_OBJ_DIR = $(OUT_PREFIX)build-$(1)
$(1)_BUILD_OBJS = $$(SRCS:%.c=$$($(1)_OBJ_DIR)/%.o)
$(1)_BUILD_OBJSA = $$(ASRCS:%.S=$$($(1)_OBJ_DIR)/%.o)
$(1)_OBJS = $$($(1)_BUILD_OBJSA) $$($(1)_BUILD_OBJS)

build:: $$($(1)_OBJ_DIR)/$$(TARGET)-boot.elf $$($(1)_OBJ_DIR)/$$(TARGET)-boot.bin $$($(1)_OBJ_DIR)/$$(TARGET)-fel.elf $$($(1)_OBJ_DIR)/$$(TARGET)-fel.bin

.PRECIOUS : $$($(1)_OBJS)
$$($(1)_OBJ_DIR)/$$(TARGET)-fel.elf: $$($(1)_OBJS)
	echo "  LD    $$@"
	$$(CC) -E -P -x c -D__RAM_BASE=0x00028000 ./arch/arm32/mach-t113s3/link.ld > $$($(1)_OBJ_DIR)/link-fel.ld
	$$(CC) $$^ -o $$@ $(LIB_DIR) -T $$($(1)_OBJ_DIR)/link-fel.ld $$(LDFLAGS) -Wl,-Map,$$($(1)_OBJ_DIR)/$$(TARGET)-fel.map

$$($(1)_OBJ_DIR)/$$(TARGET)-boot.elf: $$($(1)_OBJS)
	echo "  LD    $$@"
	$$(CC) -E -P -x c -D__RAM_BASE=0x00020000 ./arch/arm32/mach-t113s3/link.ld > $$($(1)_OBJ_DIR)/link-boot.ld
	$$(CC) $$^ -o $$@ $(LIB_DIR) -T $$($(1)_OBJ_DIR)/link-boot.ld $$(LDFLAGS) -Wl,-Map,$$($(1)_OBJ_DIR)/$$(TARGET)-boot.map

$$($(1)_OBJ_DIR)/$$(TARGET)-fel.bin: $$($(1)_OBJ_DIR)/$$(TARGET)-fel.elf
	@echo OBJCOPY $$@
	$$(OBJCOPY) -O binary $$< $$@

$$($(1)_OBJ_DIR)/$$(TARGET)-boot.bin: $$($(1)_OBJ_DIR)/$$(TARGET)-boot.elf
	@echo OBJCOPY $$@
	$$(OBJCOPY) -O binary $$< $$@

$$($(1)_OBJ_DIR)/%.o : %.c
	echo "  CC    $$@"
	mkdir -p $$(@D)
	$$(CC) $$(CFLAGS) -include $$($(1)_OBJ_DIR)/board.h $$(INCLUDE_DIRS) -c $$< -o $$@

$$($(1)_OBJ_DIR)/%.o : %.S
	echo "  CC    $$@"
	mkdir -p $$(@D)
	$$(CC) $$(ASFLAGS) $$(INCLUDE_DIRS) -c $$< -o $$@

$$($(1)_OBJS): $$($(1)_OBJ_DIR)/board.h

$$($(1)_OBJ_DIR)/board.h: board.h
	echo "  GEN   $$@"
	mkdir -p $$(@D)
	cp $$< $$@
	$(foreach opt,$(2),sed -i "s/^#define $(word 1,$(subst =, ,$(opt))).*/#define $(word 1,$(subst =, ,$(opt))) $(word 2,$(subst =, ,$(opt)))/" $$@;)

clean::
	rm -rf $$($(1)_OBJ_DIR)

-include $$(patsubst %.o,%.d,$$($(1)_OBJS))

endef

# build image with no storage support
ifneq ($(filter fel,$(BUILD_VARIANTS)),)
$(eval $(call REGISTER_VARIANT,fel,CONFIG_BOOT_SPINAND=0 CONFIG_BOOT_SDCARD=0 CONFIG_BOOT_MMC=0))
endif

ifneq ($(filter spi,$(BUILD_VARIANTS)),)
$(eval $(call REGISTER_VARIANT,spi,CONFIG_BOOT_SPINAND=1 CONFIG_BOOT_SDCARD=0 CONFIG_BOOT_MMC=0))
endif

# build sd/mmc only image without spi
ifneq ($(filter sdmmc,$(BUILD_VARIANTS)),)
$(eval $(call REGISTER_VARIANT,sdmmc,CONFIG_BOOT_SPINAND=0 CONFIG_BOOT_SDCARD=1 CONFIG_BOOT_MMC=1))
endif

# build emmc only image without spi
ifneq ($(filter emmc,$(BUILD_VARIANTS)),)
$(eval $(call REGISTER_VARIANT,emmc,CONFIG_BOOT_SPINAND=0 CONFIG_BOOT_SDCARD=0 CONFIG_BOOT_MMC=1))
endif

# build image with everything
ifneq ($(filter all,$(BUILD_VARIANTS)),)
$(eval $(call REGISTER_VARIANT,all,CONFIG_BOOT_SPINAND=1 CONFIG_BOOT_SDCARD=1 CONFIG_BOOT_MMC=1))
endif

clean::
	rm -f $(OUT_PREFIX)$(TARGET)-*.bin
	rm -f $(OUT_PREFIX)$(TARGET)-*.map
	rm -f $(OUT_PREFIX)*.img
	rm -f $(OUT_PREFIX)*.d
	rm -f $(OUT_PREFIX).build_revision
	$(MAKE) -C tools clean BUILD_DIR="$(TOOLS_OUT_DIR)/build" MKSUNXI="$(MKSUNXI)"

format:
	find . -iname "*.h" -o -iname "*.c" | xargs clang-format --verbose -i

tools:
	$(MAKE) -C tools all BUILD_DIR="$(TOOLS_OUT_DIR)/build" MKSUNXI="$(MKSUNXI)"


mkboot: build tools
ifneq ($(filter fel,$(BUILD_VARIANTS)),)
	echo "FEL:"
	$(SIZE) $(OUT_PREFIX)build-fel/$(TARGET)-boot.elf
	cp -f $(OUT_PREFIX)build-fel/$(TARGET)-boot.bin $(OUT_PREFIX)$(TARGET)-boot-fel.bin
	$(MKSUNXI) $(OUT_PREFIX)$(TARGET)-boot-fel.bin 512
endif

ifneq ($(filter spi,$(BUILD_VARIANTS)),)
	echo "SPI:"
	$(SIZE) $(OUT_PREFIX)build-spi/$(TARGET)-boot.elf
	cp -f $(OUT_PREFIX)build-spi/$(TARGET)-boot.bin $(OUT_PREFIX)$(TARGET)-boot-spi.bin
	cp -f $(OUT_PREFIX)build-spi/$(TARGET)-boot.bin $(OUT_PREFIX)$(TARGET)-boot-spi-4k.bin
	$(MKSUNXI) $(OUT_PREFIX)$(TARGET)-boot-spi.bin 8192
	$(MKSUNXI) $(OUT_PREFIX)$(TARGET)-boot-spi-4k.bin 8192 4096
endif

ifneq ($(filter sdmmc,$(BUILD_VARIANTS)),)
	echo "SDMMC:"
	$(SIZE) $(OUT_PREFIX)build-sdmmc/$(TARGET)-boot.elf
	cp -f $(OUT_PREFIX)build-sdmmc/$(TARGET)-boot.bin $(OUT_PREFIX)$(TARGET)-boot-sd.bin
	$(MKSUNXI) $(OUT_PREFIX)$(TARGET)-boot-sd.bin 512
endif

ifneq ($(filter emmc,$(BUILD_VARIANTS)),)
	echo "eMMC:"
	$(SIZE) $(OUT_PREFIX)build-emmc/$(TARGET)-boot.elf
	cp -f $(OUT_PREFIX)build-emmc/$(TARGET)-boot.bin $(OUT_PREFIX)$(TARGET)-boot-emmc.bin
	$(MKSUNXI) $(OUT_PREFIX)$(TARGET)-boot-emmc.bin 512
endif

ifneq ($(filter all,$(BUILD_VARIANTS)),)
	echo "ALL:"
	$(SIZE) $(OUT_PREFIX)build-all/$(TARGET)-boot.elf
	cp -f $(OUT_PREFIX)build-all/$(TARGET)-boot.bin $(OUT_PREFIX)$(TARGET)-boot-all.bin
	cp -f $(OUT_PREFIX)build-all/$(TARGET)-boot.bin $(OUT_PREFIX)$(TARGET)-fel.bin
	$(MKSUNXI) $(OUT_PREFIX)$(TARGET)-fel.bin 512
	$(MKSUNXI) $(OUT_PREFIX)$(TARGET)-boot-all.bin 8192
endif

$(OUT_PREFIX)spi-boot.img: mkboot
	rm -f $(OUT_PREFIX)spi-boot.img
	dd if=$(OUT_PREFIX)$(TARGET)-boot-spi.bin of=$(OUT_PREFIX)spi-boot.img bs=2k
	dd if=$(OUT_PREFIX)$(TARGET)-boot-spi.bin of=$(OUT_PREFIX)spi-boot.img bs=2k seek=32 # Second copy on page 32
	dd if=$(OUT_PREFIX)$(TARGET)-boot-spi.bin of=$(OUT_PREFIX)spi-boot.img bs=2k seek=64 # Third copy on page 64
	# dd if=linux/boot/$(DTB) of=$(OUT_PREFIX)spi-boot.img bs=2k seek=128 # DTB on page 128
	# dd if=linux/boot/$(KERNEL) of=$(OUT_PREFIX)spi-boot.img bs=2k seek=256 # Kernel on page 256

# Keep "make spi-boot.img" spelled the same way for out of tree builds.
ifneq ($(OUT_PREFIX),)
.PHONY: spi-boot.img
spi-boot.img: $(OUT_PREFIX)spi-boot.img
endif
