#include "common.h"
#include "loaders.h"
#include "board.h"
#if CONFIG_BOOT_SPINAND
#include "fdt.h"
#endif

#if CONFIG_BOOT_SDCARD || CONFIG_BOOT_MMC

#include "sdmmc.h"

FATFS fs;

#ifndef CLTBL_DWORDS
#define CLTBL_DWORDS 2000U
#endif

#ifndef READ_CHUNK
#define READ_CHUNK (32U * 1024U)
#endif

// consume() returns false to stop the stream early, e.g. when its destination
// is full. That is not an error here; the caller knows why it asked to stop.
static FRESULT read_stream(const char *path, bool (*consume)(const uint8_t *, UINT))
{
	FRESULT fret;
	FIL	file;
	UINT	bytes_read = 0U;

	if ((path == NULL) || (consume == NULL))
		return FR_INVALID_PARAMETER;

	fret = f_open(&file, path, FA_READ);
	if (fret != FR_OK)
		return fret;

	static DWORD cltbl[CLTBL_DWORDS];
	cltbl[0]    = CLTBL_DWORDS;
	file.cltbl  = cltbl;
	fret = f_lseek(&file, CREATE_LINKMAP);
	if (fret == FR_NOT_ENOUGH_CORE) {
		f_close(&file);
		return fret;
	}
	if (fret != FR_OK) {
		f_close(&file);
		return fret;
	}

	static uint8_t buf[READ_CHUNK];
	FRESULT     read_result = FR_OK;
	do {
		fret = f_read(&file, buf, READ_CHUNK, &bytes_read);
		if (fret != FR_OK) {
			read_result = fret;
			break;
		}
		if (bytes_read == 0U)
			break;
		if (!consume(buf, bytes_read))
			break;
	} while (bytes_read == READ_CHUNK);

	file.cltbl = NULL;
	FRESULT close_result = f_close(&file);
	if (read_result != FR_OK)
		return read_result;
	return close_result;
}

typedef struct {
	uint8_t *dest;
	u32	 total;
	u32	 limit;	// bytes the destination can hold; 0 means "no bound"
	bool	 overflow;
} read_copy_state_t;

static read_copy_state_t read_copy_state;

static bool read_copy_consume(const uint8_t *buf, UINT len)
{
	// The caller sizes the destination before the file size is known, so a
	// file bigger than the window has to stop here rather than keep memcpy'ing
	// over whatever was loaded next. Stopping also matters for the watchdog:
	// reading a multi-megabyte file to completion only to reject it can take
	// longer than the timeout armed before the load.
	//
	// Written as a subtraction because total + len would wrap on a bad size.
	if ((u32)len > (read_copy_state.limit - read_copy_state.total)) {
		read_copy_state.overflow = true;
		return false;
	}

	memcpy(read_copy_state.dest, buf, (size_t)len);
	read_copy_state.dest += (size_t)len;
	read_copy_state.total += (u32)len;

	return true;
}

void sdmmc_speed_test(void)
{
	u32 start = time_ms();
	u32 test_time;
	u32 kb_tested;
	u32 kb_per_second;

	sdmmc_blk_read(&card0, (u8 *)(SDRAM_BASE), 0, CONFIG_SDMMC_SPEED_TEST_SIZE);
	test_time	  = time_ms() - start;
	kb_tested	  = (CONFIG_SDMMC_SPEED_TEST_SIZE * 512U) / 1024U;
	kb_per_second = (test_time == 0U) ? 0U : (CONFIG_SDMMC_SPEED_TEST_SIZE * 512U) / test_time;
	if (kb_per_second < 1000) {
		info("SDMMC: speedtest %" PRIu32 "KB in %" PRIu32 "ms at %" PRIu32 "KB/S\r\n", kb_tested, test_time,
			 kb_per_second);
	} else {
		u32 mb_per_second = kb_per_second / 1024;
		info("SDMMC: speedtest %" PRIu32 "KB in %" PRIu32 "ms at %" PRIu32 "MB/S\r\n", kb_tested, test_time,
			 mb_per_second);
	}
}

int mount_sdmmc()
{
	FRESULT fret;

	/* mount fs */
	fret = f_mount(&fs, "", 1);
	if (fret != FR_OK) {
		error("FATFS: mount error: %d\r\n", fret);
		return -1;
	} else {
		debug("FATFS: mount OK\r\n");
	}

	return 0;
}

void unmount_sdmmc(void)
{
	FRESULT fret;

	/* umount fs */
	fret = f_mount(0, "", 0);
	if (fret != FR_OK) {
		error("FATFS: unmount error %d\r\n", fret);
	} else {
		debug("FATFS: unmount OK\r\n");
	}
}

int read_file(const char *filename, uint8_t *dest, u32 max)
{
	if (!filename) {
		error("FATFS: empty filename\r\n");
		return -1;
	}
	if (!dest) {
		error("FATFS: empty destination\r\n");
		return -1;
	}
	if (max == 0U) {
		error("FATFS: no room reserved for [%s]\r\n", filename);
		return -1;
	}

#if LOG_LEVEL >= LOG_DEBUG
	u32 start = time_ms();
#endif

	read_copy_state.dest	 = dest;
	read_copy_state.total	 = 0U;
	read_copy_state.limit	 = max;
	read_copy_state.overflow = false;

	FRESULT fret = read_stream(filename, read_copy_consume);
	if (fret != FR_OK) {
		read_copy_state.dest  = NULL;
		read_copy_state.total = 0U;
		error("FATFS: file read: [%s]: error %d\r\n", filename, fret);
		return -1;
	}
	if (read_copy_state.overflow) {
		read_copy_state.dest  = NULL;
		read_copy_state.total = 0U;
		error("FATFS: [%s] is larger than its %" PRIu32 " byte window\r\n", filename, max);
		return -1;
	}

	u32 total_bytes = read_copy_state.total;

#if LOG_LEVEL >= LOG_DEBUG
	u32 duration	 = time_ms() - start + 1U;
	f32 throughput = ((f32)total_bytes / (f32)duration) / 1024.0f;
	debug("FATFS: %s read in %" PRIu32 "ms at %.2fMB/S\r\n", filename, duration, throughput);
#endif

	read_copy_state.dest  = NULL;
	read_copy_state.total = 0U;
	return (int)total_bytes;
}

int load_sdmmc(image_info_t *image)
{
	int ret;

#if LOG_LEVEL >= LOG_DEBUG
	u32 start;
	start = time_ms();
#endif // LOG_LEVEL >= LOG_DEBUG

	// Each read is bounded by the guard region the load map gives that object,
	// so an oversized file on the card fails here instead of running into
	// whatever is loaded next.
	info("FATFS: read %s addr=%x\r\n", image->of_filename, (unsigned int)image->dtb_dest);
	ret = read_file(image->of_filename, image->dtb_dest, CONFIG_DTB_GUARD_SIZE);
	if (ret <= 0)
		return ret;
	image->dtb_size = ret;

	info("FATFS: read %s addr=%x\r\n", image->filename, (unsigned int)image->kernel_dest);
	ret = read_file(image->filename, image->kernel_dest, CONFIG_KERNEL_GUARD_SIZE);
	if (ret <= 0)
		return ret;
	image->kernel_size = ret;

	// initrd_limit is the free DRAM main() worked out above initrd_dest; zero
	// means there is nowhere to put an initrd, so there is nothing to do.
	if (image->initrd_filename && image->initrd_dest && (image->initrd_limit > 0U)) {
		if (strlen(image->initrd_filename)) {
			info("FATFS: read %s addr=%x\r\n", image->initrd_filename, (unsigned int)image->initrd_dest);
			ret = read_file(image->initrd_filename, image->initrd_dest, image->initrd_limit);
			if (ret <= 0)
				return ret;
			image->initrd_size = ret;
		}
	}

#if LOG_LEVEL >= LOG_DEBUG
	debug("FATFS: done in %" PRIu32 "ms\r\n", time_ms() - start);
#endif

	return 0;
}
#endif

#if CONFIG_BOOT_SPINAND
int load_spi_nand(sunxi_spi_t *spi, image_info_t *image)
{
	linux_zimage_header_t *hdr;
	unsigned int		   size;
	uint64_t			   start, time;

	if (spi_nand_detect(spi) != 0)
		return -1;

	/* get dtb size and read */
	spi_nand_read(spi, image->dtb_dest, CONFIG_SPINAND_DTB_ADDR, (uint32_t)sizeof(boot_param_header_t));
	if (fdt_check_blob_valid(image->dtb_dest) != 0) {
		error("SPI-NAND: DTB verification failed\r\n");
		return -1;
	}

	size = fdt_get_total_size(image->dtb_dest);
	debug("SPI-NAND: dt blob: Copy from 0x%08x to 0x%08lx size:0x%08x\r\n", CONFIG_SPINAND_DTB_ADDR,
		  (uint32_t)image->dtb_dest, size);
	start = time_us();
	spi_nand_read(spi, image->dtb_dest, CONFIG_SPINAND_DTB_ADDR, (uint32_t)size);
	time = time_us() - start;
	info("SPI-NAND: read dt blob of size %u at %.2fMB/S\r\n", size, (f32)(size / time));

	/* get kernel size and read */
	spi_nand_read(spi, image->kernel_dest, CONFIG_SPINAND_KERNEL_ADDR, (uint32_t)sizeof(linux_zimage_header_t));
	hdr = (linux_zimage_header_t *)image->kernel_dest;
	if (hdr->magic != LINUX_ZIMAGE_MAGIC) {
		debug("SPI-NAND: zImage verification failed\r\n");
		return -1;
	}
	size = hdr->end - hdr->start;
	debug("SPI-NAND: Image: Copy from 0x%08x to 0x%08lx size:0x%08x\r\n", CONFIG_SPINAND_KERNEL_ADDR,
		  (uint32_t)image->kernel_dest, size);
	start = time_us();
	spi_nand_read(spi, image->kernel_dest, CONFIG_SPINAND_KERNEL_ADDR, (uint32_t)size);
	time = time_us() - start;
	info("SPI-NAND: read Image of size %u at %.2fMB/S\r\n", size, (f32)(size / time));

	return 0;
}
#endif
