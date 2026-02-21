# HERB Binary Format Specification

Version 1. HERB's native program representation.

Every byte has HERB semantics. No general-purpose serialization. No borrowed spec.

---

## Overview

A `.herb` file is a compiled HERB program. It contains the same information as a `.herb.json` file — entity types, containers, moves, tensions, entities — but encoded as a compact binary stream instead of JSON text.

**Properties:**
- **Compact** — 81-90% smaller than equivalent JSON
- **Simple to load** — 420 lines of C vs 685 for JSON (39% reduction)
- **Self-contained** — no external format dependencies
- **Streamable** — read sequentially from a byte buffer, no seeking
- **Versionable** — magic number + version byte for future evolution
- **Little-endian** — matches x86-64 target architecture

---

## File Structure

```
Header (8 bytes)
String Table
Sections (in dependency order)
End Marker (1 byte)
```

### Header

| Offset | Size | Field | Value |
|--------|------|-------|-------|
| 0 | 4 | Magic | `HERB` (0x48 0x45 0x52 0x42) |
| 4 | 1 | Version | 1 |
| 5 | 1 | Flags | 0 (reserved) |
| 6 | 2 | String count | u16le |

### String Table

All names in the program (entity types, container names, property keys, operator symbols, etc.) are collected into a string table. Everything else references strings by their u16 index. Index `0xFFFF` means "none/any."

For each string:

| Size | Field |
|------|-------|
| 1 | Length (u8, max 255) |
| N | UTF-8 bytes (NOT null-terminated) |

### Sections

Sections appear in strict dependency order. Each section starts with a tag byte and a count.

| Tag | Section | Must follow |
|-----|---------|-------------|
| 0x01 | Entity Types | — |
| 0x02 | Containers | Entity Types |
| 0x03 | Moves | Containers |
| 0x04 | Pools | — |
| 0x05 | Transfers | Pools |
| 0x06 | Entities | Containers, Entity Types |
| 0x07 | Channels | Entities |
| 0x08 | Config | — |
| 0x09 | Tensions | Everything else |
| 0xFF | End | — |

---

## Section Formats

### 0x01: Entity Types

```
tag: u8 = 0x01
count: u16
For each entity type:
    name_idx: u16          (string index)
    scoped_count: u8       (number of scoped container templates)
    For each scoped container:
        name_idx: u16      (scope container name)
        kind: u8           (0 = simple, 1 = slot)
        entity_type: u16   (string index, 0xFFFF = any)
```

### 0x02: Containers

```
tag: u8 = 0x02
count: u16
For each container:
    name_idx: u16
    kind: u8               (0 = simple, 1 = slot)
    entity_type: u16       (0xFFFF = any)
```

### 0x03: Moves

```
tag: u8 = 0x03
count: u16
For each move:
    name_idx: u16
    entity_type: u16       (0xFFFF = any)
    is_scoped: u8          (0 = regular, 1 = scoped)
    from_count: u8
    from_idxs: u16[from_count]  (string indices — container names if regular, scope names if scoped)
    to_count: u8
    to_idxs: u16[to_count]
```

### 0x04: Pools

```
tag: u8 = 0x04
count: u16
For each pool:
    name_idx: u16          (pool name)
    property_idx: u16      (conserved property name)
```

### 0x05: Transfers

```
tag: u8 = 0x05
count: u16
For each transfer:
    name_idx: u16
    pool_idx: u16          (string index of pool name)
    entity_type: u16       (0xFFFF = any)
```

### 0x06: Entities

```
tag: u8 = 0x06
count: u16
For each entity:
    name_idx: u16
    type_idx: u16
    in_kind: u8            (0 = normal, 1 = scoped)
    if normal:
        container_idx: u16 (string index of container name)
    if scoped:
        scope_entity: u16  (string index of owner entity name)
        container: u16     (string index of scope container name)
    prop_count: u8
    For each property:
        key_idx: u16       (string index)
        value_kind: u8     (0 = int, 1 = float, 2 = string)
        if int: value: i64le
        if float: value: f64le
        if string: value_idx: u16
```

### 0x07: Channels

```
tag: u8 = 0x07
count: u16
For each channel:
    name_idx: u16
    from_entity: u16      (string index of sender entity name)
    to_entity: u16        (string index of receiver entity name)
    entity_type: u16      (0xFFFF = any)
```

### 0x08: Config

```
tag: u8 = 0x08
max_nesting_depth: i16le  (-1 = unlimited)
```

### 0x09: Tensions

```
tag: u8 = 0x09
count: u16
For each tension:
    name_idx: u16
    priority: i16le
    pair_mode: u8          (0 = zip, 1 = cross)
    match_count: u8
    For each match clause:
        (see Match Clause Encoding)
    emit_count: u8
    For each emit clause:
        (see Emit Clause Encoding)
```

### 0xFF: End

```
tag: u8 = 0xFF
```

---

## Match Clause Encoding

Each match clause starts with a kind byte:

### 0x00: Entity In

```
kind: u8 = 0x00
bind_idx: u16              (string index, 0xFFFF = no binding)
required: u8               (1 = required, 0 = optional)
select: u8                 (0 = first, 1 = each, 2 = max_by, 3 = min_by)
key_idx: u16               (string index for max_by/min_by key, 0xFFFF = none)
in_kind: u8                (0 = normal, 1 = scoped, 2 = channel)
if normal:
    container_idx: u16     (string index of container name)
if scoped:
    scope_bind: u16        (string index of scope binding name)
    container: u16         (string index of scope container name)
if channel:
    channel_idx: u16       (string index of channel name)
has_where: u8              (0 = no where, 1 = where expression follows)
if has_where:
    expression             (see Expression Encoding)
```

### 0x01: Empty In

```
kind: u8 = 0x01
bind_idx: u16
select: u8                 (0 = first, 1 = each)
count: u8
container_idxs: u16[count] (string indices of container names)
```

### 0x02: Container Is

```
kind: u8 = 0x02
container_idx: u16         (string index of container name)
is_empty: u8               (1 = empty, 0 = occupied)
```

### 0x03: Guard

```
kind: u8 = 0x03
expression                 (see Expression Encoding)
```

---

## Emit Clause Encoding

Each emit clause starts with a kind byte:

### 0x00: Move

```
kind: u8 = 0x00
move_idx: u16              (string index of move type name)
entity_idx: u16            (string index of entity ref / binding name)
to_ref                     (see Target Reference Encoding)
```

### 0x01: Set

```
kind: u8 = 0x01
entity_idx: u16            (string index of entity ref)
prop_idx: u16              (string index of property name)
value_expr                 (see Expression Encoding)
```

### 0x02: Send

```
kind: u8 = 0x02
channel_idx: u16           (string index of channel name)
entity_idx: u16            (string index of entity ref)
```

### 0x03: Receive

```
kind: u8 = 0x03
channel_idx: u16           (string index of channel name)
entity_idx: u16            (string index of entity ref)
to_ref                     (see Target Reference Encoding)
```

### 0x04: Transfer

```
kind: u8 = 0x04
transfer_idx: u16          (string index of transfer type name)
from_idx: u16              (string index of source entity ref)
to_idx: u16                (string index of target entity ref)
amount_expr                (see Expression Encoding)
```

### 0x05: Duplicate

```
kind: u8 = 0x05
entity_idx: u16            (string index of entity ref)
in_ref                     (see Target Reference Encoding)
```

---

## Target Reference Encoding

Used for "to" in moves/receives and "in" in duplicates:

```
kind: u8
0x00 = Normal:  str_idx: u16      (string index of container/binding name)
0x01 = Scoped:  scope: u16, container: u16  (scope binding + scope container name)
0x02 = None:    (no additional data)
```

---

## Expression Encoding

Expressions are encoded inline as recursive tagged unions. Each starts with a kind byte:

```
0x00 = Int:            value: i64le
0x01 = Float:          value: f64le
0x02 = String:         str_idx: u16
0x03 = Bool:           value: u8 (0/1)
0x04 = Prop:           prop_str: u16, of_str: u16 (0xFFFF = context entity)
0x05 = Count Container: container_str: u16
0x06 = Count Scoped:   scope_str: u16, container_str: u16
0x07 = Count Channel:  channel_str: u16
0x08 = Binary Op:      op_str: u16, left_expr (recursive), right_expr (recursive)
0x09 = Unary Not:      arg_expr (recursive)
0x0A = In-Of:          container_str: u16, entity_str: u16
0xFF = Null:           (no expression — terminator)
```

---

## Compilation

```
.herb.json  →  herb_compile.py  →  .herb binary
```

The compiler collects all unique strings, assigns indices, then writes sections in dependency order. Composed programs (those with a `"compose"` key) are automatically flattened before compilation.

---

## Loading

The runtime's `herb_load()` function auto-detects format by checking the first 4 bytes:
- If they match `HERB`, the binary loader runs
- Otherwise, the JSON parser runs

This means `herb_load()` transparently accepts both formats. The binary path reads the string table, then processes sections sequentially — no tree building, no key lookup, just direct reads into the graph.

---

## Size Comparison

| Program | JSON (bytes) | Binary (bytes) | Reduction |
|---------|-------------|----------------|-----------|
| scheduler | 4,072 | 531 | 87% |
| priority_scheduler | 4,252 | 573 | 87% |
| dom_layout | 4,174 | 577 | 86% |
| economy | 3,878 | 561 | 86% |
| interactive_os | 4,954 | 964 | 81% |
| multiprocess | 7,400 | 924 | 88% |
| ipc | 10,095 | 1,241 | 88% |
| process_dimensions | 6,679 | 950 | 86% |
| multiprocess_modules | 9,943 | 1,169 | 88% |
| kernel (4-module) | 17,941 | 1,795 | 90% |

---

## Why Not Protobuf / MessagePack / CBOR / etc.

Every byte in a `.herb` file has HERB semantics. The format knows what a tension is, what an expression tree looks like, what a scoped container reference means. A general-purpose format would require an additional schema layer, add parsing overhead for type tags it doesn't need, and create a dependency on someone else's specification.

HERB's format is simpler than any of these because it encodes exactly one thing: a HERB program. No more, no less.

---

*This format is HERB's native representation. JSON was scaffolding. This is permanent.*
