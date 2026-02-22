# HERB_OS

A bootable x86-64 operating system written in HERB — a declarative, reactive programming language where system behavior is data, not code.

88KB disk image. Assembly at the hardware boundary. HERB everywhere else.

## Boot

```
qemu-system-x86_64 -drive format=raw,file=boot/herb_os.img -m 64 -serial stdio
```

## Build

Requires `nasm`, `gcc` (cross or MinGW), `ld`, `objcopy`, `python3`.

```
cd boot && make
```

## Structure

```
boot/           Bootloader, kernel, HAM bytecode engine, hardware assembly
src/            Freestanding runtime, binary compiler, arena allocator
programs/       HERB program sources (.herb.json → .herb binary)
```

The `.herb` files are behavioral programs — reactive rules that drive autonomous execution toward equilibrium. The kernel loads them as data. The runtime resolves them. Processes don't execute instructions. They *are* their tensions.
