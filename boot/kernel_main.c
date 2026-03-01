/*
 * HERB OS Kernel — Interactive
 *
 * The C entry point called by kernel_entry.asm after entering
 * 64-bit long mode. This file contains:
 *
 *   - VGA text mode output (0xB8000) OR pixel framebuffer (BGA)
 *   - Serial port debug (COM1 0x3F8)
 *   - IDT / PIC / PIT setup
 *   - PS/2 keyboard scancode table
 *   - HERB runtime integration
 *   - Interactive command dispatch (keyboard → HERB signals)
 *   - Structured process table / graphical state display
 *
 * Supports compile flags:
 *   - KERNEL_MODE: four-module kernel (qualified names, scoped resources)
 *   - GRAPHICS_MODE: pixel framebuffer via BGA (800x600x32)
 *     Without GRAPHICS_MODE: VGA text mode (80x25)
 *
 * No libc. No POSIX. No Linux. Just hardware and HERB.
 */

#include "herb_freestanding.h"

/* Embedded HERB program (generated from .herb.json) */
#include "program_data.h"

/* Embedded process program binaries (generated from .herb files) */
#ifdef KERNEL_MODE
#include "process_programs.h"
#endif

/* Framebuffer graphics (BGA + rendering primitives) */
#ifdef GRAPHICS_MODE
#include "framebuffer.h"
#endif

/* ============================================================
 * CONTAINER & TYPE NAME MACROS
 *
 * KERNEL_MODE uses qualified names from module composition.
 * Default mode uses flat names from interactive_os.
 * ============================================================ */

#ifdef KERNEL_MODE
  #define CN_READY       "proc.READY"
  #define CN_CPU0        "proc.CPU0"
  #define CN_BLOCKED     "proc.BLOCKED"
  #define CN_TERMINATED  "proc.TERMINATED"
  #define CN_TIMER_SIG   "proc.TIMER_SIG"
  #define CN_KILL_SIG    "proc.KILL_SIG"
  #define CN_BLOCK_SIG   "proc.BLOCK_SIG"
  #define CN_UNBLOCK_SIG "proc.UNBLOCK_SIG"
  #define CN_BOOST_SIG   "proc.BOOST_SIG"
  #define CN_ALLOC_SIG   "proc.ALLOC_SIG"
  #define CN_FREE_SIG    "proc.FREE_SIG"
  #define CN_OPEN_SIG    "proc.OPEN_SIG"
  #define CN_CLOSE_SIG   "proc.CLOSE_SIG"
  #define CN_SEND_SIG    "proc.SEND_SIG"
  #define CN_CLICK_SIG   "proc.CLICK_SIG"
  #define CN_KEY_SIG     "proc.KEY_SIG"
  #define CN_SIG_DONE    "proc.SIG_DONE"
  #define CN_VISIBLE     "display.VISIBLE"
  #define CN_CMDLINE     "input.CMDLINE"
  #define CN_INPUT_STATE "input.INPUT_STATE"
  #define CN_CMD_SIG     "proc.CMD_SIG"
  #define CN_SPAWN_SIG   "proc.SPAWN_SIG"
  #define CN_KEYBIND     "input.KEYBIND"
  #define CN_TEXTCMD     "input.TEXTCMD"
  #define CN_TEXTARG     "input.TEXTARG"
  #define CN_MECHBIND    "input.MECHBIND"
  #define CN_SHELL_STATE "input.SHELL_STATE"
  #define CN_SPAWN_STATE "spawn.SPAWN_STATE"
  #define CN_DISPLAY_STATE "display.DISPLAY_STATE"
  #define CN_LEGEND      "display.LEGEND"
  #define CN_HELP_TEXT   "display.HELP_TEXT"
  #define CN_GAME_STATE     "world.GAME_STATE"
  #define CN_GAME_PLAYER    "world.PLAYER"
  #define CN_GAME_TILES     "world.TILES"
  #define CN_GAME_TREES     "world.TREES"
  #define CN_GAME_MOVE_SIG  "world.MOVE_SIG"
  #define CN_GAME_GATHER_SIG "world.GATHER_SIG"
  #define CN_GAME_TREE_GATHERED "world.TREE_GATHERED"
  #define ET_GAME_SIGNAL    "world.GameSignal"
  #define ET_SHELLCTL    "input.ShellCtl"
  #define ET_SPAWNCTL    "spawn.SpawnCtl"
  #define ET_PROCESS     "proc.Process"
  #define ET_SIGNAL      "proc.Signal"
  #define ET_SURFACE     "display.Surface"
  #define ET_PAGE        "mem.Page"
  #define ET_FD          "fs.FileDescriptor"
  #define ET_MSG         "ipc.Message"
  #define CN_BUFFER      "BUFFER"
  #define ET_BUFFER      "Buffer"
  #define OS_TITLE       "HERB KERNEL"
  #define OS_SUBTITLE    "Shell"
#else
  #define CN_READY       "READY"
  #define CN_CPU0        "CPU0"
  #define CN_BLOCKED     "BLOCKED"
  #define CN_TERMINATED  "TERMINATED"
  #define CN_TIMER_SIG   "TIMER_EXPIRED"
  #define CN_KILL_SIG    "KILL_SIG"
  #define CN_BLOCK_SIG   "BLOCK_SIG"
  #define CN_UNBLOCK_SIG "UNBLOCK_SIG"
  #define CN_BOOST_SIG   "BOOST_SIG"
  #define CN_SIG_DONE    "SIG_DONE"
  #define ET_PROCESS     "Process"
  #define ET_SIGNAL      "Signal"
  #define OS_TITLE       "HERB OS"
  #define OS_SUBTITLE    "Interactive Shell"
#endif

/* ============================================================
 * HERB Runtime API (from herb_runtime_freestanding.c)
 * ============================================================ */

extern void herb_init(void* arena_memory, herb_size_t arena_size, HerbErrorFn error_fn);
extern int herb_load(const char* json_buf, herb_size_t json_len);
extern int herb_create(const char* name, const char* type, const char* container);
extern int herb_state(char* buf, int buf_size);
extern int herb_set_prop_int(int entity_id, const char* property, int64_t value);
extern int herb_container_count(const char* container);
extern int herb_container_entity(const char* container, int idx);
extern const char* herb_entity_name(int entity_id);
extern int64_t herb_entity_prop_int(int entity_id, const char* property, int64_t default_val);
extern const char* herb_entity_prop_str(int entity_id, const char* property, const char* default_val);
extern const char* herb_entity_location(int entity_id);
extern int herb_entity_total(void);
extern herb_size_t herb_arena_usage(void);
extern herb_size_t herb_arena_total(void);

/* Tension query/toggle API */
extern int herb_tension_count(void);
extern const char* herb_tension_name(int idx);
extern int herb_tension_priority(int idx);
extern int herb_tension_enabled(int idx);
extern void herb_tension_set_enabled(int idx, int enabled);
extern int herb_tension_owner(int idx);

/* Tension creation API — loadable behavioral programs */
extern int herb_tension_create(const char* name, int priority, int owner_entity,
                                const char* run_container_name);
extern int herb_tension_match_in(int tidx, const char* bind_name, const char* container,
                                  int select_mode);
extern int herb_tension_match_in_where(int tidx, const char* bind_name, const char* container,
                                         int select_mode, void* where_expr);
extern int herb_tension_emit_set(int tidx, const char* entity_bind, const char* property,
                                   void* value_expr);
extern int herb_tension_emit_move(int tidx, const char* move_type, const char* entity_bind,
                                    const char* to_container);
extern void* herb_expr_int(int64_t val);
extern void* herb_expr_prop(const char* prop_name, const char* of_bind);
extern void* herb_expr_binary(const char* op, void* left, void* right);
extern int herb_remove_owner_tensions(int owner_entity);

/* Runtime container creation API */
extern int herb_create_container(const char* name, int kind);

/* Program fragment loading — loads .herb binary as process behavior */
extern int herb_load_program(const uint8_t* data, herb_size_t len,
                              int owner_entity, const char* run_container);

/* Tension removal by name — for hot-swappable system policy */
extern int herb_remove_tension_by_name(const char* name);

/* Forward declarations — text input helpers */
extern void create_key_signal(int ascii_code);
extern int read_cmdline(char* buf, int bufsz);
extern void handle_submission(void);

/* Forward declarations — mechanism functions (Session 54) */
extern void cmd_timer(void);
extern void cmd_boost(void);
extern void cmd_step(void);
#ifdef KERNEL_MODE
extern void cmd_alloc_page(void);
extern void cmd_open_fd(void);
extern void cmd_free_page(void);
extern void cmd_close_fd(void);
extern void cmd_toggle_game(void);
extern void cmd_send_msg(void);
extern void cmd_tension_prev(void);
extern void cmd_tension_next(void);
extern void cmd_tension_toggle(void);
extern void cmd_ham_test(void);
#endif

/* Forward declarations — HERB-based command dispatch (Session 53-54) */
#ifdef KERNEL_MODE
extern void dispatch_cmd_from_route(int cmd_id, int arg_id);
extern void dispatch_mech_action(int action);
extern void dispatch_text_command(int text_key, int arg_key, const char* buf);
extern void post_dispatch(int sig_eid, int ops, const char* cpu0_name);
extern void cleanup_terminated(void);
extern void handle_shell_action(void);
extern void cmd_swap_policy_from_herb(int which);
extern void cmd_spawn(int requested_type);
#endif

/* ============================================================
 * ISR stubs (from kernel_entry.asm)
 * ============================================================ */

extern void timer_isr_stub(void);
extern void keyboard_isr_stub(void);
extern void mouse_isr_stub(void);

/* Volatile flags set by ISRs */
extern volatile uint8_t volatile_timer_fired;
extern volatile uint8_t volatile_key_scancode;
extern volatile uint8_t volatile_key_pressed;
extern volatile uint8_t mouse_ring[64];
extern volatile uint8_t mouse_ring_head;
extern volatile uint8_t mouse_ring_tail;

/* ============================================================
 * PORT I/O
 * ============================================================ */

/* Port I/O — implemented in herb_hw.asm (Phase 2) */
extern void outb(uint16_t port, uint8_t val);
extern uint8_t inb(uint16_t port);
extern void io_wait(void);

/* Privileged CPU ops — implemented in herb_hw.asm (Phase 2, Session 59) */
extern void hw_sti(void);
extern void hw_hlt(void);

/* ============================================================
 * SERIAL PORT (COM1: 0x3F8)
 * ============================================================ */

/* Serial port — implemented in herb_hw.asm (Phase 2, Session 60) */
extern void serial_init(void);
extern void serial_putchar(char c);
extern void serial_print(const char* s);

/* PIC/PIT — implemented in herb_hw.asm (Phase 2, Session 61) */
extern void pic_remap(void);
extern void pit_init(int hz);

/* PS/2 mouse — implemented in herb_hw.asm (Phase 2, Session 62) */
extern void ps2_wait_input(void);
extern void ps2_wait_output(void);
extern void mouse_write(uint8_t data);
extern uint8_t mouse_read(void);
extern void mouse_init(void);

/* HAM — HERB Abstract Machine (Phase 3, Sessions 64-67) */
extern int ham_run(uint8_t* bytecode_ptr, int bytecode_len);
extern int ham_compile_all(uint8_t* buf, int buf_size, int* out_count);
extern int ham_run_ham(int max_steps);
extern void ham_mark_dirty(void);
extern int ham_get_compiled_count(void);
extern int ham_get_bytecode_len(void);
extern int intern(const char* s);
extern int ham_dbg_thdr, ham_dbg_fail, ham_dbg_tend, ham_dbg_skip;
extern int ham_dbg_action, ham_dbg_scan_nz, ham_dbg_require, ham_dbg_guard;

void serial_print_int(int val) {
    char buf[16];
    herb_snprintf(buf, sizeof(buf), "%d", val);
    serial_print(buf);
}


/* ============================================================
 * VGA TEXT MODE
 * ============================================================ */

#define VGA_WIDTH  80
#define VGA_HEIGHT 25
#define VGA_ADDR   0xB8000

#define VGA_BLACK   0x0
#define VGA_BLUE    0x1
#define VGA_GREEN   0x2
#define VGA_CYAN    0x3
#define VGA_RED     0x4
#define VGA_MAGENTA 0x5
#define VGA_BROWN   0x6
#define VGA_LGRAY   0x7
#define VGA_DGRAY   0x8
#define VGA_LBLUE   0x9
#define VGA_LGREEN  0xA
#define VGA_LCYAN   0xB
#define VGA_LRED    0xC
#define VGA_LMAGENTA 0xD
#define VGA_YELLOW  0xE
#define VGA_WHITE   0xF

static volatile uint16_t* const vga_buffer = (volatile uint16_t*)VGA_ADDR;
static int vga_row = 0;
static int vga_col = 0;
static uint8_t vga_color = 0x0F;

void vga_set_color(uint8_t fg, uint8_t bg) {
    vga_color = (bg << 4) | (fg & 0x0F);
}

void vga_clear(void) {
    uint16_t blank = (uint16_t)(' ') | ((uint16_t)vga_color << 8);
    for (int i = 0; i < VGA_WIDTH * VGA_HEIGHT; i++) {
        vga_buffer[i] = blank;
    }
    vga_row = 0;
    vga_col = 0;
}

static void vga_putchar(char c) {
    if (c == '\n') {
        vga_col = 0;
        vga_row++;
        return;
    }
    if (c == '\r') {
        vga_col = 0;
        return;
    }
    if (vga_row >= VGA_HEIGHT || vga_col >= VGA_WIDTH) return;
    int offset = vga_row * VGA_WIDTH + vga_col;
    vga_buffer[offset] = (uint16_t)c | ((uint16_t)vga_color << 8);
    vga_col++;
}

void vga_print(const char* s) {
    while (*s) {
        vga_putchar(*s++);
    }
}

static void vga_print_at(int row, int col, const char* s) {
    vga_row = row;
    vga_col = col;
    vga_print(s);
}

void vga_print_int(int val) {
    char buf[16];
    herb_snprintf(buf, sizeof(buf), "%d", val);
    vga_print(buf);
}

/* Fill a row with spaces in the current color */
static void vga_clear_row(int row) {
    uint16_t blank = (uint16_t)(' ') | ((uint16_t)vga_color << 8);
    for (int c = 0; c < VGA_WIDTH; c++) {
        vga_buffer[row * VGA_WIDTH + c] = blank;
    }
}

/* Print a string padded to exactly `width` characters */
static void vga_print_padded(const char* s, int width) {
    int i = 0;
    while (s[i] && i < width) {
        vga_putchar(s[i]);
        i++;
    }
    while (i < width) {
        vga_putchar(' ');
        i++;
    }
}

/* ============================================================
 * PS/2 SCANCODE TABLE (Set 1, US QWERTY)
 * ============================================================ */

const char scancode_to_ascii[128] = {
    0,   27, '1', '2', '3', '4', '5', '6',  /* 0x00-0x07 */
    '7', '8', '9', '0', '-', '=',  8,   9,  /* 0x08-0x0F (BS, TAB) */
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', /* 0x10-0x17 */
    'o', 'p', '[', ']', '\n', 0,  'a', 's',  /* 0x18-0x1F (ENTER, LCTRL) */
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', /* 0x20-0x27 */
    '\'', '`', 0,  '\\', 'z', 'x', 'c', 'v',/* 0x28-0x2F (LSHIFT) */
    'b', 'n', 'm', ',', '.', '/', 0,  '*',   /* 0x30-0x37 (RSHIFT) */
    0,  ' ',  0,   0,   0,   0,   0,   0,    /* 0x38-0x3F (LALT,SPACE,CAPS,F1-F4) */
    0,   0,   0,   0,   0,   0,   0,   0,    /* 0x40-0x47 (F5-F10,NUM,SCROLL) */
    0,   0,   0,   0,   0,   0,   0,   0,    /* 0x48-0x4F */
    0,   0,   0,   0,   0,   0,   0,   0,    /* 0x50-0x57 */
    0,   0,   0,   0,   0,   0,   0,   0,    /* 0x58-0x5F */
    0,   0,   0,   0,   0,   0,   0,   0,    /* 0x60-0x67 */
    0,   0,   0,   0,   0,   0,   0,   0,    /* 0x68-0x6F */
    0,   0,   0,   0,   0,   0,   0,   0,    /* 0x70-0x77 */
    0,   0,   0,   0,   0,   0,   0,   0,    /* 0x78-0x7F */
};

/* IDT setup moved to herb_kernel.asm (Phase A) */

/* ============================================================
 * ARENA MEMORY
 * ============================================================ */

#define ARENA_ADDR  0x800000
#define ARENA_SIZE  (4 * 1024 * 1024)

/* ============================================================
 * PS/2 MOUSE — INITIALIZATION AND PACKET ASSEMBLY
 *
 * The PS/2 mouse is the auxiliary device on the 8042 controller.
 * IRQ12 (vector 44 after PIC remap). Mouse sends 3-byte packets:
 *   byte 0: buttons + flags (bit 0=left, bit 1=right, bit 4=x sign, bit 5=y sign)
 *   byte 1: X delta (signed via bit 4 of byte 0)
 *   byte 2: Y delta (signed via bit 5 of byte 0)
 *
 * The ISR fires once per byte. We accumulate 3 bytes before processing.
 * ============================================================ */

/* Mouse state */
int mouse_x = 400;       /* absolute cursor position */
int mouse_y = 300;
int mouse_cycle = 0;     /* packet assembly: 0, 1, 2 */
uint8_t mouse_packet[3]; /* accumulated packet bytes */
int mouse_buttons = 0;   /* current button state */
int mouse_left_clicked = 0;   /* flag: left button just clicked */
int mouse_moved = 0;     /* flag: cursor position changed */

/* Selected process tracking (graphics mode only) */
#ifdef GRAPHICS_MODE
int selected_eid = -1;   /* entity ID of selected process, -1 = none */
#endif

/* Cursor HERB entity ID (for updating x,y properties) */
int cursor_eid = -1;

/* Tension panel state */
int selected_tension_idx = -1;  /* -1 = no selection */


/* Process a complete 3-byte mouse packet */
void mouse_handle_packet(void) {
    uint8_t flags = mouse_packet[0];
    int dx = (int)mouse_packet[1];
    int dy = (int)mouse_packet[2];

    /* Apply sign extension from flags byte */
    if (flags & 0x10) dx |= 0xFFFFFF00;  /* X sign bit */
    if (flags & 0x20) dy |= 0xFFFFFF00;  /* Y sign bit */

    /* Discard overflow packets */
    if (flags & 0xC0) return;

    /* Update absolute position. PS/2 Y axis is inverted (positive = up). */
    mouse_x += dx;
    mouse_y -= dy;  /* negate: screen Y increases downward */

    /* Clamp to screen bounds */
    if (mouse_x < 0) mouse_x = 0;
    if (mouse_x >= 800) mouse_x = 799;
    if (mouse_y < 0) mouse_y = 0;
    if (mouse_y >= 600) mouse_y = 599;

    /* Detect left button click (transition from not-pressed to pressed) */
    int left_now = flags & 0x01;
    if (left_now && !(mouse_buttons & 0x01)) {
        mouse_left_clicked = 1;
    }
    mouse_buttons = flags & 0x07;  /* bits 0-2: left, right, middle */

    /* Mark that cursor moved (for rendering) */
    if (dx != 0 || dy != 0) {
        mouse_moved = 1;
    }
}

/* ============================================================
 * HERB ERROR HANDLER
 * ============================================================ */

void herb_error_handler(int severity, const char* message) {
    (void)severity;
    uint8_t old_color = vga_color;
    vga_set_color(VGA_RED, VGA_BLACK);
    vga_print_at(24, 0, "ERR: ");
    vga_print(message);
    vga_color = old_color;
    serial_print("[ERROR] ");
    serial_print(message);
    serial_print("\n");
}

/* ============================================================
 * DISPLAY LAYOUT
 *
 * Row  0:    Banner
 * Row  1:    Stats (ticks, ops, arena, processes, last key)
 * Row  2:    (blank separator)
 * Row  3:    Command legend
 * Row  4:    (blank separator)
 * Row  5:    Process table header
 * Row  6-15: Process rows (up to 10)
 * Row 16:    (blank separator)
 * Row 17:    Container/resource summary header
 * Row 18-21: Container/resource counts
 * Row 22:    (blank separator)
 * Row 23:    Last action log
 * Row 24:    Error line (if any)
 * ============================================================ */

#define ROW_BANNER    0
#define ROW_STATS     1
#define ROW_LEGEND    3
#define ROW_TABLE_HDR 5
#define ROW_TABLE     6
#define MAX_TABLE_ROWS 10
#define ROW_SUMMARY   17
#define ROW_LOG       23
#define ROW_ERROR     24

/* Global state */
int timer_count = 0;
int total_ops = 0;
int signal_counter = 0;
int process_counter = 0;
int buffer_eid = -1;       /* Shared buffer entity for producer/consumer */
char last_action[80] = "";
char last_key_name[16] = "";

/* Scheduling policy label — derived from HERB ShellCtl.current_policy (Phase 5c) */

/* Text input state (Session 49) */
#ifdef KERNEL_MODE
int input_ctl_eid = -1;  /* InputCtl entity ID (tracks mode, submitted) */
#endif

/* Shell process state (Session 50) */
#ifdef KERNEL_MODE
int shell_ctl_eid = -1;  /* ShellCtl entity ID (tracks action) */
int shell_eid = -1;      /* Shell process entity ID */
#endif

/* Spawn control state (Session 52) */
#ifdef KERNEL_MODE
int spawn_ctl_eid = -1;  /* SpawnCtl entity ID (tracks spawn decisions) */
#endif

/* Game world state */
#ifdef KERNEL_MODE
int game_ctl_eid = -1;
int player_eid = -1;
#endif

/* Display control state (Session 55) */
#ifdef KERNEL_MODE
int display_ctl_eid = -1;  /* DisplayCtl entity ID (max_terminated, max_procs_per_region, timer_interval, buffer_capacity) */
int timer_interval = 300;  /* Auto-timer interval in ticks (read from DisplayCtl at boot) */
int buffer_capacity = 20;  /* Shared buffer max capacity (read from DisplayCtl at boot) */
#endif

/* ============================================================
 * SCOPED RESOURCE HELPERS
 *
 * Query per-entity scoped container counts.
 * Scoped containers are named: "entity_name::scope_name"
 * ============================================================ */

/* scoped_count — moved to herb_kernel.asm (Phase C) */
#ifdef KERNEL_MODE
extern int scoped_count(int entity_id, const char* scope_name);
#endif

/* ============================================================
 * DRAW: Banner
 * ============================================================ */
static void draw_banner(void) {
    vga_set_color(VGA_BLACK, VGA_CYAN);
    vga_clear_row(ROW_BANNER);
    vga_print_at(ROW_BANNER, 2, OS_TITLE);
    vga_print_at(ROW_BANNER, 60, OS_SUBTITLE);
}

/* ============================================================
 * DRAW: Stats bar
 * ============================================================ */
void draw_stats(void) {
    vga_set_color(VGA_WHITE, VGA_BLUE);
    vga_clear_row(ROW_STATS);
    vga_print_at(ROW_STATS, 1, "Tick:");
    vga_print_int(timer_count / 100);

    vga_print("  Ops:");
    vga_print_int(total_ops);

    vga_print("  Arena:");
    {
        char buf[16];
        herb_snprintf(buf, sizeof(buf), "%d", (int)(herb_arena_usage() / 1024));
        vga_print(buf);
    }
    vga_print("KB");

    int n_proc = herb_container_count(CN_READY)
               + herb_container_count(CN_CPU0)
               + herb_container_count(CN_BLOCKED);
    vga_print("  Procs:");
    vga_print_int(n_proc < 0 ? 0 : n_proc);

#ifdef KERNEL_MODE
    vga_print("  Sched:");
    {
        int cp = (shell_ctl_eid >= 0) ? (int)herb_entity_prop_int(shell_ctl_eid, "current_policy", 0) : 0;
        vga_print(cp == 0 ? "PRIORITY" : "ROUND-ROBIN");
    }
#endif

    if (last_key_name[0]) {
        vga_print("  Key:[");
        vga_print(last_key_name);
        vga_print("]");
    }
}

/* ============================================================
 * DRAW: Command legend
 * ============================================================ */
static void draw_legend(void) {
    vga_clear_row(ROW_LEGEND);
#ifdef KERNEL_MODE
    /* Legend derived from HERB LEGEND entities (Session 56) */
    int n = herb_container_count(CN_LEGEND);
    if (n <= 0) return;
    /* Sort by order: collect entity IDs and sort by order property */
    int ids[32];
    int orders[32];
    int count = 0;
    for (int i = 0; i < n && count < 32; i++) {
        int eid = herb_container_entity(CN_LEGEND, i);
        if (eid >= 0) {
            ids[count] = eid;
            orders[count] = (int)herb_entity_prop_int(eid, "order", 99);
            count++;
        }
    }
    /* Simple insertion sort by order */
    for (int i = 1; i < count; i++) {
        int key_o = orders[i], key_id = ids[i];
        int j = i - 1;
        while (j >= 0 && orders[j] > key_o) {
            orders[j+1] = orders[j];
            ids[j+1] = ids[j];
            j--;
        }
        orders[j+1] = key_o;
        ids[j+1] = key_id;
    }
    /* Render: yellow key + gray label + space */
    int first = 1;
    for (int i = 0; i < count; i++) {
        const char* key = herb_entity_prop_str(ids[i], "key_text", "?");
        const char* label = herb_entity_prop_str(ids[i], "label_text", "");
        vga_set_color(VGA_YELLOW, VGA_BLACK);
        if (first) { vga_print_at(ROW_LEGEND, 1, key); first = 0; }
        else vga_print(key);
        vga_set_color(VGA_LGRAY, VGA_BLACK);
        vga_print(label);
        vga_print(" ");
    }
#else
    vga_set_color(VGA_YELLOW, VGA_BLACK);
    vga_print_at(ROW_LEGEND, 1, "N");
    vga_set_color(VGA_LGRAY, VGA_BLACK);
    vga_print("ew ");
    vga_set_color(VGA_YELLOW, VGA_BLACK);
    vga_print("K");
    vga_set_color(VGA_LGRAY, VGA_BLACK);
    vga_print("ill ");
    vga_set_color(VGA_YELLOW, VGA_BLACK);
    vga_print("B");
    vga_set_color(VGA_LGRAY, VGA_BLACK);
    vga_print("lk ");
    vga_set_color(VGA_YELLOW, VGA_BLACK);
    vga_print("U");
    vga_set_color(VGA_LGRAY, VGA_BLACK);
    vga_print("nblk ");
    vga_set_color(VGA_YELLOW, VGA_BLACK);
    vga_print("T");
    vga_set_color(VGA_LGRAY, VGA_BLACK);
    vga_print("mr ");
    vga_set_color(VGA_YELLOW, VGA_BLACK);
    vga_print("+");
    vga_set_color(VGA_LGRAY, VGA_BLACK);
    vga_print("Boost ");
    vga_set_color(VGA_YELLOW, VGA_BLACK);
    vga_print("Space");
    vga_set_color(VGA_LGRAY, VGA_BLACK);
    vga_print("=Step");
#endif
}

/* ============================================================
 * DRAW: Process table
 * ============================================================ */

static void draw_process_row(int row, int entity_id, int index) {
    const char* name = herb_entity_name(entity_id);
    const char* loc  = herb_entity_location(entity_id);
    int64_t pri  = herb_entity_prop_int(entity_id, "priority", 0);
    int64_t ts   = herb_entity_prop_int(entity_id, "time_slice", 0);

    /* Determine state color */
    uint8_t fg = VGA_LGRAY;
    char state_char = '?';
    if (loc[0] == 'C' || (loc[0] == 'p' && loc[4] == '.' && loc[5] == 'C')) {
        fg = VGA_LGREEN;
        state_char = 'R';  /* Running */
    } else if (loc[0] == 'R' || (loc[0] == 'p' && loc[5] == 'R')) {
        fg = VGA_YELLOW;
        state_char = 'S';  /* Scheduled/ready */
    } else if (loc[0] == 'B' || (loc[0] == 'p' && loc[5] == 'B')) {
        fg = VGA_LRED;
        state_char = 'B';  /* Blocked */
    } else if (loc[0] == 'T' || (loc[0] == 'p' && loc[5] == 'T')) {
        fg = VGA_DGRAY;
        state_char = 'X';  /* Terminated */
    }

    vga_set_color(VGA_LGRAY, VGA_BLACK);
    vga_clear_row(row);

    /* Index */
    vga_print_at(row, 1, "");
    vga_print_int(index);

    /* State indicator with color */
    vga_set_color(fg, VGA_BLACK);
    vga_print_at(row, 4, "");
    vga_putchar('[');
    vga_putchar(state_char);
    vga_putchar(']');

    /* Name */
    vga_set_color(VGA_WHITE, VGA_BLACK);
    vga_print_at(row, 9, "");
    vga_print_padded(name, 10);

    /* Location (abbreviated) */
    vga_set_color(fg, VGA_BLACK);
    vga_print_at(row, 20, "");
    /* Strip "proc." prefix for display if present */
    const char* disp_loc = loc;
#ifdef KERNEL_MODE
    if (loc[0] == 'p' && loc[1] == 'r' && loc[2] == 'o' && loc[3] == 'c' && loc[4] == '.') {
        disp_loc = loc + 5;
    }
#endif
    vga_print_padded(disp_loc, 12);

    /* Priority */
    vga_set_color(VGA_LCYAN, VGA_BLACK);
    vga_print_at(row, 33, "p=");
    vga_print_int((int)pri);

    /* Time slice */
    vga_print_at(row, 39, "ts=");
    vga_print_int((int)ts);

#ifdef KERNEL_MODE
    /* Scoped resources: MEM and FD counts */
    int mf = scoped_count(entity_id, "MEM_FREE");
    int mu = scoped_count(entity_id, "MEM_USED");
    int ff = scoped_count(entity_id, "FD_FREE");
    int fo = scoped_count(entity_id, "FD_OPEN");

    vga_set_color(VGA_LMAGENTA, VGA_BLACK);
    vga_print_at(row, 46, "M:");
    vga_print_int(mf);
    vga_putchar('/');
    vga_print_int(mu);

    vga_print("  F:");
    vga_print_int(ff);
    vga_putchar('/');
    vga_print_int(fo);
#endif
}

static void draw_process_table(void) {
    /* Header */
    vga_set_color(VGA_CYAN, VGA_BLACK);
    vga_clear_row(ROW_TABLE_HDR);
    vga_print_at(ROW_TABLE_HDR, 1, "#");
    vga_print_at(ROW_TABLE_HDR, 4, "ST");
    vga_print_at(ROW_TABLE_HDR, 9, "NAME");
    vga_print_at(ROW_TABLE_HDR, 20, "LOCATION");
    vga_print_at(ROW_TABLE_HDR, 33, "PRI");
    vga_print_at(ROW_TABLE_HDR, 39, "TS");
#ifdef KERNEL_MODE
    vga_print_at(ROW_TABLE_HDR, 46, "MEM(f/u)");
    vga_print_at(ROW_TABLE_HDR, 57, "FD(f/o)");
#endif

    int row = ROW_TABLE;
    int shown = 0;

    /* Running (CPU0) */
    {
        int n = herb_container_count(CN_CPU0);
        for (int i = 0; i < n && shown < MAX_TABLE_ROWS; i++) {
            int eid = herb_container_entity(CN_CPU0, i);
            if (eid >= 0) {
                draw_process_row(row++, eid, shown);
                shown++;
            }
        }
    }

    /* Ready */
    {
        int n = herb_container_count(CN_READY);
        for (int i = 0; i < n && shown < MAX_TABLE_ROWS; i++) {
            int eid = herb_container_entity(CN_READY, i);
            if (eid >= 0) {
                draw_process_row(row++, eid, shown);
                shown++;
            }
        }
    }

    /* Blocked */
    {
        int n = herb_container_count(CN_BLOCKED);
        for (int i = 0; i < n && shown < MAX_TABLE_ROWS; i++) {
            int eid = herb_container_entity(CN_BLOCKED, i);
            if (eid >= 0) {
                draw_process_row(row++, eid, shown);
                shown++;
            }
        }
    }

    /* Terminated (show at most max_terminated from DisplayCtl) */
    {
        int n = herb_container_count(CN_TERMINATED);
        int show_max = 3;
#ifdef KERNEL_MODE
        if (display_ctl_eid >= 0)
            show_max = (int)herb_entity_prop_int(display_ctl_eid, "max_terminated", 3);
#endif
        for (int i = 0; i < n && i < show_max && shown < MAX_TABLE_ROWS; i++) {
            int eid = herb_container_entity(CN_TERMINATED, i);
            if (eid >= 0) {
                draw_process_row(row++, eid, shown);
                shown++;
            }
        }
        if (n > show_max) {
            vga_set_color(VGA_DGRAY, VGA_BLACK);
            vga_clear_row(row);
            vga_print_at(row, 5, "(+");
            vga_print_int(n - show_max);
            vga_print(" terminated)");
            row++;
            shown++;
        }
    }

    /* Clear remaining rows */
    vga_set_color(VGA_LGRAY, VGA_BLACK);
    while (row < ROW_TABLE + MAX_TABLE_ROWS) {
        vga_clear_row(row++);
    }
}

/* ============================================================
 * DRAW: Container / resource summary
 * ============================================================ */

static void draw_summary(void) {
    vga_set_color(VGA_LGRAY, VGA_BLACK);
    for (int r = ROW_SUMMARY; r < ROW_SUMMARY + 5; r++)
        vga_clear_row(r);

    vga_set_color(VGA_CYAN, VGA_BLACK);
    vga_print_at(ROW_SUMMARY, 1, "Containers:");

    vga_set_color(VGA_LGRAY, VGA_BLACK);
    int ready_n = herb_container_count(CN_READY);
    int cpu_n   = herb_container_count(CN_CPU0);
    int blk_n   = herb_container_count(CN_BLOCKED);
    int term_n  = herb_container_count(CN_TERMINATED);
    int sig_n   = herb_container_count(CN_SIG_DONE);

    vga_print_at(ROW_SUMMARY + 1, 3, "READY=");
    vga_print_int(ready_n < 0 ? 0 : ready_n);
    vga_print("  CPU0=");
    vga_print_int(cpu_n < 0 ? 0 : cpu_n);
    vga_print("  BLOCKED=");
    vga_print_int(blk_n < 0 ? 0 : blk_n);
    vga_print("  TERM=");
    vga_print_int(term_n < 0 ? 0 : term_n);
    vga_print("  SigDone=");
    vga_print_int(sig_n < 0 ? 0 : sig_n);

#ifdef KERNEL_MODE
    /* Per-process resource summary */
    vga_set_color(VGA_CYAN, VGA_BLACK);
    vga_print_at(ROW_SUMMARY + 2, 1, "Resources:");
    int row = ROW_SUMMARY + 3;
    const char* containers[] = { CN_CPU0, CN_READY, CN_BLOCKED };
    for (int ci = 0; ci < 3 && row < ROW_SUMMARY + 5; ci++) {
        int n = herb_container_count(containers[ci]);
        for (int i = 0; i < n && row < ROW_SUMMARY + 5; i++) {
            int eid = herb_container_entity(containers[ci], i);
            if (eid < 0) continue;
            const char* ename = herb_entity_name(eid);
            int mf = scoped_count(eid, "MEM_FREE");
            int mu = scoped_count(eid, "MEM_USED");
            int ff = scoped_count(eid, "FD_FREE");
            int fo = scoped_count(eid, "FD_OPEN");
            int inbox = scoped_count(eid, "INBOX");

            vga_set_color(VGA_LGRAY, VGA_BLACK);
            vga_print_at(row, 3, "");
            vga_print_padded(ename, 8);
            vga_print(" MEM:");
            vga_print_int(mf);
            vga_print("f/");
            vga_print_int(mu);
            vga_print("u  FD:");
            vga_print_int(ff);
            vga_print("f/");
            vga_print_int(fo);
            vga_print("o  IN:");
            vga_print_int(inbox);
            row++;
        }
    }
#endif
}

/* ============================================================
 * DRAW: Action log
 * ============================================================ */

static void draw_log(void) {
    vga_set_color(VGA_LGREEN, VGA_BLACK);
    vga_clear_row(ROW_LOG);
    if (last_action[0]) {
        vga_print_at(ROW_LOG, 1, "> ");
        vga_print(last_action);
    }
}

/* ============================================================
 * GRAPHICS MODE: Framebuffer Rendering
 *
 * When GRAPHICS_MODE is defined, HERB state is rendered as
 * colored rectangles in container regions — a live visualization
 * of the HERB runtime's internal state.
 *
 * Layout (800x600):
 *   y=0:    Banner bar (30px)
 *   y=30:   Stats bar (20px)
 *   y=50:   Key legend (20px)
 *   y=76:   Main area — container regions (left) + tension panel (right)
 *   y=486:  Action log (20px)
 *   y=510:  Container summary (20px)
 *   y=534:  Resource legend (20px)
 * ============================================================ */

#ifdef GRAPHICS_MODE

/* Layout constants */
#define GFX_BANNER_Y    0
#define GFX_BANNER_H    30
#define GFX_STATS_Y     30
#define GFX_STATS_H     20
#define GFX_LEGEND_Y    50
#define GFX_LEGEND_H    20
#define GFX_MAIN_Y      76
#define GFX_MAIN_H      404
#define GFX_LOG_Y       486
#define GFX_LOG_H       20
#define GFX_SUMMARY_Y   510
#define GFX_SUMMARY_H   20
#define GFX_RESLEG_Y    534
#define GFX_RESLEG_H    20

/* Game world layout */
#define GAME_TILE_SIZE   50       /* pixels per tile */
#define GAME_GRID_X      16      /* grid left edge */
#define GAME_GRID_Y      80      /* grid top edge */
#define GAME_GRID_W      (8 * GAME_TILE_SIZE)   /* 400px */
#define GAME_GRID_H      (8 * GAME_TILE_SIZE)   /* 400px */
#define GAME_INFO_X      432     /* info panel left edge */
#define GAME_INFO_W      356     /* info panel width */

/* Tension panel (right sidebar) */
#define GFX_TENS_X      548
#define GFX_TENS_Y      76
#define GFX_TENS_W      244
#define GFX_TENS_H      388
#define GFX_TENS_ROW_H  16

/* Container region positions in the main area */
#define GFX_PAD          8
#define GFX_CONT_W      ((FB_WIDTH - GFX_PAD * 3) / 2)
#define GFX_CONT_H      ((GFX_MAIN_H - GFX_PAD * 3) / 2)

/* CPU0 region: top-left */
#define GFX_CPU0_X      GFX_PAD
#define GFX_CPU0_Y      GFX_MAIN_Y
/* READY region: top-right */
#define GFX_READY_X     (GFX_PAD * 2 + GFX_CONT_W)
#define GFX_READY_Y     GFX_MAIN_Y
/* BLOCKED region: bottom-left */
#define GFX_BLOCK_X     GFX_PAD
#define GFX_BLOCK_Y     (GFX_MAIN_Y + GFX_CONT_H + GFX_PAD)
/* TERMINATED region: bottom-right */
#define GFX_TERM_X      (GFX_PAD * 2 + GFX_CONT_W)
#define GFX_TERM_Y      (GFX_MAIN_Y + GFX_CONT_H + GFX_PAD)

/* Process rect sizing */
#define GFX_PROC_W      120
#define GFX_PROC_PAD    6
#ifdef KERNEL_MODE
#define GFX_PROC_H      56   /* taller to show resources */
#else
#define GFX_PROC_H      40
#endif

/* ============================================================
 * SURFACE STATE → COLORS (Session 55: colors as HERB entity properties)
 *
 * Display tensions set surface.state AND border_color/fill_color directly.
 * C reads border_color and fill_color from HERB entities — no lookup table.
 * Region entities carry their own colors. Process surfaces get colors from
 * sync tensions (sync_running, sync_ready, sync_blocked, sync_terminated).
 * HERB is policy (color decisions). C is mechanism (pixels).
 * ============================================================ */

/* Color lookup arrays removed (Session 55).
 * Colors now live on HERB entities: border_color/fill_color on region Surfaces
 * and process Surfaces. Sync tensions set them. C reads directly. */

/* Region titles (indexed by region_id from HERB Surface entity) */
static const char* region_titles[] = {
    "CPU0 (RUNNING)", "READY", "BLOCKED", "TERMINATED"
};

/* Kernel containers corresponding to each region */
static const char* region_containers[] = {
    CN_CPU0, CN_READY, CN_BLOCKED, CN_TERMINATED
};

/* ---- Draw processes from a container into a region ---- */
static void gfx_draw_procs_in_region(int rx, int ry, int rw, int rh,
                                      const char* container_name,
                                      uint32_t fallback_border, uint32_t fallback_fill) {
    int n = herb_container_count(container_name);
    if (n < 0) n = 0;

    /* Layout processes in a grid within the region */
    int content_x = rx + 4;
    int content_y = ry + 22;  /* below title bar */
    int content_w = rw - 8;
    int content_h = rh - 26;

    /* How many process rects fit per row? */
    int cols = content_w / (GFX_PROC_W + GFX_PROC_PAD);
    if (cols < 1) cols = 1;

    int max_per_region = 12;
#ifdef KERNEL_MODE
    if (display_ctl_eid >= 0)
        max_per_region = (int)herb_entity_prop_int(display_ctl_eid, "max_procs_per_region", 12);
#endif

    for (int i = 0; i < n && i < max_per_region; i++) {
        int eid = herb_container_entity(container_name, i);
        if (eid < 0) continue;

        const char* name = herb_entity_name(eid);
        int64_t pri = herb_entity_prop_int(eid, "priority", 0);
        int64_t ts = herb_entity_prop_int(eid, "time_slice", 0);

        /* In KERNEL_MODE, read border_color/fill_color directly from HERB
         * Surface entity — sync tensions set actual pixel colors (Session 55).
         * In flat mode, use fallback colors from the container region. */
        uint32_t border_col = fallback_border;
        uint32_t fill_col = fallback_fill;
#ifdef KERNEL_MODE
        {
            const char* pname = herb_entity_name(eid);
            char surf_cont[64];
            herb_snprintf(surf_cont, sizeof(surf_cont), "%s::SURFACE", pname);
            int sc = herb_container_count(surf_cont);
            if (sc > 0) {
                int sid = herb_container_entity(surf_cont, 0);
                if (sid >= 0) {
                    int bc = (int)herb_entity_prop_int(sid, "border_color", 0);
                    int fc = (int)herb_entity_prop_int(sid, "fill_color", 0);
                    if (bc != 0) border_col = (uint32_t)bc;
                    if (fc != 0) fill_col = (uint32_t)fc;
                }
            }
        }
#endif

        int col = i % cols;
        int row = i / cols;
        int px = content_x + col * (GFX_PROC_W + GFX_PROC_PAD);
        int py = content_y + row * (GFX_PROC_H + GFX_PROC_PAD);

        /* Skip if out of bounds */
        if (py + GFX_PROC_H > ry + rh) break;

        fb_draw_process(px, py, GFX_PROC_W, GFX_PROC_H,
                        name, (int)pri, (int)ts,
                        border_col, fill_col);

#ifdef KERNEL_MODE
        /* Draw selection highlight: thick bright border if selected */
        if (herb_entity_prop_int(eid, "selected", 0) == 1) {
            fb_draw_rect2(px - 2, py - 2, GFX_PROC_W + 4, GFX_PROC_H + 4, COL_SELECTED);
            fb_draw_rect(px - 3, py - 3, GFX_PROC_W + 6, GFX_PROC_H + 6, COL_SELECTED);
        }

        /* Draw resource indicators */
        int mf = scoped_count(eid, "MEM_FREE");
        int mu = scoped_count(eid, "MEM_USED");
        int ff = scoped_count(eid, "FD_FREE");
        int fo = scoped_count(eid, "FD_OPEN");
        fb_draw_resources(px + 4, py + 38, mf, mu, ff, fo);

        /* Draw program state: producer or consumer */
        {
            int64_t produced = herb_entity_prop_int(eid, "produced", -1);
            int64_t consumed = herb_entity_prop_int(eid, "consumed", -1);
            if (produced >= 0) {
                char pbuf[20];
                herb_snprintf(pbuf, sizeof(pbuf), ">%d", (int)produced);
                fb_draw_string(px + 60, py + 38, pbuf, 0x00FF9900, fill_col);
            } else if (consumed >= 0) {
                char pbuf[20];
                herb_snprintf(pbuf, sizeof(pbuf), "<%d", (int)consumed);
                fb_draw_string(px + 60, py + 38, pbuf, 0x0066CCFF, fill_col);
            }
        }
#endif
    }

    /* Show overflow count */
    if (n > max_per_region) {
        char buf[32];
        herb_snprintf(buf, sizeof(buf), "+%d more", n - max_per_region);
        fb_draw_string(content_x, content_y + content_h - 16, buf, COL_TEXT_DIM, 0);
    }
}

/* ---- Tension panel: rules as visible, selectable, toggleable objects ----
 *
 * This renders the OS's tensions (energy gradients) as first-class visual
 * objects in the display. Each tension is a row showing its name, priority,
 * and enabled state. The selected tension has a highlight border.
 *
 * Tensions use cool blue/cyan tones to visually distinguish RULES (forces
 * that cause movement) from THINGS (entities that are moved).
 */
#ifdef KERNEL_MODE
static void gfx_draw_tension_panel(void) {
    int nt = herb_tension_count();
    int enabled_count = 0;
    for (int i = 0; i < nt; i++)
        if (herb_tension_enabled(i)) enabled_count++;

    /* Panel background + border */
    fb_fill_rect(GFX_TENS_X, GFX_TENS_Y, GFX_TENS_W, GFX_TENS_H, COL_TENS_BG);
    fb_draw_rect(GFX_TENS_X, GFX_TENS_Y, GFX_TENS_W, GFX_TENS_H, COL_TENS_BORDER);

    /* Title */
    {
        int tx = fb_draw_string(GFX_TENS_X + 6, GFX_TENS_Y + 3, "TENSIONS", COL_TENS_TITLE, COL_TENS_BG);
        /* Enabled count */
        char buf[16];
        herb_snprintf(buf, sizeof(buf), " %d/%d", enabled_count, nt);
        fb_draw_string(tx, GFX_TENS_Y + 3, buf, COL_TEXT_DIM, COL_TENS_BG);
    }

    /* Separator line below title */
    fb_hline(GFX_TENS_X + 2, GFX_TENS_Y + 18, GFX_TENS_W - 4, COL_TENS_BORDER);

    /* Each tension as a row */
    int row_y = GFX_TENS_Y + 22;
    int max_rows = (GFX_TENS_H - 26) / GFX_TENS_ROW_H;

    for (int i = 0; i < nt && i < max_rows; i++) {
        int y = row_y + i * GFX_TENS_ROW_H;
        int en = herb_tension_enabled(i);
        int sel = (i == selected_tension_idx);
        int pri = herb_tension_priority(i);
        const char* name = herb_tension_name(i);

        /* Row background */
        uint32_t row_bg = en ? COL_TENS_ON_BG : COL_TENS_OFF_BG;
        fb_fill_rect(GFX_TENS_X + 2, y, GFX_TENS_W - 4, GFX_TENS_ROW_H - 1, row_bg);

        /* Selection highlight */
        if (sel) {
            fb_draw_rect(GFX_TENS_X + 1, y - 1, GFX_TENS_W - 2, GFX_TENS_ROW_H + 1, COL_TENS_SEL);
        }

        /* Enabled indicator: small colored square */
        uint32_t ind_col = en ? COL_TENS_ON : COL_TENS_OFF;
        fb_fill_rect(GFX_TENS_X + 6, y + 4, 6, 6, ind_col);

        /* Tension name — strip module prefix for compact display */
        const char* display_name = name;
        /* Find last '.' to skip module prefix */
        for (const char* p = name; *p; p++) {
            if (*p == '.') display_name = p + 1;
        }

        /* For process-owned tensions, show owner tag in warm color */
        int owner = herb_tension_owner(i);
        int name_x = GFX_TENS_X + 16;
        if (owner >= 0) {
            /* Draw owner indicator dot in warm color */
            fb_fill_rect(GFX_TENS_X + 6, y + 4, 6, 6,
                          en ? 0x00FF9900 : 0x00664400);  /* orange/dim orange */
        }

        /* Truncate name to fit: ~16 chars max */
        char nbuf[17];
        int ni = 0;
        while (display_name[ni] && ni < 16) {
            nbuf[ni] = display_name[ni];
            ni++;
        }
        nbuf[ni] = '\0';

        uint32_t name_col = en ? (owner >= 0 ? 0x00FFCC66 : COL_TENS_NAME) : COL_TENS_DIM;
        fb_draw_string(name_x, y + 1, nbuf, name_col, row_bg);

        /* Priority number */
        char pbuf[8];
        herb_snprintf(pbuf, sizeof(pbuf), "%d", pri);
        fb_draw_string(GFX_TENS_X + GFX_TENS_W - 28, y + 1, pbuf, COL_TENS_PRI, row_bg);
    }

    /* Legend at bottom of panel */
    int leg_y = GFX_TENS_Y + GFX_TENS_H - 16;
    fb_fill_rect(GFX_TENS_X + 2, leg_y, GFX_TENS_W - 4, 14, COL_TENS_BG);
    int lx = GFX_TENS_X + 6;
    lx = fb_draw_string(lx, leg_y + 1, "[", COL_TEXT_DIM, COL_TENS_BG);
    lx = fb_draw_string(lx, leg_y + 1, "]", COL_TEXT_DIM, COL_TENS_BG);
    lx = fb_draw_string(lx, leg_y + 1, "sel ", COL_TEXT_DIM, COL_TENS_BG);
    lx = fb_draw_string(lx, leg_y + 1, "D", COL_TEXT_KEY, COL_TENS_BG);
    fb_draw_string(lx, leg_y + 1, "=toggle", COL_TEXT_DIM, COL_TENS_BG);
}
#endif /* KERNEL_MODE */

/* ---- Game world terrain helpers ---- */
static uint32_t terrain_color(int terrain) {
    switch (terrain) {
        case 0: return COL_TILE_GRASS;
        case 1: return COL_TILE_FOREST;
        case 2: return COL_TILE_WATER;
        case 3: return COL_TILE_STONE;
        case 4: return COL_TILE_DIRT;
        default: return COL_TILE_GRASS;
    }
}

static const char* terrain_name(int terrain) {
    switch (terrain) {
        case 0: return "Grass";
        case 1: return "Forest";
        case 2: return "Water";
        case 3: return "Stone";
        case 4: return "Dirt";
        default: return "???";
    }
}

/* ---- Game world renderer ---- */
#ifdef KERNEL_MODE
static void gfx_draw_game(void) {
    /* --- Tile grid --- */
    int tile_count = herb_container_count(CN_GAME_TILES);
    for (int i = 0; i < tile_count; i++) {
        int eid = herb_container_entity(CN_GAME_TILES, i);
        if (eid < 0) continue;
        int tx = (int)herb_entity_prop_int(eid, "tile_x", 0);
        int ty = (int)herb_entity_prop_int(eid, "tile_y", 0);
        int terrain = (int)herb_entity_prop_int(eid, "terrain", 0);

        int px = GAME_GRID_X + tx * GAME_TILE_SIZE;
        int py = GAME_GRID_Y + ty * GAME_TILE_SIZE;

        /* Fill tile with terrain color */
        fb_fill_rect(px + 1, py + 1, GAME_TILE_SIZE - 2, GAME_TILE_SIZE - 2, terrain_color(terrain));
        /* Grid border */
        fb_draw_rect(px, py, GAME_TILE_SIZE, GAME_TILE_SIZE, COL_TILE_GRID);
    }

    /* --- Tree markers (before player so player draws on top) --- */
    int tree_count = herb_container_count(CN_GAME_TREES);
    for (int i = 0; i < tree_count; i++) {
        int eid = herb_container_entity(CN_GAME_TREES, i);
        if (eid < 0) continue;
        int tx = (int)herb_entity_prop_int(eid, "tile_x", 0);
        int ty = (int)herb_entity_prop_int(eid, "tile_y", 0);

        int px = GAME_GRID_X + tx * GAME_TILE_SIZE;
        int py = GAME_GRID_Y + ty * GAME_TILE_SIZE;

        /* Tree: trunk + canopy */
        int cx = px + GAME_TILE_SIZE / 2;
        int cy = py + GAME_TILE_SIZE / 2;
        fb_fill_rect(cx - 2, cy + 2, 4, 10, COL_TREE_TRUNK);
        fb_fill_rect(cx - 8, cy - 8, 16, 14, COL_TREE);
    }

    /* --- Player marker --- */
    if (player_eid >= 0) {
        int px_tile = (int)herb_entity_prop_int(player_eid, "tile_x", 0);
        int py_tile = (int)herb_entity_prop_int(player_eid, "tile_y", 0);

        int px = GAME_GRID_X + px_tile * GAME_TILE_SIZE;
        int py = GAME_GRID_Y + py_tile * GAME_TILE_SIZE;

        /* Player: bordered bright square in center of tile */
        int margin = 10;
        fb_fill_rect(px + margin, py + margin,
                     GAME_TILE_SIZE - margin * 2, GAME_TILE_SIZE - margin * 2,
                     COL_PLAYER);
        fb_draw_rect(px + margin - 1, py + margin - 1,
                     GAME_TILE_SIZE - margin * 2 + 2, GAME_TILE_SIZE - margin * 2 + 2,
                     COL_PLAYER_BDR);
    }

    /* --- Info panel (right side) --- */
    fb_fill_rect(GAME_INFO_X, GAME_GRID_Y, GAME_INFO_W, GAME_GRID_H, COL_GAME_BG);
    fb_draw_rect(GAME_INFO_X, GAME_GRID_Y, GAME_INFO_W, GAME_GRID_H, COL_BORDER);

    int ix = GAME_INFO_X + 12;
    int iy = GAME_GRID_Y + 12;

    /* Title */
    fb_draw_string(ix, iy, "COMMON HERB", COL_GAME_TITLE, COL_GAME_BG);
    iy += 24;

    /* Player info */
    fb_draw_string(ix, iy, "Player", COL_TEXT_HI, COL_GAME_BG);
    iy += 16;

    if (player_eid >= 0) {
        int ptx = (int)herb_entity_prop_int(player_eid, "tile_x", 0);
        int pty = (int)herb_entity_prop_int(player_eid, "tile_y", 0);
        int hp  = (int)herb_entity_prop_int(player_eid, "hp", 0);

        /* Position */
        int x = fb_draw_string(ix, iy, "Pos: (", COL_TEXT_DIM, COL_GAME_BG);
        x = fb_draw_int(x, iy, ptx, COL_TEXT_VAL, COL_GAME_BG);
        x = fb_draw_string(x, iy, ",", COL_TEXT_DIM, COL_GAME_BG);
        x = fb_draw_int(x, iy, pty, COL_TEXT_VAL, COL_GAME_BG);
        fb_draw_string(x, iy, ")", COL_TEXT_DIM, COL_GAME_BG);
        iy += 16;

        /* HP */
        x = fb_draw_string(ix, iy, "HP: ", COL_TEXT_DIM, COL_GAME_BG);
        fb_draw_int(x, iy, hp, COL_RUNNING, COL_GAME_BG);
        iy += 16;

        /* Terrain under player */
        for (int i = 0; i < tile_count; i++) {
            int tid = herb_container_entity(CN_GAME_TILES, i);
            if (tid < 0) continue;
            if ((int)herb_entity_prop_int(tid, "tile_x", -1) == ptx &&
                (int)herb_entity_prop_int(tid, "tile_y", -1) == pty) {
                int t = (int)herb_entity_prop_int(tid, "terrain", 0);
                x = fb_draw_string(ix, iy, "On: ", COL_TEXT_DIM, COL_GAME_BG);
                fb_draw_string(x, iy, terrain_name(t), terrain_color(t), COL_GAME_BG);
                break;
            }
        }
        iy += 16;
    }

    iy += 8;

    /* Inventory */
    fb_draw_string(ix, iy, "Inventory", COL_TEXT_HI, COL_GAME_BG);
    iy += 16;

    int wood = herb_container_count(CN_GAME_TREE_GATHERED);
    if (wood < 0) wood = 0;
    {
        int x = fb_draw_string(ix, iy, "Wood: ", COL_TEXT_DIM, COL_GAME_BG);
        fb_draw_int(x, iy, wood, COL_TREE, COL_GAME_BG);
    }
    iy += 16;

    int trees_left = herb_container_count(CN_GAME_TREES);
    if (trees_left < 0) trees_left = 0;
    {
        int x = fb_draw_string(ix, iy, "Trees left: ", COL_TEXT_DIM, COL_GAME_BG);
        fb_draw_int(x, iy, trees_left, COL_TEXT_VAL, COL_GAME_BG);
    }
    iy += 24;

    /* Terrain legend */
    fb_draw_string(ix, iy, "Terrain", COL_TEXT_HI, COL_GAME_BG);
    iy += 16;

    fb_fill_rect(ix, iy + 2, 10, 10, COL_TILE_GRASS);
    fb_draw_string(ix + 14, iy, "Grass", COL_TEXT_DIM, COL_GAME_BG);
    iy += 14;
    fb_fill_rect(ix, iy + 2, 10, 10, COL_TILE_FOREST);
    fb_draw_string(ix + 14, iy, "Forest (trees)", COL_TEXT_DIM, COL_GAME_BG);
    iy += 14;
    fb_fill_rect(ix, iy + 2, 10, 10, COL_TILE_WATER);
    fb_draw_string(ix + 14, iy, "Water (blocked)", COL_TEXT_DIM, COL_GAME_BG);
    iy += 14;
    fb_fill_rect(ix, iy + 2, 10, 10, COL_TILE_STONE);
    fb_draw_string(ix + 14, iy, "Stone (blocked)", COL_TEXT_DIM, COL_GAME_BG);
    iy += 24;

    /* Controls */
    fb_draw_string(ix, iy, "Controls", COL_TEXT_HI, COL_GAME_BG);
    iy += 16;
    fb_draw_string(ix, iy, "Arrows  Move", COL_TEXT_DIM, COL_GAME_BG);
    iy += 14;
    fb_draw_string(ix, iy, "Space   Gather", COL_TEXT_DIM, COL_GAME_BG);
    iy += 14;
    fb_draw_string(ix, iy, "G       OS view", COL_TEXT_DIM, COL_GAME_BG);
}
#endif /* KERNEL_MODE */

/* ---- Full graphics redraw ---- */
static void gfx_draw_full(void) {
    /* Clear to dark background */
    fb_clear(COL_BG);

    /* ---- Banner ---- */
    fb_fill_rect(0, GFX_BANNER_Y, FB_WIDTH, GFX_BANNER_H, COL_BANNER_BG);
    fb_draw_string(12, GFX_BANNER_Y + 8, OS_TITLE, COL_TEXT_HI, COL_BANNER_BG);
    fb_draw_string(FB_WIDTH - 200, GFX_BANNER_Y + 8, OS_SUBTITLE, COL_TEXT_DIM, COL_BANNER_BG);

    /* ---- Stats bar ---- */
    fb_fill_rect(0, GFX_STATS_Y, FB_WIDTH, GFX_STATS_H, COL_STATS_BG);
    {
        int x = 12;
        x = fb_draw_string(x, GFX_STATS_Y + 3, "Tick:", COL_TEXT_DIM, COL_STATS_BG);
        x = fb_draw_int(x, GFX_STATS_Y + 3, timer_count / 100, COL_TEXT_VAL, COL_STATS_BG);
        x = fb_draw_string(x + 12, GFX_STATS_Y + 3, "Ops:", COL_TEXT_DIM, COL_STATS_BG);
        x = fb_draw_int(x, GFX_STATS_Y + 3, total_ops, COL_TEXT_VAL, COL_STATS_BG);
        x = fb_draw_string(x + 12, GFX_STATS_Y + 3, "Arena:", COL_TEXT_DIM, COL_STATS_BG);
        x = fb_draw_int(x, GFX_STATS_Y + 3, (int)(herb_arena_usage() / 1024), COL_TEXT_VAL, COL_STATS_BG);
        x = fb_draw_string(x, GFX_STATS_Y + 3, "KB", COL_TEXT_DIM, COL_STATS_BG);

        int n_proc = herb_container_count(CN_READY)
                   + herb_container_count(CN_CPU0)
                   + herb_container_count(CN_BLOCKED);
        x = fb_draw_string(x + 12, GFX_STATS_Y + 3, "Procs:", COL_TEXT_DIM, COL_STATS_BG);
        x = fb_draw_int(x, GFX_STATS_Y + 3, n_proc < 0 ? 0 : n_proc, COL_TEXT_VAL, COL_STATS_BG);

#ifdef KERNEL_MODE
        /* Policy indicator — read from HERB ShellCtl.current_policy */
        {
            int cp = (shell_ctl_eid >= 0) ? (int)herb_entity_prop_int(shell_ctl_eid, "current_policy", 0) : 0;
            x = fb_draw_string(x + 12, GFX_STATS_Y + 3, "Sched:", COL_TEXT_DIM, COL_STATS_BG);
            x = fb_draw_string(x, GFX_STATS_Y + 3, cp == 0 ? "PRIORITY" : "ROUND-ROBIN",
                               cp == 0 ? COL_RUNNING : 0x00FF9900, COL_STATS_BG);
        }
#endif

        if (last_key_name[0]) {
            x = fb_draw_string(x + 12, GFX_STATS_Y + 3, "Key:[", COL_TEXT_DIM, COL_STATS_BG);
            x = fb_draw_string(x, GFX_STATS_Y + 3, last_key_name, COL_TEXT_KEY, COL_STATS_BG);
            fb_draw_string(x, GFX_STATS_Y + 3, "]", COL_TEXT_DIM, COL_STATS_BG);
        }
    }

#ifdef KERNEL_MODE
    /* ---- Game mode dispatch ---- */
    if (game_ctl_eid >= 0 &&
        herb_entity_prop_int(game_ctl_eid, "display_mode", 0) == 1) {

        /* Game-specific legend */
        fb_fill_rect(0, GFX_LEGEND_Y, FB_WIDTH, GFX_LEGEND_H, COL_LEGEND_BG);
        {
            int x = 12;
            x = fb_draw_string(x, GFX_LEGEND_Y + 3, "Arrows", COL_TEXT_KEY, COL_LEGEND_BG);
            x = fb_draw_string(x, GFX_LEGEND_Y + 3, "=Move ", COL_TEXT_DIM, COL_LEGEND_BG);
            x = fb_draw_string(x, GFX_LEGEND_Y + 3, "Space", COL_TEXT_KEY, COL_LEGEND_BG);
            x = fb_draw_string(x, GFX_LEGEND_Y + 3, "=Gather ", COL_TEXT_DIM, COL_LEGEND_BG);
            x = fb_draw_string(x, GFX_LEGEND_Y + 3, "G", COL_TEXT_KEY, COL_LEGEND_BG);
            fb_draw_string(x, GFX_LEGEND_Y + 3, "=OS view", COL_TEXT_DIM, COL_LEGEND_BG);
        }
        fb_hline(0, GFX_LEGEND_Y + GFX_LEGEND_H + 2, FB_WIDTH, COL_BORDER);

        /* Draw game world */
        gfx_draw_game();

        /* Log bar */
        fb_fill_rect(0, GFX_LOG_Y, FB_WIDTH, GFX_LOG_H, COL_LEGEND_BG);
        if (last_action[0]) {
            fb_draw_string(12, GFX_LOG_Y + 3, "> ", COL_RUNNING, COL_LEGEND_BG);
            fb_draw_string(28, GFX_LOG_Y + 3, last_action, COL_TEXT, COL_LEGEND_BG);
        }

        /* Game summary bar */
        fb_fill_rect(0, GFX_SUMMARY_Y, FB_WIDTH, GFX_SUMMARY_H, COL_STATS_BG);
        {
            int x = 12;
            int wood = herb_container_count(CN_GAME_TREE_GATHERED);
            if (wood < 0) wood = 0;
            x = fb_draw_string(x, GFX_SUMMARY_Y + 3, "COMMON HERB", COL_GAME_TITLE, COL_STATS_BG);
            x = fb_draw_string(x + 16, GFX_SUMMARY_Y + 3, "Wood:", COL_TEXT_DIM, COL_STATS_BG);
            x = fb_draw_int(x, GFX_SUMMARY_Y + 3, wood, COL_TREE, COL_STATS_BG);
            x = fb_draw_string(x + 16, GFX_SUMMARY_Y + 3, "Trees:", COL_TEXT_DIM, COL_STATS_BG);
            int trees = herb_container_count(CN_GAME_TREES);
            fb_draw_int(x, GFX_SUMMARY_Y + 3, trees < 0 ? 0 : trees, COL_TEXT_VAL, COL_STATS_BG);
        }

        /* Bottom bars */
        fb_fill_rect(0, GFX_RESLEG_Y, FB_WIDTH, GFX_RESLEG_H, COL_LEGEND_BG);
        fb_fill_rect(0, GFX_RESLEG_Y + GFX_RESLEG_H + 4, FB_WIDTH, 22, 0x00161622);
        fb_draw_string(8, GFX_RESLEG_Y + GFX_RESLEG_H + 7, "G", COL_TEXT_KEY, 0x00161622);
        fb_draw_string(20, GFX_RESLEG_Y + GFX_RESLEG_H + 7, "= return to OS", COL_TEXT_DIM, 0x00161622);

        fb_flip();
        fb_cursor_draw();
        return;
    }
#endif

    /* ---- Key legend (derived from HERB LEGEND entities, Session 56) ---- */
    fb_fill_rect(0, GFX_LEGEND_Y, FB_WIDTH, GFX_LEGEND_H, COL_LEGEND_BG);
    {
        int x = 12;
#ifdef KERNEL_MODE
        int n = herb_container_count(CN_LEGEND);
        if (n > 0) {
            int ids[32];
            int orders[32];
            int count = 0;
            for (int i = 0; i < n && count < 32; i++) {
                int eid = herb_container_entity(CN_LEGEND, i);
                if (eid >= 0) {
                    ids[count] = eid;
                    orders[count] = (int)herb_entity_prop_int(eid, "order", 99);
                    count++;
                }
            }
            for (int i = 1; i < count; i++) {
                int key_o = orders[i], key_id = ids[i];
                int j = i - 1;
                while (j >= 0 && orders[j] > key_o) {
                    orders[j+1] = orders[j];
                    ids[j+1] = ids[j];
                    j--;
                }
                orders[j+1] = key_o;
                ids[j+1] = key_id;
            }
            for (int i = 0; i < count; i++) {
                const char* key = herb_entity_prop_str(ids[i], "key_text", "?");
                const char* label = herb_entity_prop_str(ids[i], "label_text", "");
                x = fb_draw_string(x, GFX_LEGEND_Y + 3, key, COL_TEXT_KEY, COL_LEGEND_BG);
                x = fb_draw_string(x, GFX_LEGEND_Y + 3, label, COL_TEXT_DIM, COL_LEGEND_BG);
                x = fb_draw_string(x, GFX_LEGEND_Y + 3, " ", COL_TEXT_DIM, COL_LEGEND_BG);
            }
        }
#else
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "N", COL_TEXT_KEY, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "ew ", COL_TEXT_DIM, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "K", COL_TEXT_KEY, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "ill ", COL_TEXT_DIM, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "B", COL_TEXT_KEY, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "lk ", COL_TEXT_DIM, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "U", COL_TEXT_KEY, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "nblk ", COL_TEXT_DIM, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "T", COL_TEXT_KEY, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "mr ", COL_TEXT_DIM, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "+", COL_TEXT_KEY, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "Boost ", COL_TEXT_DIM, COL_LEGEND_BG);
        x = fb_draw_string(x, GFX_LEGEND_Y + 3, "Space", COL_TEXT_KEY, COL_LEGEND_BG);
        fb_draw_string(x, GFX_LEGEND_Y + 3, "=Step", COL_TEXT_DIM, COL_LEGEND_BG);
#endif
    }

    /* ---- Separator line ---- */
    fb_hline(0, GFX_LEGEND_Y + GFX_LEGEND_H + 2, FB_WIDTH, COL_BORDER);

    /* ---- Container regions: read from HERB Surface entities ----
     *
     * The display module placed region Surfaces in display.VISIBLE.
     * Each has properties: kind=0, region_id, x, y, width, height.
     * The C renderer reads these and draws titled boxes.
     * Process colors come from each process's scoped SURFACE entity.
     *
     * This is the architectural inversion: HERB owns visual state,
     * C is a dumb pixel blitter.
     */
#ifdef KERNEL_MODE
    {
        int nv = herb_container_count(CN_VISIBLE);
        for (int vi = 0; vi < nv; vi++) {
            int sid = herb_container_entity(CN_VISIBLE, vi);
            if (sid < 0) continue;
            int kind = (int)herb_entity_prop_int(sid, "kind", -1);
            if (kind != 0) continue;  /* only container regions */

            int rid = (int)herb_entity_prop_int(sid, "region_id", -1);
            if (rid < 0 || rid > 3) continue;

            /* Read position/size from HERB entity properties */
            int rx = (int)herb_entity_prop_int(sid, "x", 0);
            int ry = (int)herb_entity_prop_int(sid, "y", 0);
            int rw = (int)herb_entity_prop_int(sid, "width", 100);
            int rh = (int)herb_entity_prop_int(sid, "height", 100);

            /* Read border_color/fill_color from HERB region entity (Session 55) */
            int bc = (int)herb_entity_prop_int(sid, "border_color", COL_TEXT_DIM);
            int fc = (int)herb_entity_prop_int(sid, "fill_color", COL_BG);

            fb_draw_container(rx, ry, rw, rh,
                              region_titles[rid],
                              (uint32_t)bc, (uint32_t)fc);

            /* Draw processes within this region */
            gfx_draw_procs_in_region(rx, ry, rw, rh, region_containers[rid],
                                      (uint32_t)bc, (uint32_t)fc);
        }
    }
#else
    /* Flat mode: no display module, use hardcoded positions */
    fb_draw_container(GFX_CPU0_X, GFX_CPU0_Y, GFX_CONT_W, GFX_CONT_H,
                      "CPU0 (RUNNING)", COL_RUNNING, COL_RUNNING_BG);
    gfx_draw_procs_in_region(GFX_CPU0_X, GFX_CPU0_Y, GFX_CONT_W, GFX_CONT_H,
                              CN_CPU0, COL_RUNNING, COL_RUNNING_BG);

    fb_draw_container(GFX_READY_X, GFX_READY_Y, GFX_CONT_W, GFX_CONT_H,
                      "READY", COL_READY, COL_READY_BG);
    gfx_draw_procs_in_region(GFX_READY_X, GFX_READY_Y, GFX_CONT_W, GFX_CONT_H,
                              CN_READY, COL_READY, COL_READY_BG);

    fb_draw_container(GFX_BLOCK_X, GFX_BLOCK_Y, GFX_CONT_W, GFX_CONT_H,
                      "BLOCKED", COL_BLOCKED, COL_BLOCKED_BG);
    gfx_draw_procs_in_region(GFX_BLOCK_X, GFX_BLOCK_Y, GFX_CONT_W, GFX_CONT_H,
                              CN_BLOCKED, COL_BLOCKED, COL_BLOCKED_BG);

    fb_draw_container(GFX_TERM_X, GFX_TERM_Y, GFX_CONT_W, GFX_CONT_H,
                      "TERMINATED", COL_TERM, COL_TERM_BG);
    gfx_draw_procs_in_region(GFX_TERM_X, GFX_TERM_Y, GFX_CONT_W, GFX_CONT_H,
                              CN_TERMINATED, COL_TERM, COL_TERM_BG);
#endif

    /* ---- Tension panel (right sidebar) ---- */
#ifdef KERNEL_MODE
    gfx_draw_tension_panel();
#endif

    /* ---- Action log ---- */
    fb_fill_rect(0, GFX_LOG_Y, FB_WIDTH, GFX_LOG_H, COL_LEGEND_BG);
    if (last_action[0]) {
        fb_draw_string(12, GFX_LOG_Y + 3, "> ", COL_RUNNING, COL_LEGEND_BG);
        fb_draw_string(28, GFX_LOG_Y + 3, last_action, COL_TEXT, COL_LEGEND_BG);
    }

    /* ---- Container summary ---- */
    fb_fill_rect(0, GFX_SUMMARY_Y, FB_WIDTH, GFX_SUMMARY_H, COL_STATS_BG);
    {
        int x = 12;
        int ready_n = herb_container_count(CN_READY);
        int cpu_n = herb_container_count(CN_CPU0);
        int blk_n = herb_container_count(CN_BLOCKED);
        int term_n = herb_container_count(CN_TERMINATED);

        x = fb_draw_string(x, GFX_SUMMARY_Y + 3, "READY=", COL_TEXT_DIM, COL_STATS_BG);
        x = fb_draw_int(x, GFX_SUMMARY_Y + 3, ready_n < 0 ? 0 : ready_n, COL_READY, COL_STATS_BG);
        x = fb_draw_string(x + 8, GFX_SUMMARY_Y + 3, "CPU0=", COL_TEXT_DIM, COL_STATS_BG);
        x = fb_draw_int(x, GFX_SUMMARY_Y + 3, cpu_n < 0 ? 0 : cpu_n, COL_RUNNING, COL_STATS_BG);
        x = fb_draw_string(x + 8, GFX_SUMMARY_Y + 3, "BLOCKED=", COL_TEXT_DIM, COL_STATS_BG);
        x = fb_draw_int(x, GFX_SUMMARY_Y + 3, blk_n < 0 ? 0 : blk_n, COL_BLOCKED, COL_STATS_BG);
        x = fb_draw_string(x + 8, GFX_SUMMARY_Y + 3, "TERM=", COL_TEXT_DIM, COL_STATS_BG);
        fb_draw_int(x, GFX_SUMMARY_Y + 3, term_n < 0 ? 0 : term_n, COL_TERM, COL_STATS_BG);
    }

#ifdef KERNEL_MODE
    /* ---- Buffer indicator ---- */
    if (buffer_eid >= 0) {
        int64_t bcount = herb_entity_prop_int(buffer_eid, "count", 0);
        int64_t bcap = herb_entity_prop_int(buffer_eid, "capacity", 1);
        int bar_x = 12, bar_y = GFX_RESLEG_Y + 3;
        int bar_w = 120, bar_h = 12;

        fb_fill_rect(0, GFX_RESLEG_Y, FB_WIDTH, GFX_RESLEG_H, COL_LEGEND_BG);
        fb_draw_string(bar_x, bar_y, "BUF", COL_TEXT_DIM, COL_LEGEND_BG);
        bar_x += 28;

        /* Draw fill bar: outline + filled portion */
        fb_draw_rect(bar_x, bar_y, bar_w, bar_h, COL_TEXT_DIM);
        if (bcount > 0 && bcap > 0) {
            int fill_w = (int)((bcount * (bar_w - 2)) / bcap);
            if (fill_w > bar_w - 2) fill_w = bar_w - 2;
            /* Color: green when low, yellow when mid, red/orange when near full */
            uint32_t fill_col = 0x0044CC44;  /* green */
            if (bcount * 3 > bcap * 2) fill_col = 0x00FF9900;  /* orange near full */
            else if (bcount * 2 > bcap) fill_col = 0x00CCCC00;  /* yellow mid */
            fb_fill_rect(bar_x + 1, bar_y + 1, fill_w, bar_h - 2, fill_col);
        }
        bar_x += bar_w + 6;

        /* Numeric display */
        {
            char bbuf[20];
            herb_snprintf(bbuf, sizeof(bbuf), "%d/%d", (int)bcount, (int)bcap);
            fb_draw_string(bar_x, bar_y, bbuf, COL_TEXT_VAL, COL_LEGEND_BG);
        }

        /* Legend: producer/consumer indicators */
        bar_x += 60;
        fb_draw_string(bar_x, bar_y, ">", 0x00FF9900, COL_LEGEND_BG);
        bar_x += 12;
        fb_draw_string(bar_x, bar_y, "producer  ", COL_TEXT_DIM, COL_LEGEND_BG);
        bar_x += 80;
        fb_draw_string(bar_x, bar_y, "<", 0x0066CCFF, COL_LEGEND_BG);
        bar_x += 12;
        fb_draw_string(bar_x, bar_y, "consumer", COL_TEXT_DIM, COL_LEGEND_BG);
    } else {
        /* Fallback: resource legend when no buffer exists */
        fb_fill_rect(0, GFX_RESLEG_Y, FB_WIDTH, GFX_RESLEG_H, COL_LEGEND_BG);
        {
            int x = 12;
            fb_fill_rect(x, GFX_RESLEG_Y + 7, 6, 6, COL_RES_FREE);
            x = fb_draw_string(x + 10, GFX_RESLEG_Y + 3, "MEM free  ", COL_TEXT_DIM, COL_LEGEND_BG);
            fb_fill_rect(x, GFX_RESLEG_Y + 7, 6, 6, COL_RES_USED);
            x = fb_draw_string(x + 10, GFX_RESLEG_Y + 3, "MEM used  ", COL_TEXT_DIM, COL_LEGEND_BG);
            fb_fill_rect(x, GFX_RESLEG_Y + 7, 6, 6, COL_RES_FD_F);
            x = fb_draw_string(x + 10, GFX_RESLEG_Y + 3, "FD free  ", COL_TEXT_DIM, COL_LEGEND_BG);
            fb_fill_rect(x, GFX_RESLEG_Y + 7, 6, 6, COL_RES_FD_U);
            fb_draw_string(x + 10, GFX_RESLEG_Y + 3, "FD open", COL_TEXT_DIM, COL_LEGEND_BG);
        }
    }
#endif

    /* ---- Command line (Session 49) ---- */
#ifdef KERNEL_MODE
    {
        int input_mode = 0;
        if (input_ctl_eid >= 0) {
            input_mode = (int)herb_entity_prop_int(input_ctl_eid, "mode", 0);
        }

        /* Command line bar at bottom */
        int cmd_y = GFX_RESLEG_Y + GFX_RESLEG_H + 4;
        fb_fill_rect(0, cmd_y, FB_WIDTH, 22, 0x00161622);

        if (input_mode == 1) {
            /* Text mode: show typed text with cursor */
            char cmdbuf[64];
            int clen = read_cmdline(cmdbuf, sizeof(cmdbuf));

            fb_draw_string(8, cmd_y + 3, ":", 0x0066FF66, 0x00161622);
            if (clen > 0) {
                fb_draw_string(20, cmd_y + 3, cmdbuf, COL_TEXT_HI, 0x00161622);
            }
            /* Draw cursor (blinking underscore) */
            int cursor_px = 20 + clen * 8;
            fb_fill_rect(cursor_px, cmd_y + 14, 8, 2, 0x0066FF66);
        } else {
            /* Command mode: show hint */
            fb_draw_string(8, cmd_y + 3, "/", 0x00666688, 0x00161622);
            fb_draw_string(20, cmd_y + 3, "type command", 0x00444466, 0x00161622);
        }
    }
#endif

    /* ---- Flip back buffer to framebuffer, then overlay cursor ---- */
    fb_flip();
    fb_cursor_draw();
}

/* Quick stats-only update for periodic refresh (avoids full redraw) */
void gfx_draw_stats_only(void) {
    /* Redraw just the stats bar and flip */
    fb_fill_rect(0, GFX_STATS_Y, FB_WIDTH, GFX_STATS_H, COL_STATS_BG);
    {
        int x = 12;
        x = fb_draw_string(x, GFX_STATS_Y + 3, "Tick:", COL_TEXT_DIM, COL_STATS_BG);
        x = fb_draw_int(x, GFX_STATS_Y + 3, timer_count / 100, COL_TEXT_VAL, COL_STATS_BG);
        x = fb_draw_string(x + 12, GFX_STATS_Y + 3, "Ops:", COL_TEXT_DIM, COL_STATS_BG);
        x = fb_draw_int(x, GFX_STATS_Y + 3, total_ops, COL_TEXT_VAL, COL_STATS_BG);

        int n_proc = herb_container_count(CN_READY)
                   + herb_container_count(CN_CPU0)
                   + herb_container_count(CN_BLOCKED);
        x = fb_draw_string(x + 12, GFX_STATS_Y + 3, "Procs:", COL_TEXT_DIM, COL_STATS_BG);
        x = fb_draw_int(x, GFX_STATS_Y + 3, n_proc < 0 ? 0 : n_proc, COL_TEXT_VAL, COL_STATS_BG);
#ifdef KERNEL_MODE
        {
            int cp = (shell_ctl_eid >= 0) ? (int)herb_entity_prop_int(shell_ctl_eid, "current_policy", 0) : 0;
            x = fb_draw_string(x + 12, GFX_STATS_Y + 3, "Sched:", COL_TEXT_DIM, COL_STATS_BG);
            fb_draw_string(x, GFX_STATS_Y + 3, cp == 0 ? "PRIORITY" : "ROUND-ROBIN",
                           cp == 0 ? COL_RUNNING : 0x00FF9900, COL_STATS_BG);
        }
#endif
    }
    fb_flip();
    fb_cursor_draw();
}

/* ---- Framebuffer wrapper functions for assembly (Phase A) ---- */
int km_fb_init(void) { return fb_init_display(); }
void km_fb_clear_bg(void) { fb_clear(COL_BG); }
void km_fb_flip(void) { fb_flip(); }
void km_fb_cursor_erase(void) { fb_cursor_erase(); }
void km_fb_cursor_draw(void) { fb_cursor_draw(); }
int km_fb_get_active(void) { return fb_active; }
void km_set_cursor(int x, int y) { cursor_x = x; cursor_y = y; }

#endif /* GRAPHICS_MODE */

/* ============================================================
 * DRAW: Full screen refresh
 * ============================================================ */

void draw_full(void) {
#ifdef GRAPHICS_MODE
    if (fb_active) {
        gfx_draw_full();
        return;
    }
#endif
    draw_banner();
    draw_stats();
    draw_legend();
    draw_process_table();
    draw_summary();
    draw_log();

    /* Command line (VGA text mode, Session 49) */
#ifdef KERNEL_MODE
    if (input_ctl_eid >= 0) {
        int mode = (int)herb_entity_prop_int(input_ctl_eid, "mode", 0);
        vga_set_color(VGA_LGRAY, VGA_BLACK);
        vga_clear_row(ROW_ERROR);
        if (mode == 1) {
            char cmdbuf[64];
            int clen = read_cmdline(cmdbuf, sizeof(cmdbuf));
            vga_set_color(VGA_LGREEN, VGA_BLACK);
            vga_print_at(ROW_ERROR, 0, ":");
            vga_set_color(VGA_WHITE, VGA_BLACK);
            if (clen > 0) vga_print(cmdbuf);
            vga_set_color(VGA_LGREEN, VGA_BLACK);
            vga_putchar('_');
        } else {
            vga_set_color(VGA_DGRAY, VGA_BLACK);
            vga_print_at(ROW_ERROR, 0, "/ to type command");
        }
    }
#endif
}

/* ============================================================
 * COMMAND HANDLERS
 * ============================================================ */

/* make_sig_name — moved to herb_kernel.asm (Phase C) */
extern void make_sig_name(char* buf, int bufsz, const char* prefix);

/* ============================================================
 * PROGRAMS AS DATA (Session 47)
 *
 * A process IS its tensions. Loading a program means loading
 * a .herb binary and injecting its tensions into the runtime.
 *
 * The program binaries are compiled from .herb.json files and
 * embedded in the kernel image. No C code constructs tensions.
 * The .herb data IS the program.
 *
 * Available programs: producer, consumer (embedded in kernel).
 * Additional: worker, beacon (available as .herb files).
 * ============================================================ */

/* buffer_capacity removed Session 56 — now read from DisplayCtl.buffer_capacity */

/* report_buffer_state — moved to herb_kernel.asm (Phase C) */
#ifdef KERNEL_MODE
extern void report_buffer_state(void);
#else
static void report_buffer_state(void) { /* no-op in non-kernel mode */ }
#endif

/* ============================================================
 * PROCESS CREATION VIA HERB POLICY (Session 52)
 *
 * Process creation is HERB policy. C creates a SPAWN_SIG entity
 * with requested_type. HERB spawn tensions decide priority
 * (from PRI_POOL conservation pool) and program type (from
 * PROG_POOL or explicit request). C reads SpawnCtl decisions
 * and creates the process with resources and program.
 *
 * requested_type: 0=auto (HERB picks), 1=producer, 2=consumer,
 *                 3=worker, 4=beacon
 * ============================================================ */

/* cmd_spawn, cmd_new_process — moved to herb_kernel.asm (Phase C Step 9) */
#ifdef KERNEL_MODE
extern void cmd_spawn(int requested_type);
#else
extern void cmd_new_process(void);
#endif

/* post_dispatch, dispatch_cmd_from_route, dispatch_mech_action,
 * dispatch_text_command — moved to herb_kernel.asm (Phase C) */

/* compute_text_key, compute_arg_key — moved to herb_kernel.asm (Phase C) */
extern int compute_text_key(const char* buf);
extern int compute_arg_key(const char* buf);

#ifdef KERNEL_MODE
/* cmd_click — moved to herb_kernel.asm (Phase C) */
extern void cmd_click(int cx, int cy);

/* cmd_tension_next/prev/toggle, cmd_ham_test — moved to herb_kernel.asm (Phase C) */

/* ============================================================
 * HOT-SWAPPABLE SCHEDULING POLICY (Session 48)
 *
 * Replace the active scheduling tension at runtime with a
 * different behavioral rule loaded from .herb binary data.
 * The system never stops running. No reboot. No recompile.
 * Just data replacing data.
 *
 * The mechanism is general: herb_remove_tension_by_name()
 * works for any tension, herb_load_program() with owner=-1
 * loads any fragment as a system tension. The demo swaps
 * scheduling, but you could swap display sync, hit testing,
 * or any other system behavioral rule the same way.
 * ============================================================ */

/* cmd_swap_policy_from_herb — moved to herb_kernel.asm (Phase C Step 8) */
#endif /* KERNEL_MODE */

/* create_key_signal, create_move_signal, create_gather_signal — moved to herb_kernel.asm (Phase C) */
extern void create_move_signal(int direction);
extern void create_gather_signal(void);

#ifdef KERNEL_MODE

/* read_cmdline — moved to herb_kernel.asm (Phase C Step 8) */

/* cleanup_terminated — moved to herb_kernel.asm (Phase C Step 8) */

/* handle_shell_action — moved to herb_kernel.asm (Phase C Step 8) */

/* handle_submission — moved to herb_kernel.asm (Phase C Step 8) */
#endif /* KERNEL_MODE */

/* handle_key — moved to herb_kernel.asm (Phase C Step 10) */
extern void handle_key(uint8_t scancode);

/* kernel_main() moved to herb_kernel.asm (Phase A) */
