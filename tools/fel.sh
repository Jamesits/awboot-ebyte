#!/bin/bash
set -Eeuo pipefail

# --- Helpers ---------------------------------------------------------------
MB(){ echo $(( $1 * 1024 * 1024 )); }
hex(){ printf "0x%08x" "$1"; }

# --- SoC / RAM -------------------------------------------------------------
BOOT_ADDR=0x00028000
SDRAM_BASE=$((0x40000000))
SDRAM_SIZE_MB=128
SDRAM_TOP=$(( SDRAM_BASE + $(MB ${SDRAM_SIZE_MB}) ))

# PSCI keeps the top of DRAM and awboot hides it from the kernel, so nothing
# may be placed there. CONFIG_PSCI_DRAM_RESERVE in board.h.
PSCI_RESERVE=$((0x10000))

# --- Final layout (host-owned) --------------------------------------------
# This mirrors the DRAM load map in board.h. awboot takes the addresses from
# the mailboxes rather than from that map when it is booted over FEL, so the
# two are not forced to agree - but keeping them identical means a board booted
# from a card and one pushed over FEL put everything in the same place, and the
# guard sizes only have to be reasoned about once.
#
#   KERN_ADDR      0x42000000  zImage    + KERNEL_GUARD_MB
#   MAILBOX_BASE   0x43100000  mailboxes + MAILBOX_SIZE_MB
#   DTB_ADDR       0x43200000  DTB       + DTB_GUARD_MB
#   INITRD_ADDR    0x43300000  initrd, growing upwards
#   SDRAM_TOP - PSCI_RESERVE   ceiling
#
# The initrd sits last and grows up, so its address does not depend on its
# size - the same reason board.h orders it that way.
KERN_ADDR=$(( SDRAM_BASE + $(MB 32) ))                    # 0x42000000
KERNEL_GUARD_MB=17
MAILBOX_BASE=$((0x43100000))                              # CONFIG_FEL_MAILBOX_BASE
MAILBOX_SIZE_MB=1
DTB_ADDR=$(( MAILBOX_BASE + $(MB ${MAILBOX_SIZE_MB}) ))   # 0x43200000
DTB_GUARD_MB=1
INITRD_ADDR=$(( DTB_ADDR + $(MB ${DTB_GUARD_MB}) ))       # 0x43300000
INITRD_CEILING=$(( SDRAM_TOP - PSCI_RESERVE ))

# awboot refuses anything larger. CONFIG_INITRAMFS_MAX_SIZE in board.h.
INITRAMFS_MAX=$(MB 25)

# awboot warns if the initrd does not start on this boundary.
# CONFIG_INITRD_ALIGNMENT in board.h.
INITRD_ALIGNMENT=64

# The shell counterpart of the _Static_assert in board.h: the mailbox address
# is fixed by this script, and the kernel guard is sized to stop beneath it.
if (( KERN_ADDR + $(MB ${KERNEL_GUARD_MB}) != MAILBOX_BASE )); then
  echo "ERR: kernel guard ends at $(hex $(( KERN_ADDR + $(MB ${KERNEL_GUARD_MB}) ))), not at the mailbox $(hex ${MAILBOX_BASE})" >&2
  exit 1
fi
if (( INITRD_ADDR % INITRD_ALIGNMENT != 0 )); then
  echo "ERR: initrd address $(hex ${INITRD_ADDR}) is not ${INITRD_ALIGNMENT}-byte aligned" >&2
  exit 1
fi

# --- Mailboxes (awboot reads these; keep in sync with board.h) ------------
MAIL_INITRD_SIZE=$(( MAILBOX_BASE + 0x0 ))   # uint32
MAIL_INITRD_START=$(( MAILBOX_BASE + 0x4 ))  # uint32
MAIL_DTB_ADDR=$(( MAILBOX_BASE + 0x8 ))      # uint32
MAIL_KERNEL_ADDR=$(( MAILBOX_BASE + 0xC ))   # uint32 (optional but handy)

# --- Paths -----------------------------------------------------------------
if (( $# < 2 || $# > 3 )); then
  echo "Usage: $(basename "$0") <kernel> <dtb> [initrd]" >&2
  exit 1
fi

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# An out-of-tree build (make O=...) puts this elsewhere; point AWBOOT_BIN at it,
# e.g. AWBOOT_BIN=../../out/awboot/build-fel/awboot-fel.bin
AWBOOT_BIN="${AWBOOT_BIN:-${SCRIPT_DIR}/../build-fel/awboot-fel.bin}"
KERNEL_FILE=${1}
DTB_FILE=${2}
INITRD_FILE=${3:-}

if [[ ! -f "${AWBOOT_BIN}" ]]; then
  echo "ERR: missing awboot binary at ${AWBOOT_BIN}" >&2
  exit 1
fi
if [[ ! -f "${KERNEL_FILE}" ]]; then
  echo "ERR: kernel file not found: ${KERNEL_FILE}" >&2
  exit 1
fi
if [[ ! -f "${DTB_FILE}" ]]; then
  echo "ERR: DTB file not found: ${DTB_FILE}" >&2
  exit 1
fi

# --- Sizes -----------------------------------------------------------------
KERNEL_SIZE_DEC=$(stat -c "%s" "${KERNEL_FILE}")
DTB_SIZE_DEC=$(stat -c "%s" "${DTB_FILE}")
INITRD_PRESENT=false
INITRD_SIZE_DEC=0
if [[ -n "${INITRD_FILE}" ]]; then
  if [[ ! -f "${INITRD_FILE}" ]]; then
    echo "ERR: initrd file not found: ${INITRD_FILE}" >&2
    exit 1
  fi
  INITRD_PRESENT=true
  INITRD_SIZE_DEC=$(stat -c "%s" "${INITRD_FILE}")
fi

# --- Compute final addresses ----------------------------------------------
# The start is fixed by the map; only the end moves with the file. A zero start
# is what tells awboot there is no initrd.
INITRD_START=0
INITRD_END=0
if ${INITRD_PRESENT}; then
  INITRD_START=${INITRD_ADDR}
  INITRD_END=$(( INITRD_START + INITRD_SIZE_DEC ))
fi

# --- Sanity checks ---------------------------------------------------------
# Each image has to fit in the guard the map gives it, or it runs into whatever
# is placed above.
if (( KERNEL_SIZE_DEC > $(MB ${KERNEL_GUARD_MB}) )); then
  echo "ERR: kernel (${KERNEL_SIZE_DEC} bytes) exceeds the ${KERNEL_GUARD_MB} MiB guard below the mailbox" >&2
  exit 1
fi
if (( DTB_SIZE_DEC > $(MB ${DTB_GUARD_MB}) )); then
  echo "ERR: DTB (${DTB_SIZE_DEC} bytes) exceeds its ${DTB_GUARD_MB} MiB guard" >&2
  exit 1
fi
if ${INITRD_PRESENT}; then
  if (( INITRD_SIZE_DEC > INITRAMFS_MAX )); then
    echo "ERR: initrd (${INITRD_SIZE_DEC} bytes) exceeds awboot's CONFIG_INITRAMFS_MAX_SIZE (${INITRAMFS_MAX} bytes)" >&2
    exit 1
  fi
  if (( INITRD_END > INITRD_CEILING )); then
    echo "ERR: initrd ends at $(hex ${INITRD_END}), above the PSCI reserve at $(hex ${INITRD_CEILING})" >&2
    exit 1
  fi
fi

# --- Map preview -----------------------------------------------------------
echo "Final (host-decided) memory map:"
printf "  zImage   @ %s (%s, %d bytes)\n"  "$(hex ${KERN_ADDR})" "$(basename "${KERNEL_FILE}")" ${KERNEL_SIZE_DEC}
printf "  mailbox  @ %s (%d MiB reserved)\n" "$(hex ${MAILBOX_BASE})" ${MAILBOX_SIZE_MB}
printf "  DTB      @ %s (%s, %d bytes)\n"  "$(hex ${DTB_ADDR})"  "$(basename "${DTB_FILE}")"   ${DTB_SIZE_DEC}
if ${INITRD_PRESENT}; then
  printf "  initrd   @ %s .. %s (%d bytes, %d MiB spare below %s)\n" \
         "$(hex ${INITRD_START})" "$(hex ${INITRD_END})" ${INITRD_SIZE_DEC} \
         $(( (INITRD_CEILING - INITRD_END) / 1024 / 1024 )) "$(hex ${INITRD_CEILING})"
else
  echo "  initrd   disabled"
fi
printf "  mailboxes: initrd_size=%s initrd_start=%s dtb_addr=%s kernel_addr=%s\n" \
       "$(hex ${MAIL_INITRD_SIZE})" "$(hex ${MAIL_INITRD_START})" "$(hex ${MAIL_DTB_ADDR})" "$(hex ${MAIL_KERNEL_ADDR})"

# --- Push over FEL ---------------------------------------------------------
xfel ddr   t113-s3
xfel write ${BOOT_ADDR}                        "${AWBOOT_BIN}"
xfel write 0x$(printf %x ${KERN_ADDR})         "${KERNEL_FILE}"
xfel write 0x$(printf %x ${DTB_ADDR})          "${DTB_FILE}"
if ${INITRD_PRESENT}; then
  xfel write 0x$(printf %x ${INITRD_START})      "${INITRD_FILE}"
fi

# Mailboxes (tell awboot exactly where things are)
xfel write32 0x$(printf %x ${MAIL_INITRD_SIZE})  0x$(printf %x ${INITRD_SIZE_DEC})
xfel write32 0x$(printf %x ${MAIL_INITRD_START}) 0x$(printf %x ${INITRD_START})
xfel write32 0x$(printf %x ${MAIL_DTB_ADDR})     0x$(printf %x ${DTB_ADDR})
xfel write32 0x$(printf %x ${MAIL_KERNEL_ADDR})  0x$(printf %x ${KERN_ADDR})

# Optional verification (uncomment to debug)
# TMP="$(mktemp)"
# xfel read  0x$(printf %x ${DTB_ADDR})     ${DTB_SIZE_DEC}     "${TMP}"; cmp -n ${DTB_SIZE_DEC}     "${TMP}" "${DTB_FILE}"     || { echo "DTB mismatch"; exit 1; }
# xfel read  0x$(printf %x ${KERN_ADDR})    ${KERNEL_SIZE_DEC}  "${TMP}"; cmp -n ${KERNEL_SIZE_DEC}  "${TMP}" "${KERNEL_FILE}"  || { echo "Kernel mismatch"; exit 1; }
# xfel read  0x$(printf %x ${INITRD_START}) ${INITRD_SIZE_DEC}  "${TMP}"; cmp -n ${INITRD_SIZE_DEC}  "${TMP}" "${INITRD_FILE}"  || { echo "Initrd mismatch"; exit 1; }

xfel exec    ${BOOT_ADDR}
