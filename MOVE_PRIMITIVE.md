# THE MOVE PRIMITIVE

Session 24. The pivot within the pivot.

---

## THE CORE INSIGHT

**THE OPERATION SET IS THE CONSTRAINT SYSTEM.**

Session 23's stress tests revealed a fundamental flaw: we check constraints and reject violations. But invalid states still get constructed, then we notice the problem.

The insight: invalid states aren't checked and rejected. They're **unreachable** because no sequence of valid operations leads to them.

Like virtual memory — Process A can't access Process B's memory not because of a check, but because **the operation doesn't exist**. The address 0x1000 in Process A's context IS a different address than 0x1000 in Process B's context. There's no shared address to protect.

---

## THE DOUBLE-SPEND REVISITED

Session 23 found:
```
Alice queues: ASSERT location(sword, alice_inventory)
Bob queues: ASSERT location(sword, bob_inventory)
Both pass preconditions (checked against initial state)
Both apply
Sword in two places
```

The bug isn't in the checking. The bug is that ASSERT is too powerful. We gave the system an operation that can construct invalid states.

**Fix:** Don't have an ASSERT operation for location. Have a MOVE operation:

```
MOVE(entity, from, to)
```

The MOVE only exists if:
- entity IS in `from` (not "was" or "should be" — IS, at the moment of execution)
- (from, to) is a valid transition for this entity type

After Alice's MOVE executes, Bob's MOVE **doesn't exist** because sword is no longer in shop_inventory. Not "fails" — the operation literally isn't there. You can't invoke something that doesn't exist.

---

## MOVE AS THE FUNDAMENTAL PRIMITIVE

MOVE covers three patterns that appear everywhere:

### 1. Containment
Entity in scope. Where something is.

- Process in address space
- File descriptor in process table
- DOM element in document tree
- Thread in core affinity set

### 2. Conservation
Quantity between holders. What moves without being created or destroyed.

- Memory pages between free list and process mapping
- File handles between free pool and open table
- CPU time slices between available pool and process allocation
- Network buffer capacity between available and in-use

### 3. State Machines
Entity in state-as-container. The current state IS a location.

- Process state: READY_QUEUE → RUNNING_SLOT → BLOCKED_QUEUE → READY_QUEUE
- Memory region: UNMAPPED → MAPPED_PRIVATE → COPY_ON_WRITE → MAPPED_SHARED
- TCP connection: CLOSED → SYN_SENT → ESTABLISHED → FIN_WAIT → CLOSED
- DOM element: DETACHED → CONNECTED → BEING_REMOVED → DETACHED

In all three cases, the answer to "what is X's state/location/value?" is "which container is X in?"

---

## GROUNDING: OS EXAMPLES

### Process State (State Machine)

Containers:
- READY_QUEUE
- RUNNING_SLOT_0, RUNNING_SLOT_1, ... (one per CPU core)
- BLOCKED_QUEUE
- ZOMBIE_LIST

Valid moves (the operation set):
```
(READY_QUEUE, RUNNING_SLOT_n)      -- scheduler picks process
(RUNNING_SLOT_n, READY_QUEUE)      -- preemption
(RUNNING_SLOT_n, BLOCKED_QUEUE)    -- process calls blocking syscall
(BLOCKED_QUEUE, READY_QUEUE)       -- I/O completes
(RUNNING_SLOT_n, ZOMBIE_LIST)      -- process exits
(ZOMBIE_LIST, null)                -- parent reaps
```

Invalid moves don't exist. A process can't go from BLOCKED to RUNNING directly. That operation isn't in the set. There's no check because there's no operation to check.

### Memory Mapping (Containment + State)

For a memory region R in process P:

Containers (states):
- UNMAPPED
- MAPPED_PRIVATE(flags)
- MAPPED_SHARED(backing)
- COPY_ON_WRITE(source)

Valid moves:
```
(UNMAPPED, MAPPED_PRIVATE)         -- mmap with MAP_PRIVATE
(UNMAPPED, MAPPED_SHARED)          -- mmap with MAP_SHARED
(MAPPED_*, UNMAPPED)               -- munmap
(MAPPED_SHARED, COPY_ON_WRITE)     -- fork copies shared mapping
(COPY_ON_WRITE, MAPPED_PRIVATE)    -- first write to COW page
```

The operation "access memory at address X" exists only if X is in a mapped region for the current process. For Process B's addresses, that operation doesn't exist in Process A's context.

### File Descriptors (Conservation)

Pool: FREE_FD_POOL(process)
Tables: FD_TABLE_SLOT(process, fd_num)

Valid moves:
```
(FREE_FD_POOL(P), FD_TABLE_SLOT(P, n))    -- open() assigns fd
(FD_TABLE_SLOT(P, n), FREE_FD_POOL(P))    -- close() releases fd
(FD_TABLE_SLOT(P, n), FD_TABLE_SLOT(P, m)) -- dup2() moves fd
```

Conservation: total fd count in (free_pool + table) is constant per process (up to limit).

---

## GROUNDING: BROWSER EXAMPLES

### DOM Element Position (Containment)

Containers:
- DOCUMENT_TREE(parent_element)
- DETACHED_POOL

Valid moves:
```
(DETACHED_POOL, DOCUMENT_TREE(parent))     -- appendChild
(DOCUMENT_TREE(old), DOCUMENT_TREE(new))   -- appendChild when already attached
(DOCUMENT_TREE(parent), DETACHED_POOL)     -- removeChild
```

An element can be in exactly one place. The double-parent bug can't happen because MOVE requires a specific `from`.

### Layout Box (State Machine)

States for a layout box:
- NEEDS_LAYOUT
- LAYING_OUT
- NEEDS_PAINT
- PAINTED
- DIRTY

Valid moves:
```
(NEEDS_LAYOUT, LAYING_OUT)        -- layout engine begins
(LAYING_OUT, NEEDS_PAINT)         -- layout complete
(NEEDS_PAINT, PAINTED)            -- paint complete
(PAINTED, DIRTY)                  -- content changed
(DIRTY, NEEDS_LAYOUT)             -- style recalc
(LAYING_OUT, NEEDS_LAYOUT)        -- child invalidated during layout
```

### Network Request (State Machine)

States:
- UNSENT
- OPENED
- HEADERS_RECEIVED
- LOADING
- DONE
- ABORTED

Valid moves defined by XMLHttpRequest spec. Invalid transitions don't exist.

---

## FREE PROPERTIES VS MOVE PROPERTIES

Not everything is containment/conservation/state-machine. Some properties are "free" — any value in the domain is valid.

Examples:
- Register values in a CPU (any 64-bit value)
- Window width (any positive integer up to screen size)
- Configuration flags (any combination)

For free properties, MOVE degenerates to ASSIGN where the only constraint is domain validity:

```
ASSIGN(property, new_value)  -- where new_value is in valid domain
```

This is just MOVE(property, old_value, new_value) where every (old, new) pair is valid as long as new is in the domain.

The key insight: even "free" properties have a constraint — domain validity. A window width can't be -500. A register can't hold a 65-bit value. The operation ASSIGN(width, -500) doesn't exist.

---

## IMPLEMENTING MOVE

How does this translate to code?

### Schema Declaration

```python
# Define containers (locations/states)
define_container("READY_QUEUE", entity_type="Process")
define_container("RUNNING_SLOT", entity_type="Process", cardinality=CPU_COUNT)
define_container("BLOCKED_QUEUE", entity_type="Process")

# Define valid moves (the operation set)
define_move("schedule",
    from_=["READY_QUEUE"],
    to=["RUNNING_SLOT"])

define_move("preempt",
    from_=["RUNNING_SLOT"],
    to=["READY_QUEUE"])

define_move("block",
    from_=["RUNNING_SLOT"],
    to=["BLOCKED_QUEUE"])

define_move("unblock",
    from_=["BLOCKED_QUEUE"],
    to=["READY_QUEUE"])
```

### Execution

When you call `move("schedule", process, running_slot_0)`:

1. System checks: is process in READY_QUEUE? (Not a "precondition check" — this determines whether the operation exists)
2. If no: operation doesn't exist. Not "fails" — it's not there. Like calling a method that doesn't exist.
3. If yes: atomically remove from READY_QUEUE, add to RUNNING_SLOT_0

There's no intermediate state where process is in neither or both. The move is atomic.

### Quantities (Conservation)

For conserved quantities like "gold between players":

```python
define_quantity_pool("gold_pool", total=10000)
define_quantity_holder("player_gold", entity_type="Player", pool="gold_pool")

define_move("transfer_gold",
    from_=["player_gold"],
    to=["player_gold"],
    amount_param=True)
```

When you call `move("transfer_gold", from_holder=alice, to_holder=bob, amount=100)`:

1. Check: does alice.gold >= 100?
2. If no: operation doesn't exist for this amount
3. If yes: atomically subtract from alice, add to bob

Conservation is guaranteed: the total in the pool never changes.

---

## THE KEY SHIFT

Old model:
```
State exists
Operations mutate state
Constraints check if state is valid
Violations are reported (but state is already corrupted)
```

New model:
```
Operations are defined as valid transitions
State is "where things are" — derived from operation history
Invalid states are unreachable by construction
No "constraint checking" because only valid operations exist
```

This isn't just a different checking strategy. It's a different **ontology**. State isn't primary. Operations are primary. State is a consequence of what operations have occurred.

---

## WHAT THIS MEANS FOR HERB

### Keep
- Delta log (operations are primitive, state is derived)
- Provenance (why did this operation occur)
- Entity/relation structure (things that exist, connections between them)

### Remove
- Preconditions as checks
- Postconditions as checks
- Invariants as checks
- The whole constraint-checking apparatus

### Replace With
- Schema that declares valid operations
- Operations that only exist when applicable
- Atomic moves that can't produce intermediate invalid states

### The AI's Role
The AI constructs and manipulates the schema. It doesn't write "code that checks constraints" — it declares "what operations exist." The constraint system IS the operation set.

---

## NEXT

1. Rewrite herb_graph.py around MOVE as the fundamental primitive
2. Implement containers, quantity pools, state machines
3. Test with OS examples (process scheduling) not game examples
4. Prove that the double-spend bug is structurally impossible

---

*Operations define the world. State is what you observe. Invalid states are like married bachelors — the words exist but they don't refer to anything that can be.*
