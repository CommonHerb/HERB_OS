# HERB Manifesto

HERB is a long-horizon operating system project built around a strict final-stack goal:

- Assembly is the permanent hardware boundary.
- HERB source (`.herb`) is the permanent behavior layer above it.
- Everything else is temporary development tooling and must justify its existence.

This project is not trying to become a novelty demo or an AI-generated curiosity. The goal is to build a real system with real integrity: coherent architecture, correct behavior, and enough polish that the result deserves to be judged by the standards applied to serious operating systems.

## Final Stack

The intended final stack contains exactly two implementation layers:

1. Assembly
2. HERB

Python, JSON, offline converters, compatibility shims, and historical runtimes are scaffolding. They may exist during development, but they are not part of the destination and must never be confused for permanent design.

## Design Standard

HERB is pursuing:

- Architectural honesty over convenient stories
- Declarative system behavior over ad hoc imperative glue
- Correctness and smoothness over feature-count inflation
- Internal beauty over short-term theatrics
- Niche legitimacy before mainstream comparison

The ambition is not to imitate Linux or Windows mechanically. The ambition is to reach comparable seriousness: a system whose behavior is trustworthy, whose abstractions are coherent, and whose implementation reflects care rather than improvisation.

## Policy And Mechanism

The central architectural idea is that behavior above the hardware boundary should be expressed in HERB whenever possible. Assembly exists to talk to hardware, move bytes, handle interrupts, manage memory at the machine boundary, and provide the substrate on which HERB programs can define system policy.

The project treats this boundary as a discipline:

- Hardware and low-level execution mechanics belong in assembly.
- System behavior, reactions, and higher-level policy belong in `.herb`.
- Development tooling exists to support the live path, not to replace it.

## Project Discipline

HERB only remains defensible if it resists self-mythologizing.

That means:

- verified status must stay separate from long-term vision
- stale architectures must be archived rather than half-maintained
- scaffolding must be named as scaffolding
- every live-path change must be understood and verified
- purity is not a substitute for engineering discipline

The project can take decades. That is acceptable. What is not acceptable is letting aspiration masquerade as current reality.

## Success Condition

Success is not "shipping next quarter."

Success is building a system that is:

- real
- internally consistent
- technically defensible
- aesthetically coherent
- useful in at least some genuine niche contexts

If HERB earns that, it will have justified the effort whether or not it ever becomes widely adopted.
