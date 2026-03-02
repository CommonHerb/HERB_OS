"""
HERB Compiler — Session 19

Compiles a minimal HERB subset to C for native-speed fact derivation.

SUBSET SUPPORTED:
- Facts: triples (subject, relation, object) — all values are atoms or integers
- Patterns: variables (?x) and constants in any position
- Rules: patterns → single template, no guards, no retractions, no aggregates
- Derivation: fixpoint (rules fire until no new facts)

NOT SUPPORTED (yet):
- Temporal bounds (from_tick, to_tick)
- Provenance (cause, cause_facts)
- Aggregation (sum, count, max, min)
- Negation (not-exists)
- Guards (IF conditions)
- Retractions (RETRACT)
- Deferred rules (=>>)
- Once-per-tick
- Multi-world (Verse)

DESIGN DECISIONS:

1. VALUE INTERNING
   All atoms become integers at compile time. The compiler builds a symbol table
   mapping strings to ints. At runtime, there are no strings — just ints.

   This makes comparison O(1) and storage compact (4 bytes per value).

2. FACT REPRESENTATION
   A fact is three ints: (subject, relation, object).

   struct Fact {
       int subject;
       int relation;
       int object;
   };

   Facts are stored in a dynamic array. We maintain indices for fast lookup.

3. INDEX STRUCTURE
   For pattern matching, we need fast lookup by:
   - (relation, object) — e.g., "all entities where is_a = person"
   - (subject, relation) — e.g., "hero's location"
   - exact triple — for deduplication

   In C, we use hash tables (open addressing, linear probing).

   Key insight: the index doesn't store facts — it stores indices into
   the fact array. This is cache-friendly and dedup-friendly.

4. COMPILED RULES
   Each rule becomes a C function:

   void rule_NAME(FactStore* store) {
       // Iterate over first pattern's matches
       for (...) {
           // Nested loops for additional patterns
           for (...) {
               // Assert the template
               assert_fact(store, s, r, o);
           }
       }
   }

   The fixpoint loop calls all rule functions until none produce new facts.

5. PATTERN MATCHING STRATEGY
   For each pattern in a rule:
   - If relation and object are constants: use (r,o) index
   - If subject and relation are constants: use (s,r) index
   - Otherwise: scan fact array with filters

   Variables are just stack locals that get bound by iteration.

USAGE:

    from herb_compiler import HerbCompiler
    from herb_core import World, Var

    # Build a world with facts and rules
    w = World()
    w.assert_fact("hero", "is_a", "person")
    w.assert_fact("hero", "location", "town")
    w.add_derivation_rule("visibility",
        patterns=[(X, "is_a", "person"), (X, "location", LOC)],
        template=(X, "visible_from", LOC))

    # Compile to C
    compiler = HerbCompiler()
    c_code = compiler.compile(w)

    # Save and build
    with open("herb_runtime.c", "w") as f:
        f.write(c_code)
    # gcc -O3 herb_runtime.c -o herb_runtime

The generated C includes a main() that:
1. Initializes the fact store
2. Asserts initial facts
3. Runs derivation to fixpoint
4. Prints resulting facts
5. Reports timing
"""

from dataclasses import dataclass, field
from typing import Any, Optional
from herb_core import World, Var, Expr, DerivationRule


@dataclass
class SymbolTable:
    """
    Maps values (atoms, numbers) to unique integer IDs.

    All HERB values become integers at compile time. This makes
    comparison O(1) and enables compact representation in C.
    """
    _next_id: int = 0
    _value_to_id: dict[Any, int] = field(default_factory=dict)
    _id_to_value: dict[int, Any] = field(default_factory=dict)

    def intern(self, value: Any) -> int:
        """Get or create an ID for a value."""
        if isinstance(value, Var):
            raise ValueError(f"Cannot intern variable {value}")

        if value in self._value_to_id:
            return self._value_to_id[value]

        id = self._next_id
        self._next_id += 1
        self._value_to_id[value] = id
        self._id_to_value[id] = value
        return id

    def get_id(self, value: Any) -> Optional[int]:
        """Get ID for a value, or None if not interned."""
        return self._value_to_id.get(value)

    def get_value(self, id: int) -> Any:
        """Get value for an ID."""
        return self._id_to_value.get(id)

    def all_symbols(self) -> list[tuple[int, Any]]:
        """Return all (id, value) pairs, sorted by id."""
        return sorted(self._id_to_value.items())


@dataclass
class CompiledPattern:
    """
    A pattern compiled for C code generation.

    Tracks which positions are constants (known at compile time)
    vs variables (bound at runtime).
    """
    subject_const: Optional[int] = None  # None = variable
    relation_const: Optional[int] = None
    object_const: Optional[int] = None
    subject_var: Optional[str] = None    # Variable name if not constant
    relation_var: Optional[str] = None
    object_var: Optional[str] = None

    @property
    def best_index(self) -> str:
        """
        Determine the best index to use for this pattern.

        Priority:
        1. (s, r, o) — exact lookup, O(1)
        2. (s, r) — subject-relation index
        3. (r, o) — relation-object index (common for "is_a X" patterns)
        4. (r) — relation-only (if only relation is constant)
        5. scan — full table scan (fallback)
        """
        if self.subject_const is not None and self.relation_const is not None and self.object_const is not None:
            return "sro"
        if self.subject_const is not None and self.relation_const is not None:
            return "sr"
        if self.relation_const is not None and self.object_const is not None:
            return "ro"
        if self.relation_const is not None:
            return "r"
        return "scan"


class HerbCompiler:
    """
    Compiles a HERB World to C code.

    The generated C includes:
    - Data structures for fact storage
    - Hash tables for indices
    - Compiled rule functions
    - Fixpoint derivation loop
    - Main function for standalone execution
    """

    def __init__(self):
        self.symbols = SymbolTable()
        self.initial_facts: list[tuple[int, int, int]] = []
        self.rules: list[tuple[str, list[CompiledPattern], tuple[Any, Any, Any]]] = []

    def compile(self, world: World) -> str:
        """
        Compile a World to C code.

        Returns complete C source that can be compiled with:
            gcc -O3 output.c -o output
        """
        # Phase 1: Intern all symbols and collect facts
        self._collect_symbols(world)

        # Phase 2: Compile rules
        self._compile_rules(world)

        # Phase 3: Generate C code
        return self._generate_c()

    def _collect_symbols(self, world: World):
        """
        Collect all values from facts and rules, intern them.
        """
        # Collect from facts
        for fact in world.all_facts():
            s = self.symbols.intern(fact.subject)
            r = self.symbols.intern(fact.relation)
            o = self.symbols.intern(fact.object)
            self.initial_facts.append((s, r, o))

        # Collect from rules (constant parts of patterns and templates)
        for rule in world._derivation_rules:
            # Validate: no aggregates, negation, guards, retractions, deferred
            if rule.is_aggregate():
                raise ValueError(f"Rule '{rule.name}' uses aggregation (not supported in compiled subset)")
            if rule.has_negation():
                raise ValueError(f"Rule '{rule.name}' uses negation (not supported in compiled subset)")
            if rule.guard is not None:
                raise ValueError(f"Rule '{rule.name}' has guard (not supported in compiled subset)")
            if rule.retractions:
                raise ValueError(f"Rule '{rule.name}' has retractions (not supported in compiled subset)")
            if rule.deferred:
                raise ValueError(f"Rule '{rule.name}' is deferred (not supported in compiled subset)")
            if len(rule.templates) > 1:
                raise ValueError(f"Rule '{rule.name}' has multiple templates (not supported in compiled subset)")

            for pattern in rule.patterns:
                for val in pattern:
                    if not isinstance(val, Var):
                        self.symbols.intern(val)

            for template in rule.templates:
                for val in template:
                    if not isinstance(val, Var) and not isinstance(val, Expr):
                        self.symbols.intern(val)

    def _compile_rules(self, world: World):
        """
        Compile each rule to intermediate representation.
        """
        for rule in world._derivation_rules:
            patterns = []
            for pattern in rule.patterns:
                cp = CompiledPattern()

                if isinstance(pattern[0], Var):
                    cp.subject_var = pattern[0].name
                else:
                    cp.subject_const = self.symbols.get_id(pattern[0])

                if isinstance(pattern[1], Var):
                    cp.relation_var = pattern[1].name
                else:
                    cp.relation_const = self.symbols.get_id(pattern[1])

                if isinstance(pattern[2], Var):
                    cp.object_var = pattern[2].name
                else:
                    cp.object_const = self.symbols.get_id(pattern[2])

                patterns.append(cp)

            template = rule.templates[0]  # We validated single template above
            self.rules.append((rule.name, patterns, template))

    def _generate_c(self) -> str:
        """
        Generate complete C source code.
        """
        parts = []

        # Header
        parts.append(self._gen_header())

        # Symbol table (as comments for debugging)
        parts.append(self._gen_symbol_comments())

        # Data structures
        parts.append(self._gen_data_structures())

        # Hash table implementation
        parts.append(self._gen_hash_table())

        # Fact store operations
        parts.append(self._gen_fact_store())

        # Compiled rules
        for name, patterns, template in self.rules:
            parts.append(self._gen_rule(name, patterns, template))

        # Derivation loop
        parts.append(self._gen_derivation())

        # Main function
        parts.append(self._gen_main())

        return "\n".join(parts)

    def _gen_header(self) -> str:
        return '''/*
 * HERB Compiled Runtime
 * Generated by herb_compiler.py
 *
 * This is a standalone C program that implements a HERB fact store
 * with derivation rules compiled to native loops.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#define INITIAL_CAPACITY 1024
#define HASH_TABLE_SIZE 4096
'''

    def _gen_symbol_comments(self) -> str:
        lines = ["\n/* Symbol Table (for debugging) */"]
        for id, value in self.symbols.all_symbols():
            # Escape the value for C string
            val_str = str(value).replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'/* {id}: "{val_str}" */')
        return "\n".join(lines)

    def _gen_data_structures(self) -> str:
        return '''
/* ============================================================
 * DATA STRUCTURES
 * ============================================================ */

typedef struct {
    int subject;
    int relation;
    int object;
} Fact;

typedef struct {
    Fact* facts;
    int count;
    int capacity;

    /* Indices: arrays of fact indices, organized by hash */
    int* by_sro;      /* Hash(s,r,o) -> fact index or -1 */
    int* by_sr;       /* Hash(s,r) -> linked list head, -1 if empty */
    int* by_ro;       /* Hash(r,o) -> linked list head, -1 if empty */
    int* sr_next;     /* next pointer for (s,r) chain */
    int* ro_next;     /* next pointer for (r,o) chain */
} FactStore;
'''

    def _gen_hash_table(self) -> str:
        return '''
/* ============================================================
 * HASH FUNCTIONS
 * ============================================================ */

static inline uint32_t hash_combine(uint32_t a, uint32_t b) {
    /* FNV-1a style combination */
    return (a * 16777619) ^ b;
}

static inline uint32_t hash_triple(int s, int r, int o) {
    uint32_t h = 2166136261u;
    h = hash_combine(h, (uint32_t)s);
    h = hash_combine(h, (uint32_t)r);
    h = hash_combine(h, (uint32_t)o);
    return h % HASH_TABLE_SIZE;
}

static inline uint32_t hash_pair_sr(int s, int r) {
    uint32_t h = 2166136261u;
    h = hash_combine(h, (uint32_t)s);
    h = hash_combine(h, (uint32_t)r);
    return h % HASH_TABLE_SIZE;
}

static inline uint32_t hash_pair_ro(int r, int o) {
    uint32_t h = 2166136261u;
    h = hash_combine(h, (uint32_t)r);
    h = hash_combine(h, (uint32_t)o);
    return h % HASH_TABLE_SIZE;
}
'''

    def _gen_fact_store(self) -> str:
        return '''
/* ============================================================
 * FACT STORE OPERATIONS
 * ============================================================ */

FactStore* factstore_new() {
    FactStore* store = malloc(sizeof(FactStore));
    store->capacity = INITIAL_CAPACITY;
    store->count = 0;
    store->facts = malloc(sizeof(Fact) * store->capacity);

    store->by_sro = malloc(sizeof(int) * HASH_TABLE_SIZE);
    store->by_sr = malloc(sizeof(int) * HASH_TABLE_SIZE);
    store->by_ro = malloc(sizeof(int) * HASH_TABLE_SIZE);
    store->sr_next = malloc(sizeof(int) * store->capacity);
    store->ro_next = malloc(sizeof(int) * store->capacity);

    for (int i = 0; i < HASH_TABLE_SIZE; i++) {
        store->by_sro[i] = -1;
        store->by_sr[i] = -1;
        store->by_ro[i] = -1;
    }

    return store;
}

void factstore_free(FactStore* store) {
    free(store->facts);
    free(store->by_sro);
    free(store->by_sr);
    free(store->by_ro);
    free(store->sr_next);
    free(store->ro_next);
    free(store);
}

/* Check if fact exists using SRO index */
int factstore_exists(FactStore* store, int s, int r, int o) {
    uint32_t h = hash_triple(s, r, o);
    int idx = store->by_sro[h];

    /* Linear probing for collisions */
    int probes = 0;
    while (idx >= 0 && probes < HASH_TABLE_SIZE) {
        Fact* f = &store->facts[idx];
        if (f->subject == s && f->relation == r && f->object == o) {
            return 1;
        }
        h = (h + 1) % HASH_TABLE_SIZE;
        idx = store->by_sro[h];
        probes++;
    }
    return 0;
}

/* Assert a new fact. Returns 1 if new, 0 if already exists. */
int factstore_assert(FactStore* store, int s, int r, int o) {
    /* Check if already exists */
    if (factstore_exists(store, s, r, o)) {
        return 0;
    }

    /* Grow if needed */
    if (store->count >= store->capacity) {
        store->capacity *= 2;
        store->facts = realloc(store->facts, sizeof(Fact) * store->capacity);
        store->sr_next = realloc(store->sr_next, sizeof(int) * store->capacity);
        store->ro_next = realloc(store->ro_next, sizeof(int) * store->capacity);
    }

    /* Add fact */
    int idx = store->count++;
    store->facts[idx].subject = s;
    store->facts[idx].relation = r;
    store->facts[idx].object = o;

    /* Update SRO index (linear probing) */
    uint32_t h = hash_triple(s, r, o);
    while (store->by_sro[h] >= 0) {
        h = (h + 1) % HASH_TABLE_SIZE;
    }
    store->by_sro[h] = idx;

    /* Update SR index (linked list) */
    uint32_t hsr = hash_pair_sr(s, r);
    store->sr_next[idx] = store->by_sr[hsr];
    store->by_sr[hsr] = idx;

    /* Update RO index (linked list) */
    uint32_t hro = hash_pair_ro(r, o);
    store->ro_next[idx] = store->by_ro[hro];
    store->by_ro[hro] = idx;

    return 1;
}

/* Print all facts */
void factstore_print(FactStore* store, const char** symbols, int symbol_count) {
    printf("=== Fact Store (%d facts) ===\\n", store->count);
    for (int i = 0; i < store->count; i++) {
        Fact* f = &store->facts[i];
        const char* s_str = (f->subject < symbol_count) ? symbols[f->subject] : "?";
        const char* r_str = (f->relation < symbol_count) ? symbols[f->relation] : "?";
        const char* o_str = (f->object < symbol_count) ? symbols[f->object] : "?";
        printf("  (%s %s %s)\\n", s_str, r_str, o_str);
    }
}
'''

    def _gen_rule(self, name: str, patterns: list[CompiledPattern], template: tuple) -> str:
        """
        Generate C code for a single rule.

        The generated function iterates over pattern matches and asserts
        the template for each successful binding.
        """
        lines = [f"\n/* Rule: {name} */"]
        lines.append(f"int rule_{self._safe_name(name)}(FactStore* store) {{")
        lines.append("    int derived = 0;")

        # Track which variables are bound at each nesting level
        bound_vars: set[str] = set()
        indent = "    "

        for i, pattern in enumerate(patterns):
            # Generate iteration code based on best index
            idx_type = pattern.best_index

            if idx_type == "ro" and pattern.relation_const is not None and pattern.object_const is not None:
                # Iterate using (relation, object) index
                r_id = pattern.relation_const
                o_id = pattern.object_const
                var_name = f"idx_{i}"
                lines.append(f"{indent}/* Pattern {i}: (?, {r_id}, {o_id}) using RO index */")
                lines.append(f"{indent}int {var_name} = store->by_ro[hash_pair_ro({r_id}, {o_id})];")
                lines.append(f"{indent}while ({var_name} >= 0) {{")
                lines.append(f"{indent}    Fact* f{i} = &store->facts[{var_name}];")
                lines.append(f"{indent}    if (f{i}->relation == {r_id} && f{i}->object == {o_id}) {{")

                # Bind subject variable if present
                if pattern.subject_var:
                    lines.append(f"{indent}        int {pattern.subject_var} = f{i}->subject;")
                    bound_vars.add(pattern.subject_var)

                indent += "        "

            elif idx_type == "sr" and pattern.subject_const is not None and pattern.relation_const is not None:
                # Iterate using (subject, relation) index
                s_id = pattern.subject_const
                r_id = pattern.relation_const
                var_name = f"idx_{i}"
                lines.append(f"{indent}/* Pattern {i}: ({s_id}, {r_id}, ?) using SR index */")
                lines.append(f"{indent}int {var_name} = store->by_sr[hash_pair_sr({s_id}, {r_id})];")
                lines.append(f"{indent}while ({var_name} >= 0) {{")
                lines.append(f"{indent}    Fact* f{i} = &store->facts[{var_name}];")
                lines.append(f"{indent}    if (f{i}->subject == {s_id} && f{i}->relation == {r_id}) {{")

                # Bind object variable if present
                if pattern.object_var:
                    lines.append(f"{indent}        int {pattern.object_var} = f{i}->object;")
                    bound_vars.add(pattern.object_var)

                indent += "        "

            elif pattern.subject_var and pattern.subject_var in bound_vars and pattern.relation_const is not None:
                # Subject is already bound, relation is constant — use SR index
                s_var = pattern.subject_var
                r_id = pattern.relation_const
                var_name = f"idx_{i}"
                lines.append(f"{indent}/* Pattern {i}: (bound:{s_var}, {r_id}, ?) using SR index */")
                lines.append(f"{indent}int {var_name} = store->by_sr[hash_pair_sr({s_var}, {r_id})];")
                lines.append(f"{indent}while ({var_name} >= 0) {{")
                lines.append(f"{indent}    Fact* f{i} = &store->facts[{var_name}];")

                # Build condition: subject and relation must match, plus any bound object var
                conditions = [f"f{i}->subject == {s_var}", f"f{i}->relation == {r_id}"]
                if pattern.object_var and pattern.object_var in bound_vars:
                    conditions.append(f"f{i}->object == {pattern.object_var}")

                lines.append(f"{indent}    if ({' && '.join(conditions)}) {{")

                # Bind object variable if present and not already bound
                if pattern.object_var and pattern.object_var not in bound_vars:
                    lines.append(f"{indent}        int {pattern.object_var} = f{i}->object;")
                    bound_vars.add(pattern.object_var)

                indent += "        "

            else:
                # Fallback: full scan
                lines.append(f"{indent}/* Pattern {i}: full scan */")
                lines.append(f"{indent}for (int j{i} = 0; j{i} < store->count; j{i}++) {{")
                lines.append(f"{indent}    Fact* f{i} = &store->facts[j{i}];")

                # Generate conditions
                conditions = []
                if pattern.relation_const is not None:
                    conditions.append(f"f{i}->relation == {pattern.relation_const}")
                if pattern.subject_const is not None:
                    conditions.append(f"f{i}->subject == {pattern.subject_const}")
                if pattern.object_const is not None:
                    conditions.append(f"f{i}->object == {pattern.object_const}")
                if pattern.subject_var and pattern.subject_var in bound_vars:
                    conditions.append(f"f{i}->subject == {pattern.subject_var}")
                if pattern.object_var and pattern.object_var in bound_vars:
                    conditions.append(f"f{i}->object == {pattern.object_var}")

                if conditions:
                    lines.append(f"{indent}    if ({' && '.join(conditions)}) {{")
                    indent += "        "
                else:
                    lines.append(f"{indent}    {{")
                    indent += "    "

                # Bind new variables
                if pattern.subject_var and pattern.subject_var not in bound_vars:
                    lines.append(f"{indent}int {pattern.subject_var} = f{i}->subject;")
                    bound_vars.add(pattern.subject_var)
                if pattern.relation_var and pattern.relation_var not in bound_vars:
                    lines.append(f"{indent}int {pattern.relation_var} = f{i}->relation;")
                    bound_vars.add(pattern.relation_var)
                if pattern.object_var and pattern.object_var not in bound_vars:
                    lines.append(f"{indent}int {pattern.object_var} = f{i}->object;")
                    bound_vars.add(pattern.object_var)

        # Generate template assertion
        def resolve_template_elem(elem) -> str:
            if isinstance(elem, Var):
                if elem.name not in bound_vars:
                    raise ValueError(f"Template uses unbound variable ?{elem.name}")
                return elem.name
            elif isinstance(elem, Expr):
                raise ValueError(f"Expressions in templates not yet supported in compiler")
            else:
                return str(self.symbols.get_id(elem))

        t_s = resolve_template_elem(template[0])
        t_r = resolve_template_elem(template[1])
        t_o = resolve_template_elem(template[2])

        lines.append(f"{indent}/* Assert template */")
        lines.append(f"{indent}derived += factstore_assert(store, {t_s}, {t_r}, {t_o});")

        # Close all the loops
        for i in range(len(patterns) - 1, -1, -1):
            pattern = patterns[i]
            idx_type = pattern.best_index

            if idx_type in ("ro", "sr") or (pattern.subject_var and pattern.subject_var in bound_vars):
                # Close condition check
                indent = indent[:-8]
                lines.append(f"{indent}    }}")
                # Close while loop with next pointer
                if idx_type == "ro":
                    lines.append(f"{indent}    idx_{i} = store->ro_next[idx_{i}];")
                else:
                    lines.append(f"{indent}    idx_{i} = store->sr_next[idx_{i}];")
                lines.append(f"{indent}}}")
            else:
                # Close scan loop
                indent = indent[:-8] if len(indent) > 4 else indent
                lines.append(f"{indent}    }}")
                lines.append(f"{indent}}}")

        lines.append("    return derived;")
        lines.append("}")

        return "\n".join(lines)

    def _gen_derivation(self) -> str:
        rule_calls = []
        for name, _, _ in self.rules:
            rule_calls.append(f"        derived += rule_{self._safe_name(name)}(store);")

        rule_calls_str = "\n".join(rule_calls)

        return f'''
/* ============================================================
 * DERIVATION (FIXPOINT LOOP)
 * ============================================================ */

int derive_to_fixpoint(FactStore* store, int max_iterations) {{
    int total_derived = 0;
    int iteration = 0;

    while (iteration < max_iterations) {{
        int derived = 0;
{rule_calls_str}

        if (derived == 0) {{
            break;  /* Fixpoint reached */
        }}
        total_derived += derived;
        iteration++;
    }}

    return total_derived;
}}
'''

    def _gen_main(self) -> str:
        # Generate initial fact assertions
        fact_lines = []
        for s, r, o in self.initial_facts:
            fact_lines.append(f"    factstore_assert(store, {s}, {r}, {o});")
        fact_assertions = "\n".join(fact_lines)

        # Generate symbol table for printing
        symbol_lines = []
        for id, value in self.symbols.all_symbols():
            val_str = str(value).replace("\\", "\\\\").replace('"', '\\"')
            symbol_lines.append(f'    "{val_str}"')
        symbols_array = ",\n".join(symbol_lines)
        symbol_count = len(self.symbols.all_symbols())

        return f'''
/* ============================================================
 * MAIN
 * ============================================================ */

/* Symbol table for printing */
const char* symbols[] = {{
{symbols_array}
}};

int main() {{
    printf("HERB Compiled Runtime\\n");
    printf("======================\\n\\n");

    /* Create fact store */
    FactStore* store = factstore_new();

    /* Assert initial facts */
    printf("Asserting initial facts...\\n");
{fact_assertions}
    printf("Initial facts: %d\\n\\n", store->count);

    /* Run derivation */
    printf("Running derivation...\\n");
    clock_t start = clock();
    int derived = derive_to_fixpoint(store, 1000);
    clock_t end = clock();
    double time_ms = (double)(end - start) * 1000.0 / CLOCKS_PER_SEC;

    printf("Derived %d new facts in %.3f ms\\n\\n", derived, time_ms);

    /* Print results */
    factstore_print(store, symbols, {symbol_count});

    /* Cleanup */
    factstore_free(store);

    return 0;
}}
'''

    def _safe_name(self, name: str) -> str:
        """Convert a rule name to a valid C identifier."""
        return "".join(c if c.isalnum() else "_" for c in name)


# =============================================================================
# BENCHMARK: Python vs C
# =============================================================================

def create_test_world() -> World:
    """
    Create a test world for benchmarking.

    This world has:
    - 100 entities (entity_0 through entity_99)
    - Each entity is_a person
    - Each entity has a location (one of 10 zones)
    - Rule: person in same location => sees each other

    This tests O(N²) pattern matching — the expensive case.
    """
    from herb_core import World, Var

    world = World()
    X, Y, Z = Var('x'), Var('y'), Var('z')

    # 100 entities
    for i in range(100):
        world.assert_fact(f"entity_{i}", "is_a", "person")
        world.assert_fact(f"entity_{i}", "location", f"zone_{i % 10}")

    # Rule: entities in same location see each other
    world.add_derivation_rule(
        "visibility",
        patterns=[
            (X, "is_a", "person"),
            (Y, "is_a", "person"),
            (X, "location", Z),
            (Y, "location", Z)
        ],
        template=(X, "sees", Y)
    )

    return world


if __name__ == "__main__":
    print("HERB Compiler — Test\n")

    # Create test world
    world = create_test_world()
    print(f"Created world with {len(world)} facts")
    print(f"Rules: {len(world._derivation_rules)}")

    # Compile to C
    compiler = HerbCompiler()
    c_code = compiler.compile(world)

    # Save the generated C
    output_path = "herb_compiled_test.c"
    with open(output_path, "w") as f:
        f.write(c_code)

    print(f"\nGenerated C code saved to: {output_path}")
    print(f"Symbols interned: {len(compiler.symbols.all_symbols())}")
    print(f"Initial facts: {len(compiler.initial_facts)}")
    print(f"Compiled rules: {len(compiler.rules)}")

    print("\nTo compile and run:")
    print(f"  gcc -O3 {output_path} -o herb_test")
    print(f"  ./herb_test")

    print("\n--- First 50 lines of generated C ---")
    for i, line in enumerate(c_code.split("\n")[:50]):
        print(line)
