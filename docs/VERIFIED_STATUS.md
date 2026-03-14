# Verified Status

This document is the current-reality companion to the manifesto. It is intentionally narrower than the long-term vision.

## Scope

This file describes the repository after the repo-honesty cleanup on branch `cleanup/repo-honesty`, using:

- direct repository inspection
- successful local reruns of the surviving v2 Python suite on this branch
- the user-provided latest system validation from `main` after commit `e84727e`

When there is uncertainty, this file states that uncertainty rather than smoothing it over.

## What HERB Is Today

HERB currently consists of:

- a bare-metal/QEMU operating-system path implemented in assembly under `boot/`
- authoritative HERB source programs under `programs/`
- retained Python development tooling for the v2 MOVE/tension runtime and its tests under `src/`

The intended OS-image path is assembly plus `.herb`. Python is development tooling only and is not part of the final stack.

## Authoritative Source Paths

Live boot path:

- `boot/*.asm`
- `boot/*.inc`
- `boot/makefile`
- `boot/test_bare_metal.py`
- `programs/interactive_kernel.herb`
- `programs/shell.herb`
- `programs/producer.herb`
- `programs/consumer.herb`
- `programs/worker.herb`
- `programs/beacon.herb`
- `programs/schedule_priority.herb`
- `programs/schedule_roundrobin.herb`
- `programs/turing.herb`
- `programs/test_flow.herb`

Important clarification:

- `programs/*.herb` is the authoritative text-source path consumed by the assembler via `incbin "../programs/..."`
- the old `boot/*.herb` copies were binary artifacts and have been archived
- `.herb.json` is dead scaffolding and has been archived

## Active Python Tooling Retained

Active retained Python files on the v2 path:

- `src/herb_move.py`
- `src/herb_program.py`
- `src/herb_compose.py`
- `src/herb_scheduler.py`
- `src/herb_scheduler_priority.py`
- `src/herb_dom.py`
- `src/herb_economy.py`
- `src/herb_ipc.py`
- `src/herb_multiprocess.py`
- `src/herb_multiprocess_modules.py`
- `src/herb_kernel.py`
- `src/herb_process_dimensions.py`

Active retained v2 tests:

- `src/test_tensions.py`
- `src/test_goal_pursuit.py`
- `src/test_herb_program.py`
- `src/test_session29.py`
- `src/test_session30.py`
- `src/test_session31.py`
- `src/test_session32.py`
- `src/test_session33.py`
- `src/test_society_determinism.py`

## Latest Verified Test State

Latest full-system validation reported from `main` after commit `e84727e`:

- Python: `593` passing
- Bare metal: `176/178`
- Bare metal with NIC: `194/196`
- Remaining failures: `2` pre-existing failures in each bare-metal lane

Status verified locally on this cleanup branch:

- surviving retained v2 Python suite: `374` passing

This branch intentionally archives dead lanes, so the historical `593` count should not be treated as the active-suite count for the cleaned repository.

## What Is Verified To Work

Based on the latest validated state (Session 93, 2026-03-13), HERB OS currently has:

- boot path on bare metal / QEMU
- scheduling (priority + round-robin, hot-swappable)
- window manager (7 windows, drag/resize, focus via HERB tensions, tiling layout)
- shell output window (32-line circular buffer, PgUp/PgDn scroll)
- text editor (gap-buffer + HERB-flow editor)
- filesystem (bitmap, 256 entries, 8MB disk)
- NIC driver (E1000)
- ARP, IPv4, ICMP, UDP, DNS, TCP, HTTP

Current test counts (Session 93):
- Python: `374` passing
- Bare metal: `180/181` (1 pre-existing: HAM schedule_ready)
- 13 assembly files, 43,283 lines total

This document does not upgrade any claim beyond that evidence.

## Known Caveats

- `boot/herb_net.asm` had existing local modifications in the working tree before cleanup began on this branch.
- `boot/herb_kernel.asm` embeds `programs/test_flow.herb`, but `boot/makefile` does not currently list that file under `HERB_SOURCES`. The boot path still resolves, but the dependency declaration is incomplete.
- Historical status documents and archived artifacts should not be treated as current truth unless they are explicitly re-verified.

## Repository Policy After Cleanup

- Assembly is permanent.
- `.herb` is authoritative.
- Python survives only as active development tooling.
- Archived lanes are preserved for history, not for active maintenance.
- Manifesto and verified status are separate on purpose.
