# HERB v2 Stress Test Findings

## Date: 2026-02-05 (Session 23)

## Summary

The stress tests revealed **critical bugs** in the resolution loop that would cause catastrophic failures in a real game scenario.

---

## CRITICAL: Double-Spend Bug

### Reproduction
When two players queue purchases of the same item in the same resolution cycle:
- Both purchases succeed
- Item ends up in BOTH inventories
- Gold is destroyed (not conserved)

### Test Output
```
Initial state:
  Alice: 500 gold
  Bob: 500 gold
  Shop: 100 gold
  Sword location: shop_inventory
  Total gold: 2100

Final state:
  Alice: 400 gold
  Bob: 400 gold
  Shop: 200 gold
  Sword locations: 2
    - bob_inventory
    - alice_inventory
  Total gold: 2000

ISSUES FOUND:
  [!] CRITICAL: Sword is in multiple places!
  [!] CRITICAL: Gold not conserved (2100 -> 2000)
  [!] BUG: Both players paid for the sword
```

### Root Cause
Preconditions are checked against the **initial state** of the resolution cycle, not against the state as it will be after earlier deltas are applied.

When both Alice and Bob queue their purchase:
1. Alice's precondition checks: "Is sword in shop?" → Yes
2. Bob's precondition checks: "Is sword in shop?" → Yes (still checking initial state!)
3. Alice's deltas apply
4. Bob's deltas apply (including asserting sword location)
5. Result: sword in two places

### Impact
**Catastrophic** - This would allow item duplication in a game.

---

## HIGH: Invariants Detect But Don't Prevent

### Observation
Invariants fire AFTER the delta is applied, meaning:
- We detect the bug
- The state is already corrupted
- Violation is reported but state remains invalid

### Example
```
Asserting sword location in player inventory (without retracting from shop)...
Resolution result: CONSTRAINT_VIOLATIONS
Violations: 1
  - Invariant 'item_unique_location' violated
Sword locations after resolve: 2  <- State is still corrupted!
```

### Root Cause
The current flow is:
1. Apply pending delta
2. Check postconditions
3. Check invariants
4. Report violations

But step 1 already mutated state. We need either:
- Rollback capability
- Pre-apply validation
- Transactional semantics

---

## MEDIUM: Tax Rate TOCTOU

### Observation
A player can use a stale tax rate if:
1. Player reads tax rate (10%)
2. Government changes tax rate to 50%
3. Player purchases with observed 10% rate
4. Treasury only receives 10% tax

### Root Cause
`execute_purchase` trusts the caller-provided tax rate instead of looking it up at execution time.

### Fix
Either:
1. `execute_purchase` looks up current rate internally
2. Use a derived constraint that computes tax from current state
3. Make tax rate lookup part of the precondition/execution

---

## MEDIUM: Precondition Timing

### Observation
When multiple deltas are queued, preconditions for ALL of them are checked against the initial state before ANY are applied.

### Example
Two `purchase_intent` assertions both pass the "item in shop" precondition because neither sees the effect of the other.

### Root Cause
`apply_pending_deltas` checks preconditions in a loop before applying, but doesn't re-check as state changes.

---

## Design Questions to Resolve

### 1. Should preconditions see intermediate state?
**Option A**: Check precondition → apply → check next precondition → apply next
- Pro: Each delta sees effect of previous
- Con: Order-dependent, slower

**Option B**: Check all → apply all (current behavior)
- Pro: Faster, order-independent
- Con: Race conditions as demonstrated

**Option C**: Transactional groups that succeed or fail atomically
- Pro: Clean semantics
- Con: More complex implementation

### 2. Should invariant violations rollback?
**Option A**: Violation = error state (current)
- Pro: Simple
- Con: Corrupted state persists

**Option B**: Violation = automatic rollback
- Pro: State always valid
- Con: Need rollback mechanism

**Option C**: Violation = trigger repair constraint
- Pro: Declarative
- Con: Repair might not be possible

### 3. How should atomic transactions work?
The `transaction_group` field exists in `PendingDelta` but isn't implemented.

Need to define:
- How to group deltas
- What triggers rollback
- How rollback actually works (replay without bad deltas? undo log?)

---

## Recommended Fixes (Priority Order)

### P0: Prevent Double-Spend
1. Add `UNIQUENESS` constraint type that prevents duplicates at assertion time
2. Or: Check preconditions after each delta application
3. Or: Implement transaction rollback

### P1: Make Invariant Violations Recoverable
1. Implement undo log for deltas
2. On invariant violation, rollback to pre-delta state
3. Mark delta as rejected

### P2: Fix Tax Rate TOCTOU
1. Move tax lookup into derived constraint
2. Or: Have resolution look up fresh values

### P3: Implement Transaction Groups
1. Deltas with same `transaction_group` succeed/fail atomically
2. On any violation, rollback entire group

---

## Test Files

- `src/stress_purchase.py` - All stress tests
- `src/test_purchase.py` - Basic purchase tests
- `src/test_resolution.py` - Resolution loop tests

Run with: `python stress_purchase.py`
