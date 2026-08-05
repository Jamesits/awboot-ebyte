#ifndef __BOARD_H__
#define __BOARD_H__

#include "dram.h"
#include "sunxi_spi.h"
#include "sunxi_usart.h"
#include "sunxi_sdhci.h"

#ifndef CONFIG_KERNEL_FILENAME
#define CONFIG_KERNEL_FILENAME "zImage"
#endif
#ifndef CONFIG_DTB_FILENAME
#define CONFIG_DTB_FILENAME	   "sun8i-t113-mangopi-dual.dtb"
#endif
#ifndef CONFIG_INITRD_FILENAME
#define CONFIG_INITRD_FILENAME ""
#endif
#ifndef CONFIG_MMC_ENABLE_RSTN
#define CONFIG_MMC_ENABLE_RSTN 0
#endif

#define RTC_BKP_REG(n) *((uint32_t *)((0x07090100) + (n * 4)))

#define MB(x) ((uint32_t)(x) * 1024U * 1024U)

// DRAM load map, bottom-up. Every object is streamed into place before its
// size is known, so each gets a guard region big enough for anything this
// board will boot and the next one starts where that guard ends:
//
//   SDRAM_BASE                            the kernel decompresses down to here
//   CONFIG_KERNEL_LOAD_ADDR    0x42000000 zImage    + CONFIG_KERNEL_GUARD_SIZE
//   CONFIG_FEL_MAILBOX_BASE    0x43100000 mailbox   + CONFIG_FEL_MAILBOX_SIZE
//   CONFIG_DTB_LOAD_ADDR       0x43200000 DTB       + CONFIG_DTB_GUARD_SIZE
//   CONFIG_INITRD_LOAD_ADDR    0x43300000 initrd, growing upwards
//   dram_top - CONFIG_PSCI_DRAM_RESERVE   ceiling; PSCI owns everything above
//
// The initrd goes last because it is the only one whose size varies by tens of
// megabytes. Ordering it that way means it needs no window reserved up front -
// it just grows into whatever DRAM is left - and nothing below it has to move
// when it changes size. The reverse (initrd packed against the top of DRAM,
// under a DTB placed higher still) cannot work: the load address would depend
// on a size that is only known after the file has been read.
//
// The map steps over the FEL mailbox rather than running through it. Nothing
// would actually collide today - the mailbox only exists in the FEL-only build,
// where the host places every image itself and none of these addresses are used
// - but one map that holds for every variant is easier to reason about than one
// with a "harmless" overlap in it. The mailbox address is fixed by
// tools/fel.sh, so the kernel guard is sized to stop exactly beneath it.
#define CONFIG_KERNEL_LOAD_ADDR	  (SDRAM_BASE + MB(32))
#define CONFIG_KERNEL_GUARD_SIZE  MB(17)
#define CONFIG_FEL_MAILBOX_SIZE	  MB(1)
#define CONFIG_DTB_LOAD_ADDR	  (CONFIG_FEL_MAILBOX_BASE + CONFIG_FEL_MAILBOX_SIZE)
#define CONFIG_DTB_GUARD_SIZE	  MB(1)
#define CONFIG_INITRD_LOAD_ADDR	  (CONFIG_DTB_LOAD_ADDR + CONFIG_DTB_GUARD_SIZE)

// Cap on the initrd whatever the free DRAM works out to, so a wrong file on
// the boot partition is rejected early instead of being read in full.
#define CONFIG_INITRAMFS_MAX_SIZE MB(25)

#define CONFIG_INITRD_ALIGNMENT	  64U

// FEL mailbox layout. tools/fel.sh hardcodes these addresses, so the load map
// above is arranged around this base rather than the other way round.
#define CONFIG_FEL_MAILBOX_BASE    0x43100000U
#define CONFIG_MAIL_INITRD_SIZE_ADDR  (CONFIG_FEL_MAILBOX_BASE + 0x0U)
#define CONFIG_MAIL_INITRD_START_ADDR (CONFIG_FEL_MAILBOX_BASE + 0x4U)
#define CONFIG_MAIL_DTB_ADDR_ADDR      (CONFIG_FEL_MAILBOX_BASE + 0x8U)
#define CONFIG_MAIL_KERNEL_ADDR_ADDR   (CONFIG_FEL_MAILBOX_BASE + 0xCU)

// The load map only holds together if the kernel guard really does stop where
// the mailbox starts; CONFIG_KERNEL_GUARD_SIZE and CONFIG_FEL_MAILBOX_BASE are
// independent constants, so changing either one silently breaks it.
_Static_assert((CONFIG_KERNEL_LOAD_ADDR + CONFIG_KERNEL_GUARD_SIZE) == CONFIG_FEL_MAILBOX_BASE,
			 "kernel guard region does not end at the FEL mailbox");
_Static_assert((CONFIG_MAIL_KERNEL_ADDR_ADDR + 4U) <= (CONFIG_FEL_MAILBOX_BASE + CONFIG_FEL_MAILBOX_SIZE),
			 "FEL mailboxes do not fit in CONFIG_FEL_MAILBOX_SIZE");
_Static_assert((CONFIG_INITRD_LOAD_ADDR % CONFIG_INITRD_ALIGNMENT) == 0U,
			 "initrd load address is not CONFIG_INITRD_ALIGNMENT aligned");

#define CONFIG_CONF_FILENAME	"boot.cfg"
#define CONFIG_DEFAULT_BOOT_CMD "console=ttyS3,115200 earlycon"
#define CONFIG_BOOT_MAX_TRIES	2

/* Boot source configuration flags (1 = enabled) */
#define CONFIG_BOOT_SPINAND 0
#define CONFIG_BOOT_SDCARD	0
#define CONFIG_BOOT_MMC		1

#define CONFIG_FATFS_CACHE_SIZE		 36 // (unit: 512B sectors, multiples of 8 to match FAT's 4KB)
#define CONFIG_SDMMC_SPEED_TEST_SIZE 2048 // (unit: 512B sectors)

#define CONFIG_CPU_FREQ 1200000000

// #define CONFIG_ENABLE_CPU_FREQ_DUMP

// 128KB erase sectors, 2KB pages, so place them starting from 2nd sector
#define CONFIG_SPINAND_DTB_ADDR	   (128 * 2048)
#define CONFIG_SPINAND_KERNEL_ADDR (256 * 2048)

#define CONFIG_PSCI_DRAM_RESERVE 0x00010000U

#define LED_BOARD  1

extern sunxi_usart_t usart0_dbg;
extern sunxi_usart_t usart3_dbg;
extern sunxi_usart_t usart5_dbg;
extern sunxi_spi_t	 sunxi_spi0;

extern sdhci_t sdhci0;
extern sdhci_t sdhci2;

void board_init(void);
void board_set_led(uint8_t num, uint8_t on);

#define USART_DBG usart0_dbg
#define SDHCI sdhci0

#endif
