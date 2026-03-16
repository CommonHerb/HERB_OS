# HERB OS — Human Testing Guide

**Updated Session 96 — Testing every interaction path**

## Setup

1. Open a terminal in `C:\Users\Ben\Desktop\HERB\boot\`
2. Run `mingw32-make run` (graphics mode with QEMU)
3. The OS boots automatically — you should see:
   - A dark blue background
   - "HERB KERNEL" title at top
   - "Shell" subtitle
   - Two processes (server + client) already running
   - A sidebar panel showing tensions on the right
   - A legend bar at the bottom

**Serial output** appears in the QEMU terminal (the window you ran `make run` from). This is where diagnostic messages go.

---

## Key Reference

### Mechanism Keys (always active in command mode)

| Key | Action | What It Does |
|-----|--------|-------------|
| T | Timer tick | Triggers preemption — rotates which process runs on CPU0 |
| + or = | Boost priority | Increases running process's priority by 1 |
| SPACE | Single HAM step | Runs one fixpoint cycle (for debugging) |
| A | Alloc page | Allocates a memory page for running process |
| O | Open FD | Opens a file descriptor for running process |
| F | Free page | Frees a memory page from running process |
| C | Close FD | Closes a file descriptor from running process |
| M | Send message | Sends an IPC message from running process |
| [ | Tension prev | Selects previous tension in sidebar panel |
| ] | Tension next | Selects next tension in sidebar panel |
| D | Toggle tension | Enables/disables the selected tension |
| H | HAM test | Runs HAM diagnostic test |

### Command Keys (active in command mode)

| Key | Action | What It Does |
|-----|--------|-------------|
| N | Spawn process | Creates a new process (HERB decides type + priority) |
| K | Kill process | Kills the currently running process |
| B | Block process | Blocks the currently running process |
| U | Unblock process | Unblocks the first blocked process |
| S | Swap policy | Swaps the scheduling policy at runtime |

### Shell Mode

| Key | Action |
|-----|--------|
| / | Enter shell mode (text input) |
| ESC | Exit shell mode (back to command mode) |
| Enter | Submit the typed command |
| Backspace | Delete last character |

### Shell Commands (type after pressing /)

| Command | What It Does |
|---------|-------------|
| `kill` | Kill running process (same as K) |
| `block` | Block running process (same as B) |
| `unblock` | Unblock first blocked (same as U) |
| `load producer` | Spawn a producer process |
| `load consumer` | Spawn a consumer process |
| `load worker` | Spawn a worker process |
| `load beacon` | Spawn a beacon process |
| `swap` | Swap scheduling policy (same as S) |
| `list` | List all processes |
| `help` | Show help text |
| `edit` | Enter the flow editor empty (type characters, ESC to exit) |
| `edit <name>` | Load file from disk into the flow editor |
| `esave <name>` | Save editor buffer to disk |
| `eload <name>` | Load file from disk into editor |
| `save <name>` | Save text to disk |
| `read <name>` | Read file from disk |
| `files` | List saved files |
| `ping` | Send ICMP echo to gateway (10.0.2.2) — requires NIC (`make run-net`) |
| `udp` | Send UDP packet — requires NIC (`make run-net`) |
| `dns <domain>` | DNS lookup — requires NIC (`make run-net`) |
| `connect` | TCP connect to port 80 — requires NIC (`make run-net`) |
| `http` | HTTP GET request — requires NIC (`make run-net`) |
| `tile` | Toggle tiling layout (4+3 window grid) |

---

## Test Scenarios

### Test 1: Boot Verification

**Action:** Just watch the boot sequence.

**Expected visual:**
- Dark blue background fills the screen
- Two process boxes appear (server + client)
- One box has a green border (running on CPU0)
- One box has a yellow/brown border (ready)
- Tension sidebar on the right lists all active tensions
- Legend bar at the bottom shows key mappings

**Expected serial output:**
```
HERB OS v3 - Four-Module Kernel
  Framebuffer: detecting BGA...
  Framebuffer: 1280x800x32 initialized
  Runtime initialized
  Program loaded
```

**Pass if:** Screen renders with colored process boxes and no crash.

---

### Test 2: Preemption (Timer Tick)

**Action:** Press `T` several times (5-6 times).

**Expected visual:**
- The green (running) and yellow (ready) borders swap between the two process boxes each time
- The "Last action" text at top updates to show "Timer signal tN -> X ops"

**Expected serial output (each press):**
```
[TIMER] tN ops=X [server]->[client]
[TIMER] tN ops=X [client]->[server]
```
The `[server]->[client]` and `[client]->[server]` should alternate.

**Pass if:** Processes alternate on CPU0 and serial shows the swap.

---

### Test 3: Spawn Process

**Action:** Press `N` to spawn a new process.

**Expected visual:**
- A third process box appears
- It should have a yellow/brown border (ready state)
- The status line updates

**Expected serial output:**
```
[SHELL DISPATCH] cmd_id=8 ...
[SPAWN] pN type=X pri=Y ops=Z
```

**Pass if:** New process box visible, serial confirms spawn.

---

### Test 4: Kill Process

**Action:** Press `K` to kill the currently running process.

**Expected visual:**
- The running process box changes to gray border/fill (terminated)
- Another process moves into the running slot (green border)

**Expected serial output:**
```
[SHELL DISPATCH] cmd_id=1 ...
[KILL] pN ops=X
```

**Pass if:** Process turns gray, another takes CPU0.

---

### Test 5: Block and Unblock

**Action:**
1. Press `B` to block the running process
2. Press `U` to unblock it

**Expected visual:**
- After `B`: Running process box turns red border (blocked), another process takes CPU0
- After `U`: Blocked process returns to yellow (ready)

**Expected serial output:**
```
[SHELL DISPATCH] cmd_id=6 ...
[BLOCK] ops=X
[SHELL DISPATCH] cmd_id=7 ...
[UNBLOCK] ops=X
```

**Pass if:** Colors change correctly: green -> red (block), red -> yellow (unblock).

> **KNOWN ISSUE (Discovery 51):** If multiple processes are in the same state (e.g., 3 in READY), only the first one may show the correct color. This is the sync tension bug being fixed in this session.

---

### Test 6: Priority Boost

**Action:** Press `+` or `=` to boost the running process's priority.

**Expected visual:**
- The priority number shown in the process box increases by 1
- Status line updates

**Expected serial output:**
```
[BOOST] ops=X
```

**Pass if:** Priority number increments, serial confirms.

---

### Test 7: Shell Mode — Enter and Exit

**Action:**
1. Press `/` to enter shell mode
2. You should see a text cursor or input indicator
3. Press `ESC` to exit shell mode

**Expected visual:**
- After `/`: Status shows "Text mode" or similar indicator
- After `ESC`: Returns to normal command mode

**Expected serial output:**
```
[INPUT] mode=1 (text mode entered)
[INPUT] mode=0 ...
```

**Pass if:** Mode switches visible in serial, ESC returns to command mode.

---

### Test 8: Shell Command — Load Producer

**Action:**
1. Press `/` to enter shell mode
2. Type `load producer`
3. Press `Enter` to submit

**Expected visual:**
- Characters appear as you type
- After Enter: a new process box appears (producer type)
- Shell mode exits after submission

**Expected serial output:**
```
[INPUT] mode=1 len=N buf=load producer
[CMD] load producer
[SPAWN] pN type=1 ...
```

**Pass if:** Producer process spawned, visible as new box.

---

### Test 9: Tension Panel Navigation

**Action:**
1. Press `]` several times to cycle forward through tensions
2. Press `[` several times to cycle backward
3. Press `D` to toggle the selected tension on/off

**Expected visual:**
- The highlighted tension in the sidebar changes as you press [ and ]
- After pressing `D`, the selected tension shows as disabled (different visual)

**Expected serial output:** No specific serial output for panel navigation (visual only).

**Pass if:** Selection moves through tensions, toggle changes state.

---

### Test 10: Mouse Click Focus (Session 91)

**Action:** Click on different windows (process panels, editor, tensions panel).

**Expected visual:**
- Clicked window gets a bright blue focus ring
- Previously focused window loses the ring
- Clicked window comes to front (z-order changes)

**Expected serial output:** Focus changes driven by HERB tensions, no specific serial line.

**Pass if:** Focus ring moves to clicked window, window comes to front.

---

### Test 10b: Disable Focus Tension

**Action:**
1. Click the tensions panel to select `wm.focus_on_click`
2. Press `D` to disable it
3. Click on a different window

**Expected visual:**
- After disabling: clicking windows does NOT change focus
- Focus ring stays on the previously focused window
- Re-enabling the tension restores click-to-focus behavior

**Pass if:** Disabling `wm.focus_on_click` freezes focus — clicks have no effect on window focus.

---

### Test 10c: Tiling Layout (Session 92)

**Action:**
1. Press `/` to enter shell mode
2. Type `tile` and press Enter
3. Observe the window layout
4. Type `/tile` again to disable

**Expected visual (tile ON):**
- All 7 windows snap to a 4+3 grid filling the screen
- Top row: 4 windows, each 320px wide, covering full 1280px width
- Bottom row: 3 windows, each ~426px wide
- All windows 362px tall
- No overlapping — clean grid layout

**Expected visual (tile OFF):**
- Windows stay where they are (positions persist)
- Dragging/resizing works again

**Expected serial output:**
```
[WM] tiling ENABLED
[WM] tiling DISABLED
```

**Pass if:** Windows snap to grid on enable, stay in place on disable, dragging works after disable.

---

### Test 10d: Shell Output Window (Session 93)

**Action:**
1. Boot the OS — look for the "OUTPUT" window (was "TERMINATED")
2. The OUTPUT window should show "Type /help for commands"
3. Press `/`, type `help`, press Enter
4. Press `/`, type `files`, press Enter
5. Press `/`, type `save test hello world`, press Enter
6. Press `/`, type `files`, press Enter again
7. Press PgUp to scroll up through the output history
8. Press PgDn to scroll back down

**Expected visual:**
- OUTPUT window has blue-gray border and dark blue background
- Title bar says "OUTPUT"
- At boot: "Type /help for commands" visible in the window
- After `/help`: command list appears (one per line: "  /kill", "  /block", etc.)
- After `/files`: file listing appears ("Files on disk:", "  filename (N bytes)")
- After `/save`: "Saved test (11 bytes)" appears
- After second `/files`: the new file "test" appears in listing
- PgUp/PgDn: text scrolls through the 32-line history buffer

**Pass if:** Shell command output visible in the OUTPUT window, scroll works, serial output still appears in QEMU terminal.

---

## Color Reference

| State | Border Color | Fill Color |
|-------|-------------|------------|
| Running (CPU0) | Bright green | Dark green |
| Ready | Yellow/brown | Dark yellow |
| Blocked | Red | Dark red |
| Output (was Terminated) | Blue-gray (#446688) | Dark blue (#1A1A2E) |

---

### Test 11: Editor Window (Session 77)

**Action:** Look at the boot screen.

**Expected visual:**
- An "EDITOR" window visible (position 200,76, size 760x650)
- Dark blue background inside the window
- Title bar says "EDITOR"
- Dashboard/region windows visible alongside it

**Pass if:** Editor window is visible alongside dashboard windows.

---

### Test 12: Editor Typing in Window

**Action:**
1. Press `/` then type `edit` and press Enter
2. Type some characters (e.g., "hello world")
3. Press ESC to exit

**Expected visual:**
- Editor window gets focus (highlight on title bar)
- Characters appear inside the editor window at the top
- Characters wrap at ~94 per line (stay within window bounds)
- White cursor block visible
- Status bar at bottom shows "ESC=exit  /esave  /eload"
- ESC returns to hotkey mode

**Expected serial output:**
```
Editor (ESC=exit, type to edit)
[EDIT] GLYPHS=0
```
(No `[EDKEY]` per-keystroke spam — removed in Session 95.)

**Pass if:** Characters render inside the window, wrap correctly, no bleed-through.

---

### Test 13: Window Overlap and Clipping

**Action:**
1. Drag the editor window to overlap a dashboard window
2. Click on the dashboard window to bring it to front
3. Click on the editor window to bring it back

**Expected visual:**
- Windows clip correctly — no bleed-through
- Front window fully covers rear window content where they overlap
- Focus highlight changes correctly

**Pass if:** No rendering artifacts at window boundaries.

---

## What to Report

For each test, tell Claude:
1. **Pass or fail** (did it work as described?)
2. **Color accuracy** (do the colors match the table above?)
3. **Any visual glitches** (flickering, wrong layout, missing elements)
4. **Any unexpected behavior** (crashes, freezes, wrong process selected)

If something fails, note the exact serial output from the QEMU terminal window — this is the most useful diagnostic information.

---

### Test 14: `/edit <name>` — Load File Into Editor (Session 95)

**Action:**
1. First save a file: press `/`, type `save myfile hello from herb`, press Enter
2. Press `/`, type `edit myfile`, press Enter

**Expected visual:**
- Editor window gets focus
- The text "hello from herb" appears inside the editor
- Cursor is at end of text

**Expected serial output:**
```
[FS] read "myfile" (15 bytes)
Editor loaded myfile (15 bytes)
```

**Pass if:** File content visible in editor after `/edit myfile`.

---

### Test 15: Tab Focus Cycling (Session 95)

**Action:**
1. Make sure you're in command mode (press ESC if unsure)
2. Press Tab repeatedly (7 times to cycle through all windows)

**Expected visual:**
- Each Tab press moves the focus highlight (bright blue ring) to the next window
- Cycle order: CPU0 → READY → BLOCKED → OUTPUT → TENSIONS → EDITOR → GAME → CPU0...
- The focused window comes to front

**Pass if:** Focus ring cycles through all 7 windows, wraps around after GAME.

**Note:** Tab does NOT fire when the editor is active (mode != 0). Press ESC first to return to command mode.

---

### Test 16: NIC Boot (Session 82)

**Setup:** Run `mingw32-make run-net` (graphics mode with E1000 NIC).

**Expected serial output:**
```
[NET] E1000 found slot=N BAR0=NNNNNNNN IRQ=11
[NET] MAC=N,N,N,N,N,N IRQ=11 initialized
```

**Pass if:** NIC detected and initialized without crash. OS boots normally.

---

### Test 17: ARP Request (Session 82)

**Action:** Press `R` key (or whatever hotkey is mapped to ARP).

**Expected serial output:**
```
[NET] ARP request sent for 10.0.2.2
[NET] RX len=N ethertype=NNNN
```

**Pass if:** ARP sent, and a reply packet received from QEMU's virtual network.

---

### Test 18: Ping (Session 84)

**Setup:** Run `mingw32-make run-net` (graphics mode with E1000 NIC).

**Action:**
1. Wait for boot (ARP resolves automatically)
2. Press `/` to enter shell mode
3. Type `ping` and press Enter

**Expected serial output:**
```
[PING] sent to 10.0.2.2 seq=1
[IP] from 10.0.2.2 proto=1 len=74
[PING] reply from 10.0.2.2 seq=1
[PING] time=0ms
```

**Note:** An auto-ping is also sent at boot (~1.5s after start). You should see the auto-ping lines in serial even without typing anything.

**Pass if:** Ping sent, IPv4 reply received, round-trip logged.
