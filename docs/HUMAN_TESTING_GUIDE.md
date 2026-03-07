# HERB OS — Human Testing Guide

**Updated Session 84 — Testing every interaction path**

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
| `edit` | Enter the flow editor (type characters, ESC to exit) |
| `esave <name>` | Save editor buffer to disk |
| `eload <name>` | Load file from disk into editor |
| `save <name>` | Save text to disk |
| `read <name>` | Read file from disk |
| `files` | List saved files |
| `ping` | Send ICMP echo to gateway (10.0.2.2) — requires NIC (`make run-net`) |

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
  Framebuffer: 800x600x32 initialized
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

### Test 10: Mouse Click Selection

**Action:** Click on a process box or a tension in the sidebar panel.

**Expected visual:**
- Clicking a process box should select it (visual highlight)
- Clicking a tension in the sidebar should select that tension

**Expected serial output:**
```
[CLICK] selected NAME at X,Y ops=Z
```
or
```
[CLICK] miss
```

**Pass if:** Click registers in serial output, visual feedback on click target.

---

## Color Reference

| State | Border Color | Fill Color |
|-------|-------------|------------|
| Running (CPU0) | Bright green | Dark green |
| Ready | Yellow/brown | Dark yellow |
| Blocked | Red | Dark red |
| Terminated | Gray | Dark gray |

---

### Test 11: Editor Window (Session 77)

**Action:** Look at the boot screen.

**Expected visual:**
- An "EDITOR" window visible on the right side (position 400,76, size 400x500)
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
- Characters wrap at 49 per line (stay within window bounds)
- White cursor block visible
- Status bar at bottom shows "ESC=exit  /esave  /eload"
- ESC returns to hotkey mode

**Expected serial output:**
```
[EDIT] entering editor mode
[EDKEY] ascii=104 buf=1 pool=127
[EDIT] GLYPHS=1 g[0] ascii=104 x=0 y=0
```

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

### Test 14: NIC Boot (Session 82)

**Setup:** Run `mingw32-make run-net` (graphics mode with E1000 NIC).

**Expected serial output:**
```
[NET] E1000 found slot=N BAR0=NNNNNNNN IRQ=11
[NET] MAC=N,N,N,N,N,N IRQ=11 initialized
```

**Pass if:** NIC detected and initialized without crash. OS boots normally.

---

### Test 15: ARP Request (Session 82)

**Action:** Press `R` key (or whatever hotkey is mapped to ARP).

**Expected serial output:**
```
[NET] ARP request sent for 10.0.2.2
[NET] RX len=N ethertype=NNNN
```

**Pass if:** ARP sent, and a reply packet received from QEMU's virtual network.

---

### Test 16: Ping (Session 84)

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
