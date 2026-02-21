/*
 * HERB OS Framebuffer — BGA + Rendering Primitives
 *
 * Bochs Graphics Adapter (BGA) initialization over PCI.
 * Double-buffered software rendering with bitmap font.
 *
 * BGA is QEMU's virtual GPU: vendor 0x1234, device 0x1111.
 * Framebuffer is a linear memory region at BAR0 (read from PCI config).
 * BGA registers at I/O ports 0x01CE/0x01CF work from any CPU mode.
 *
 * The back buffer lives in system RAM (fast, cached).
 * fb_flip() copies it to the framebuffer (uncached MMIO, sequential writes).
 * Never read from the framebuffer — PCIe reads are catastrophically slow.
 */

#ifndef FRAMEBUFFER_H
#define FRAMEBUFFER_H

#include "herb_freestanding.h"
#include "font8x16.h"

/* ============================================================
 * CONFIGURATION
 * ============================================================ */

#define FB_WIDTH   800
#define FB_HEIGHT  600
#define FB_BPP     32
#define FB_PITCH   (FB_WIDTH * (FB_BPP / 8))   /* bytes per scanline */
#define FB_SIZE    (FB_WIDTH * FB_HEIGHT * (FB_BPP / 8))

/* Back buffer: system RAM at 5MB mark (before arena at 8MB) */
#define BACKBUF_ADDR  0x500000

/* ============================================================
 * COLORS (0x00RRGGBB — XRGB format)
 * ============================================================ */

#define COL_BLACK      0x00000000
#define COL_WHITE      0x00FFFFFF
#define COL_BG         0x00101020   /* dark navy background */
#define COL_BANNER_BG  0x00182848   /* banner background */
#define COL_STATS_BG   0x00142038   /* stats bar background */
#define COL_LEGEND_BG  0x00101828   /* legend background */

/* Process state colors */
#define COL_RUNNING    0x0000CC66   /* green */
#define COL_RUNNING_BG 0x00103020   /* dark green fill */
#define COL_READY      0x00CCAA00   /* yellow */
#define COL_READY_BG   0x00282010   /* dark yellow fill */
#define COL_BLOCKED    0x00CC3333   /* red */
#define COL_BLOCKED_BG 0x00281010   /* dark red fill */
#define COL_TERM       0x00555555   /* gray */
#define COL_TERM_BG    0x00181818   /* dark gray fill */

/* Container border/header colors */
#define COL_BORDER     0x00446688   /* steel blue border */
#define COL_HEADER_FG  0x00AACCEE   /* header text */

/* Text colors */
#define COL_TEXT       0x00DDDDDD   /* primary text */
#define COL_TEXT_DIM   0x00888888   /* dimmed text */
#define COL_TEXT_HI    0x00FFFFFF   /* highlighted text */
#define COL_TEXT_KEY   0x00FFDD44   /* key highlight */
#define COL_TEXT_VAL   0x0066CCFF   /* value highlight */

/* Resource indicator colors */
#define COL_RES_FREE   0x00338855   /* free resource */
#define COL_RES_USED   0x00CC4444   /* used/allocated resource */
#define COL_RES_FD_F   0x00335588   /* free FD */
#define COL_RES_FD_U   0x00CC8844   /* open FD */

/* Tension panel colors — cool tones to distinguish rules from things */
#define COL_TENS_BG     0x000C1018   /* tension panel background */
#define COL_TENS_BORDER 0x00336688   /* tension panel border */
#define COL_TENS_ON     0x0000BBDD   /* enabled tension indicator */
#define COL_TENS_OFF    0x00443333   /* disabled tension indicator */
#define COL_TENS_ON_BG  0x00101830   /* enabled tension row background */
#define COL_TENS_OFF_BG 0x000C0C14   /* disabled tension row background */
#define COL_TENS_TITLE  0x0066AACC   /* tension panel title */
#define COL_TENS_NAME   0x00AADDEE   /* tension name text (enabled) */
#define COL_TENS_DIM    0x00556666   /* tension name text (disabled) */
#define COL_TENS_PRI    0x00887799   /* tension priority text */
#define COL_TENS_SEL    0x00FFFFFF   /* selected tension highlight */

/* ============================================================
 * 16-BIT AND 32-BIT PORT I/O
 * ============================================================ */

static inline void outw(uint16_t port, uint16_t val) {
    __asm__ volatile ("outw %0, %1" : : "a"(val), "Nd"(port));
}

static inline uint16_t inw(uint16_t port) {
    uint16_t val;
    __asm__ volatile ("inw %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}

static inline void outl(uint16_t port, uint32_t val) {
    __asm__ volatile ("outl %0, %1" : : "a"(val), "Nd"(port));
}

static inline uint32_t inl(uint16_t port) {
    uint32_t val;
    __asm__ volatile ("inl %1, %0" : "=a"(val) : "Nd"(port));
    return val;
}

/* ============================================================
 * PCI CONFIGURATION SPACE
 *
 * Port 0xCF8: CONFIG_ADDRESS (32-bit)
 * Port 0xCFC: CONFIG_DATA (32-bit)
 * ============================================================ */

#define PCI_CONFIG_ADDR  0x0CF8
#define PCI_CONFIG_DATA  0x0CFC

static uint32_t pci_read(uint8_t bus, uint8_t slot, uint8_t func, uint8_t offset) {
    uint32_t address = ((uint32_t)1 << 31)       /* enable bit */
                     | ((uint32_t)bus << 16)
                     | ((uint32_t)slot << 11)
                     | ((uint32_t)func << 8)
                     | ((uint32_t)(offset & 0xFC));
    outl(PCI_CONFIG_ADDR, address);
    return inl(PCI_CONFIG_DATA);
}

/* ============================================================
 * BGA (BOCHS GRAPHICS ADAPTER) REGISTERS
 *
 * Index port: 0x01CE (write register index)
 * Data port:  0x01CF (read/write register value)
 * ============================================================ */

#define BGA_INDEX_PORT  0x01CE
#define BGA_DATA_PORT   0x01CF

/* Register indices */
#define BGA_REG_ID          0x00
#define BGA_REG_XRES        0x01
#define BGA_REG_YRES        0x02
#define BGA_REG_BPP         0x03
#define BGA_REG_ENABLE      0x04
#define BGA_REG_BANK        0x05
#define BGA_REG_VIRT_WIDTH  0x06
#define BGA_REG_VIRT_HEIGHT 0x07
#define BGA_REG_X_OFFSET    0x08
#define BGA_REG_Y_OFFSET    0x09

/* Enable flags */
#define BGA_DISABLED    0x00
#define BGA_ENABLED     0x01
#define BGA_LFB_ENABLED 0x40

static void bga_write(uint16_t reg, uint16_t val) {
    outw(BGA_INDEX_PORT, reg);
    outw(BGA_DATA_PORT, val);
}

static uint16_t bga_read(uint16_t reg) {
    outw(BGA_INDEX_PORT, reg);
    return inw(BGA_DATA_PORT);
}

/* ============================================================
 * FRAMEBUFFER STATE
 * ============================================================ */

static volatile uint32_t* fb_ptr = (volatile uint32_t*)0;  /* MMIO framebuffer */
static uint32_t* fb_back = (uint32_t*)BACKBUF_ADDR;        /* system RAM back buffer */
static int fb_w = 0;
static int fb_h = 0;
static int fb_active = 0;  /* 1 if framebuffer initialized successfully */

/* ============================================================
 * PAGE TABLE MAPPING
 *
 * The bootloader identity-maps first 64MB (PML4[0]→PDPT[0]→PD at 0x3000).
 * The BGA framebuffer lives at high physical addresses (typically 0xFD000000).
 * We add a mapping for PDPT[3] covering 0xC0000000-0xFFFFFFFF.
 *
 * Page tables (set by bootloader):
 *   0x1000: PML4
 *   0x2000: PDPT
 *   0x3000: PD (first 1GB, first 32 entries used = 64MB)
 *   0x4000: available for new PD page
 * ============================================================ */

static int map_framebuffer(uint64_t fb_phys, uint64_t fb_size) {
    /* Only handle addresses in the 3-4GB range (PDPT[3]) */
    if (fb_phys < 0xC0000000ULL || fb_phys >= 0x100000000ULL) {
        return -1;
    }

    volatile uint64_t* pdpt = (volatile uint64_t*)0x2000;
    volatile uint64_t* new_pd = (volatile uint64_t*)0x4000;

    /* Zero the new PD page */
    for (int i = 0; i < 512; i++) new_pd[i] = 0;

    /* PDPT[3] → PD at 0x4000 (present + writable) */
    pdpt[3] = 0x4000ULL | 0x03ULL;

    /* Calculate which PD entries cover the framebuffer.
     * PDPT[3] covers 0xC0000000-0xFFFFFFFF.
     * Each PD entry covers 2MB. */
    uint64_t offset = fb_phys - 0xC0000000ULL;
    int pd_start = (int)(offset / 0x200000ULL);
    int num_pages = (int)((fb_size + 0x1FFFFFULL) / 0x200000ULL);

    for (int i = 0; i < num_pages && (pd_start + i) < 512; i++) {
        uint64_t page_addr = fb_phys + (uint64_t)i * 0x200000ULL;
        /* Present + Writable + 2MB page + PCD + PWT (uncached for MMIO) */
        new_pd[pd_start + i] = page_addr | 0x9BULL;
    }

    /* Flush TLB by reloading CR3 */
    __asm__ volatile (
        "mov %%cr3, %%rax\n\t"
        "mov %%rax, %%cr3"
        ::: "rax", "memory"
    );

    return 0;
}

/* ============================================================
 * FIND BGA FRAMEBUFFER
 *
 * Scan PCI bus 0 for vendor 0x1234, device 0x1111 (Bochs VGA).
 * Return BAR0 (framebuffer physical address) or 0 on failure.
 * ============================================================ */

static uint64_t find_bga_bar0(void) {
    /* Check standard QEMU location first (bus 0, slot 2) */
    for (int slot = 0; slot < 32; slot++) {
        uint32_t id = pci_read(0, (uint8_t)slot, 0, 0);
        uint16_t vendor = (uint16_t)(id & 0xFFFF);
        uint16_t device = (uint16_t)((id >> 16) & 0xFFFF);

        if (vendor == 0x1234 && device == 0x1111) {
            uint32_t bar0 = pci_read(0, (uint8_t)slot, 0, 0x10);
            /* Mask lower 4 bits (BAR flags) */
            return (uint64_t)(bar0 & 0xFFFFFFF0UL);
        }
    }
    return 0;
}

/* ============================================================
 * FRAMEBUFFER INITIALIZATION
 *
 * 1. Find BGA via PCI
 * 2. Map framebuffer into virtual address space
 * 3. Set BGA mode (resolution + bpp)
 * 4. Point fb_ptr to the mapped framebuffer
 *
 * Returns 0 on success, -1 on failure.
 * ============================================================ */

static int fb_init_display(void) {
    /* Find BGA framebuffer address */
    uint64_t bar0 = find_bga_bar0();
    if (bar0 == 0) {
        return -1;  /* BGA not found */
    }

    /* Map 16MB at the framebuffer address (covers any resolution up to 2048x2048x32) */
    if (map_framebuffer(bar0, 16 * 1024 * 1024) != 0) {
        return -2;  /* mapping failed */
    }

    /* Verify BGA is present by reading ID register */
    uint16_t bga_id = bga_read(BGA_REG_ID);
    if (bga_id < 0xB0C0 || bga_id > 0xB0C5) {
        return -3;  /* BGA not responding */
    }

    /* Set BGA mode: disable → configure → enable with LFB */
    bga_write(BGA_REG_ENABLE, BGA_DISABLED);
    bga_write(BGA_REG_XRES, FB_WIDTH);
    bga_write(BGA_REG_YRES, FB_HEIGHT);
    bga_write(BGA_REG_BPP, FB_BPP);
    bga_write(BGA_REG_VIRT_WIDTH, FB_WIDTH);
    bga_write(BGA_REG_VIRT_HEIGHT, FB_HEIGHT);
    bga_write(BGA_REG_X_OFFSET, 0);
    bga_write(BGA_REG_Y_OFFSET, 0);
    bga_write(BGA_REG_ENABLE, BGA_ENABLED | BGA_LFB_ENABLED);

    /* Set up framebuffer pointers */
    fb_ptr = (volatile uint32_t*)bar0;
    fb_back = (uint32_t*)BACKBUF_ADDR;
    fb_w = FB_WIDTH;
    fb_h = FB_HEIGHT;
    fb_active = 1;

    return 0;
}

/* ============================================================
 * DOUBLE BUFFER: FLIP
 *
 * Copy back buffer (cached system RAM) to framebuffer (uncached MMIO).
 * Sequential writes only — never read from fb_ptr.
 * ============================================================ */

static void fb_flip(void) {
    if (!fb_active) return;

    /* Copy 32-bit words. At 800x600x4 = 480,000 dwords.
     * Sequential writes to uncached MMIO. */
    volatile uint32_t* dst = fb_ptr;
    const uint32_t* src = fb_back;
    int count = fb_w * fb_h;
    for (int i = 0; i < count; i++) {
        dst[i] = src[i];
    }
}

/* ============================================================
 * RENDERING PRIMITIVES (all write to back buffer)
 * ============================================================ */

/* Set a single pixel in the back buffer */
static inline void fb_pixel(int x, int y, uint32_t color) {
    if (x >= 0 && x < fb_w && y >= 0 && y < fb_h) {
        fb_back[y * fb_w + x] = color;
    }
}

/* Fill entire back buffer with a single color */
static void fb_clear(uint32_t color) {
    int count = FB_WIDTH * FB_HEIGHT;
    uint32_t* p = fb_back;
    for (int i = 0; i < count; i++) {
        p[i] = color;
    }
}

/* Fill a rectangle */
static void fb_fill_rect(int x, int y, int w, int h, uint32_t color) {
    /* Clip */
    int x0 = x < 0 ? 0 : x;
    int y0 = y < 0 ? 0 : y;
    int x1 = (x + w) > fb_w ? fb_w : (x + w);
    int y1 = (y + h) > fb_h ? fb_h : (y + h);

    for (int py = y0; py < y1; py++) {
        uint32_t* row = fb_back + py * fb_w;
        for (int px = x0; px < x1; px++) {
            row[px] = color;
        }
    }
}

/* Draw a rectangle outline (1px border) */
static void fb_draw_rect(int x, int y, int w, int h, uint32_t color) {
    /* Top and bottom edges */
    for (int px = x; px < x + w; px++) {
        fb_pixel(px, y, color);
        fb_pixel(px, y + h - 1, color);
    }
    /* Left and right edges */
    for (int py = y; py < y + h; py++) {
        fb_pixel(x, py, color);
        fb_pixel(x + w - 1, py, color);
    }
}

/* Draw a 2px-thick rectangle outline */
static void fb_draw_rect2(int x, int y, int w, int h, uint32_t color) {
    fb_draw_rect(x, y, w, h, color);
    fb_draw_rect(x + 1, y + 1, w - 2, h - 2, color);
}

/* Draw horizontal line */
static void fb_hline(int x, int y, int w, uint32_t color) {
    for (int i = 0; i < w; i++) {
        fb_pixel(x + i, y, color);
    }
}

/* ============================================================
 * TEXT RENDERING (using embedded 8x16 bitmap font)
 * ============================================================ */

/* Draw a single character at pixel position (x, y).
 * bg=0 means transparent background (don't draw bg pixels). */
static void fb_draw_char(int x, int y, char ch, uint32_t fg, uint32_t bg) {
    unsigned char c = (unsigned char)ch;
    const unsigned char* glyph = font_8x16[c];

    for (int row = 0; row < FONT_HEIGHT; row++) {
        unsigned char bits = glyph[row];
        for (int col = 0; col < FONT_WIDTH; col++) {
            if (bits & (0x80 >> col)) {
                fb_pixel(x + col, y + row, fg);
            } else if (bg != 0) {
                fb_pixel(x + col, y + row, bg);
            }
        }
    }
}

/* Draw a null-terminated string. Returns X position after last char. */
static int fb_draw_string(int x, int y, const char* s, uint32_t fg, uint32_t bg) {
    while (*s) {
        fb_draw_char(x, y, *s, fg, bg);
        x += FONT_WIDTH;
        s++;
    }
    return x;
}

/* Draw an integer value as a string */
static int fb_draw_int(int x, int y, int val, uint32_t fg, uint32_t bg) {
    char buf[16];
    herb_snprintf(buf, sizeof(buf), "%d", val);
    return fb_draw_string(x, y, buf, fg, bg);
}

/* Draw a string padded to exactly 'width' characters */
__attribute__((unused))
static int fb_draw_padded(int x, int y, const char* s, int width, uint32_t fg, uint32_t bg) {
    int i = 0;
    while (s[i] && i < width) {
        fb_draw_char(x + i * FONT_WIDTH, y, s[i], fg, bg);
        i++;
    }
    while (i < width) {
        fb_draw_char(x + i * FONT_WIDTH, y, ' ', fg, bg);
        i++;
    }
    return x + width * FONT_WIDTH;
}

/* ============================================================
 * CONTAINER REGION DRAWING
 *
 * A container region is a bordered box with a title bar
 * that contains process entities as colored rectangles.
 * ============================================================ */

/* Draw a container region with title */
static void fb_draw_container(int x, int y, int w, int h,
                               const char* title, uint32_t border_color,
                               uint32_t fill_color) {
    /* Fill background */
    fb_fill_rect(x, y, w, h, fill_color);

    /* Border (2px) */
    fb_draw_rect2(x, y, w, h, border_color);

    /* Title bar */
    fb_fill_rect(x + 2, y + 2, w - 4, 18, border_color);
    fb_draw_string(x + 6, y + 3, title, COL_TEXT_HI, border_color);
}

/* Draw a process entity rectangle inside a container.
 * Returns the height used. */
static int fb_draw_process(int x, int y, int w, int h,
                            const char* name, int priority, int time_slice,
                            uint32_t border_color, uint32_t fill_color) {
    /* Background */
    fb_fill_rect(x, y, w, h, fill_color);

    /* Border (1px) */
    fb_draw_rect(x, y, w, h, border_color);

    /* Name (bold: draw twice offset by 1px) */
    fb_draw_string(x + 4, y + 3, name, COL_TEXT_HI, 0);

    /* Priority and time_slice on second line */
    int tx = fb_draw_string(x + 4, y + 19, "p=", COL_TEXT_DIM, 0);
    tx = fb_draw_int(tx, y + 19, priority, COL_TEXT_VAL, 0);
    tx = fb_draw_string(tx + 4, y + 19, "ts=", COL_TEXT_DIM, 0);
    fb_draw_int(tx, y + 19, time_slice, COL_TEXT_VAL, 0);

    return h;
}

/* Draw resource indicators (small colored squares) inside a process rect */
static void fb_draw_resources(int x, int y,
                               int mem_free, int mem_used,
                               int fd_free, int fd_open) {
    int sx = x;
    int sq = 6;  /* square size */
    int gap = 2;

    /* MEM label */
    fb_draw_string(sx, y, "M", COL_TEXT_DIM, 0);
    sx += 10;

    /* Free pages (green squares) */
    for (int i = 0; i < mem_free && i < 8; i++) {
        fb_fill_rect(sx, y + 2, sq, sq, COL_RES_FREE);
        sx += sq + gap;
    }
    /* Used pages (red squares) */
    for (int i = 0; i < mem_used && i < 8; i++) {
        fb_fill_rect(sx, y + 2, sq, sq, COL_RES_USED);
        sx += sq + gap;
    }

    /* FD label */
    sx += 6;
    fb_draw_string(sx, y, "F", COL_TEXT_DIM, 0);
    sx += 10;

    /* Free FDs (blue squares) */
    for (int i = 0; i < fd_free && i < 8; i++) {
        fb_fill_rect(sx, y + 2, sq, sq, COL_RES_FD_F);
        sx += sq + gap;
    }
    /* Open FDs (orange squares) */
    for (int i = 0; i < fd_open && i < 8; i++) {
        fb_fill_rect(sx, y + 2, sq, sq, COL_RES_FD_U);
        sx += sq + gap;
    }
}

/* ============================================================
 * MOUSE CURSOR — DIRECT MMIO RENDERING
 *
 * The cursor is drawn directly to the MMIO framebuffer (fb_ptr)
 * rather than through the back buffer. This allows cheap cursor
 * updates without a full fb_flip():
 *   1. Erase old cursor: copy from back buffer to MMIO
 *   2. Draw new cursor: write to MMIO directly
 *
 * The back buffer always holds the scene WITHOUT cursor.
 * After fb_flip(), call fb_cursor_draw() to overlay the cursor.
 * ============================================================ */

/* Cursor bitmap: 10x14 arrow, 1 = foreground, MSB-first in uint16_t */
#define CURSOR_W  10
#define CURSOR_H  14

static const uint16_t cursor_shape[CURSOR_H] = {
    0x8000,  /* 1......... */
    0xC000,  /* 11........ */
    0xE000,  /* 111....... */
    0xF000,  /* 1111...... */
    0xF800,  /* 11111..... */
    0xFC00,  /* 111111.... */
    0xFE00,  /* 1111111... */
    0xFF00,  /* 11111111.. */
    0xFF80,  /* 111111111. */
    0xFE00,  /* 1111111... */
    0xEC00,  /* 111.11.... */
    0xC600,  /* 11...11... */
    0x0600,  /* .....11... */
    0x0300,  /* ......11.. */
};

/* Shadow: offset 1px right and down, makes cursor visible on any background */
static const uint16_t cursor_shadow[CURSOR_H] = {
    0x4000,  /* .1........ */
    0x2000,  /* ..1....... */
    0x1000,  /* ...1...... */
    0x0800,  /* ....1..... */
    0x0400,  /* .....1.... */
    0x0200,  /* ......1... */
    0x0100,  /* .......1.. */
    0x0080,  /* ........1. */
    0x0040,  /* .........1 */
    0x0100,  /* .......1.. */
    0x1200,  /* ...1..1... */
    0x2100,  /* ..1....1.. */
    0x0100,  /* .......1.. */
    0x0080,  /* ........1. */
};

#define COL_CURSOR_FG  0x00FFFFFF  /* white */
#define COL_CURSOR_BG  0x00000000  /* black shadow */

/* Cursor state */
static int cursor_x = 400, cursor_y = 300;  /* current position */
static int cursor_old_x = 400, cursor_old_y = 300;  /* previous position */

/* Erase cursor: restore area from back buffer to MMIO */
static void fb_cursor_erase(void) {
    if (!fb_active) return;
    int x0 = cursor_old_x - 1;  /* -1 for shadow */
    int y0 = cursor_old_y - 1;
    int x1 = x0 + CURSOR_W + 2;
    int y1 = y0 + CURSOR_H + 2;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > fb_w) x1 = fb_w;
    if (y1 > fb_h) y1 = fb_h;

    for (int py = y0; py < y1; py++) {
        for (int px = x0; px < x1; px++) {
            fb_ptr[py * fb_w + px] = fb_back[py * fb_w + px];
        }
    }
}

/* Draw cursor directly to MMIO framebuffer */
static void fb_cursor_draw(void) {
    if (!fb_active) return;

    /* Draw shadow first (1px offset) */
    for (int row = 0; row < CURSOR_H; row++) {
        uint16_t bits = cursor_shadow[row];
        for (int col = 0; col < CURSOR_W; col++) {
            if (bits & (0x8000 >> col)) {
                int px = cursor_x + col + 1;
                int py = cursor_y + row + 1;
                if (px >= 0 && px < fb_w && py >= 0 && py < fb_h) {
                    fb_ptr[py * fb_w + px] = COL_CURSOR_BG;
                }
            }
        }
    }

    /* Draw foreground */
    for (int row = 0; row < CURSOR_H; row++) {
        uint16_t bits = cursor_shape[row];
        for (int col = 0; col < CURSOR_W; col++) {
            if (bits & (0x8000 >> col)) {
                int px = cursor_x + col;
                int py = cursor_y + row;
                if (px >= 0 && px < fb_w && py >= 0 && py < fb_h) {
                    fb_ptr[py * fb_w + px] = COL_CURSOR_FG;
                }
            }
        }
    }

    cursor_old_x = cursor_x;
    cursor_old_y = cursor_y;
}

/* Selection highlight color */
#define COL_SELECTED   0x00FFFFFF  /* bright white */

#endif /* FRAMEBUFFER_H */
