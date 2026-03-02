"""
HERB Core Runtime — Second Attempt

Key insight: The world state IS the program. Not "code that manipulates state" but
"state that evolves according to its own nature."

What makes this different from RDF/SPARQL/production systems:

1. TEMPORAL FACTS - Facts aren't true/false. They're true FROM a tick TO a tick.
   You can ask "what is true now" but also "what was true then" and "what changed."

2. PROVENANCE - Every fact knows WHY it's true. What rule derived it? What action
   asserted it? What facts did those depend on? You can trace causality backward.

3. REIFIED RELATIONS - Facts about facts. The purchase event isn't just
   (player, bought, sword). It's a fact-entity you can attach other facts to:
   (purchase_17, price, 50), (purchase_17, location, shop_3), etc.

4. RULES AS FACTS - Rules live in the fact store. They're queryable, modifiable,
   derivable. "If condition X, add rule Y" is a valid meta-rule.

This isn't a library wrapping Python. This is exploring what the paradigm can do
that existing approaches can't do as cleanly.
"""

from dataclasses import dataclass, field
from typing import Any, Callable, Iterator, Optional
from collections import defaultdict
import itertools


# =============================================================================
# EXPRESSIONS: COMPUTATION IN TEMPLATES
# =============================================================================

@dataclass
class Expr:
    """
    An expression that computes a value from variables.

    Expressions live in rule templates. When a rule fires, expressions are
    evaluated with the variable bindings from pattern matching.

    Examples:
        Expr('+', [Var('hp'), 10])  ->  ?hp + 10
        Expr('-', [Var('hp'), Var('damage')])  ->  ?hp - ?damage
        Expr('>', [Var('hp'), 0])  ->  ?hp > 0 (boolean)
    """
    op: str
    args: list  # Can contain literals, Vars, or nested Exprs

    def __repr__(self):
        args_str = ' '.join(str(a) for a in self.args)
        return f"({self.op} {args_str})"


@dataclass
class AggregateExpr:
    """
    An aggregate expression that computes a value over multiple matches.

    Aggregate expressions query the world and reduce results:
        AggregateExpr('sum', Var('bonus'), [(X, 'has_bonus', Var('bonus'))])
        -> Sum of all ?bonus values where any X has_bonus ?bonus

    These can ONLY appear in aggregate rules, which run in Phase 2 after
    base rules reach fixpoint. This ensures aggregates see a stable fact base.

    Spec reference: §4.3, §5.4, §6.3
    """
    op: str  # 'sum', 'count', 'max', 'min'
    var: Optional['Var']  # Variable to aggregate (None for 'count')
    patterns: list[tuple]  # WHERE patterns

    def __repr__(self):
        if self.var:
            patterns_str = ' '.join(f"({p[0]} {p[1]} {p[2]})" for p in self.patterns)
            return f"({self.op} {self.var} WHERE {patterns_str})"
        else:
            patterns_str = ' '.join(f"({p[0]} {p[1]} {p[2]})" for p in self.patterns)
            return f"({self.op} WHERE {patterns_str})"


@dataclass
class NotExistsExpr:
    """
    A negation expression that checks for the absence of a fact.

    NotExistsExpr([(Var('shop'), 'exemption', Var('j'))])
    -> True if no fact matches (?shop exemption ?j) with current bindings

    Variables in the pattern MUST be bound from preceding positive patterns.
    This expression cannot introduce new bindings.

    Rules containing not-exists run in Phase 2 after base rules reach fixpoint.
    This ensures the negated facts have stabilized.

    Spec reference: §11
    """
    patterns: list[tuple]  # Patterns to check for absence

    def __repr__(self):
        patterns_str = ' '.join(f"({p[0]} {p[1]} {p[2]})" for p in self.patterns)
        return f"(not-exists {patterns_str})"


def evaluate_expr(expr: 'Expr', bindings: dict[str, Any], world: 'World' = None) -> Any:
    """
    Evaluate an expression with variable bindings.

    This is the arithmetic heart of HERB. Expressions in templates are
    evaluated here when rules fire.

    The world parameter is needed for aggregate and negation expressions.
    """
    # Handle NotExistsExpr at top level (it can be a guard directly)
    if isinstance(expr, NotExistsExpr):
        if world is None:
            raise ValueError("not-exists expressions require world context")
        return evaluate_not_exists_expr(expr, bindings, world)

    # Handle AggregateExpr at top level
    if isinstance(expr, AggregateExpr):
        if world is None:
            raise ValueError("Aggregate expressions require world context")
        return evaluate_aggregate_expr(expr, bindings, world)

    def resolve(val):
        if isinstance(val, Var):
            if val.name not in bindings:
                raise ValueError(f"Unbound variable: ?{val.name}")
            return bindings[val.name]
        elif isinstance(val, Expr):
            return evaluate_expr(val, bindings, world)
        elif isinstance(val, AggregateExpr):
            if world is None:
                raise ValueError("Aggregate expressions require world context")
            return evaluate_aggregate_expr(val, bindings, world)
        elif isinstance(val, NotExistsExpr):
            if world is None:
                raise ValueError("not-exists expressions require world context")
            return evaluate_not_exists_expr(val, bindings, world)
        return val

    args = [resolve(a) for a in expr.args]
    op = expr.op

    # Arithmetic
    if op == '+':
        return sum(args)
    elif op == '-':
        return args[0] - args[1] if len(args) == 2 else -args[0]
    elif op == '*':
        result = 1
        for a in args:
            result *= a
        return result
    elif op == '/':
        return args[0] / args[1]
    elif op == 'max':
        return max(args)
    elif op == 'min':
        return min(args)
    elif op == 'abs':
        return abs(args[0])
    elif op == 'mod':
        return args[0] % args[1]

    # Comparison (return boolean)
    elif op == '=':
        return args[0] == args[1]
    elif op == 'not=':
        return args[0] != args[1]
    elif op == '<':
        return args[0] < args[1]
    elif op == '>':
        return args[0] > args[1]
    elif op == '<=':
        return args[0] <= args[1]
    elif op == '>=':
        return args[0] >= args[1]

    # Boolean logic
    elif op == 'and':
        return all(args)
    elif op == 'or':
        return any(args)
    elif op == 'not':
        return not args[0]

    else:
        raise ValueError(f"Unknown operator: {op}")


def evaluate_aggregate_expr(agg: 'AggregateExpr', bindings: dict[str, Any], world: 'World') -> Any:
    """
    Evaluate an aggregate expression by querying the world.

    This runs the WHERE patterns as a query, collects all matching bindings,
    extracts the specified variable from each, and applies the aggregate.

    Spec reference: §4.3, §6.3
    """
    # Substitute any bound variables into the patterns
    def substitute_pattern(pattern):
        def sub(val):
            if isinstance(val, Var) and val.name in bindings:
                return bindings[val.name]
            return val
        return (sub(pattern[0]), sub(pattern[1]), sub(pattern[2]))

    substituted_patterns = [substitute_pattern(p) for p in agg.patterns]

    # Query the world with these patterns
    matches = world.query(*substituted_patterns)

    # Apply the aggregate function
    op = agg.op

    if op == 'count':
        return len(matches)

    elif op == 'sum':
        if agg.var is None:
            raise ValueError("sum requires a variable to aggregate")
        total = 0
        for match in matches:
            val = match.get(agg.var.name)
            if val is not None and isinstance(val, (int, float)):
                total += val
        return total

    elif op == 'max':
        if agg.var is None:
            raise ValueError("max requires a variable to aggregate")
        values = []
        for match in matches:
            val = match.get(agg.var.name)
            if val is not None and isinstance(val, (int, float)):
                values.append(val)
        return max(values) if values else 0

    elif op == 'min':
        if agg.var is None:
            raise ValueError("min requires a variable to aggregate")
        values = []
        for match in matches:
            val = match.get(agg.var.name)
            if val is not None and isinstance(val, (int, float)):
                values.append(val)
        return min(values) if values else 0

    else:
        raise ValueError(f"Unknown aggregate operator: {op}")


def evaluate_not_exists_expr(nexpr: 'NotExistsExpr', bindings: dict[str, Any], world: 'World') -> bool:
    """
    Evaluate a not-exists expression by checking for absence of matching facts.

    Returns True if NO alive fact matches the patterns after variable substitution.
    Returns False if ANY alive fact matches.

    Bound variables are substituted; unbound variables remain as wildcards.
    This allows patterns like (not-exists ?n has_quest ?any) to mean
    "?n has no quest at all" when ?any is unbound.

    Spec reference: §11.3
    """
    # Substitute bound variables into patterns; leave unbound as Var (wildcard)
    def substitute_pattern(pattern):
        def sub(val):
            if isinstance(val, Var):
                if val.name in bindings:
                    return bindings[val.name]
                # Unbound variable stays as Var (acts as wildcard in query)
                return val
            return val
        return (sub(pattern[0]), sub(pattern[1]), sub(pattern[2]))

    substituted_patterns = [substitute_pattern(p) for p in nexpr.patterns]

    # Query the world with the patterns (may contain Var wildcards)
    matches = world.query(*substituted_patterns)

    # not-exists succeeds if there are NO matches
    return len(matches) == 0


def contains_aggregate(value: Any) -> bool:
    """Check if a value contains any aggregate expressions."""
    if isinstance(value, AggregateExpr):
        return True
    elif isinstance(value, Expr):
        return any(contains_aggregate(arg) for arg in value.args)
    return False


def contains_negation(value: Any) -> bool:
    """Check if a value contains any not-exists expressions."""
    if isinstance(value, NotExistsExpr):
        return True
    elif isinstance(value, Expr):
        return any(contains_negation(arg) for arg in value.args)
    return False


# =============================================================================
# CORE: THE FACT
# =============================================================================

@dataclass(frozen=True)
class FactID:
    """Unique identifier for a fact instance."""
    id: int

    def __repr__(self):
        return f"#F{self.id}"


@dataclass
class Fact:
    """
    A temporal fact with provenance.

    Unlike flat triples, a Fact knows:
    - WHEN it became true (from_tick)
    - WHEN it stopped being true (to_tick, None = still true)
    - WHY it's true (cause: another FactID, a rule name, or "asserted")
    - WHAT depended on it (derived_facts)
    - WHICH micro-iteration it was created in (for deferred rule ordering)
    """
    id: FactID
    subject: Any
    relation: Any
    object: Any
    from_tick: int
    to_tick: Optional[int] = None  # None = still true
    cause: Optional[str] = "asserted"  # What created this fact
    cause_facts: tuple = ()  # Facts this was derived from
    micro_iter: int = 0  # Which micro-iteration within the tick (for deferred rules)

    def is_alive(self, tick: int) -> bool:
        """Is this fact true at the given tick?"""
        return self.from_tick <= tick and (self.to_tick is None or tick < self.to_tick)

    def __repr__(self):
        status = f"[{self.from_tick}-{self.to_tick or '?'}]"
        micro = f"@{self.micro_iter}" if self.micro_iter > 0 else ""
        return f"{self.id}: ({self.subject} {self.relation} {self.object}) {status}{micro}"


# =============================================================================
# VARIABLES FOR PATTERN MATCHING
# =============================================================================

@dataclass(frozen=True)
class Var:
    """A pattern variable. Matches anything and binds to it."""
    name: str
    def __repr__(self):
        return f"?{self.name}"

def var(name: str) -> Var:
    return Var(name)

# Predefined variables for convenience
X, Y, Z = var('x'), var('y'), var('z')
A, B, C = var('a'), var('b'), var('c')
S, R, O = var('s'), var('r'), var('o')  # Subject, Relation, Object


# =============================================================================
# THE WORLD: TEMPORAL FACT STORE WITH PROVENANCE
# =============================================================================

class World:
    """
    The HERB world. All facts exist here, with their full temporal history.

    This is not a database you query. It's a universe that remembers everything
    that ever happened and knows why.

    Worlds can be nested in a Verse for isolation:
    - Child Worlds inherit parent facts (read-only)
    - Child Worlds export selected facts to parent
    - Messages pass through inbox/SEND mechanism
    """

    def __init__(self, name: str = "root", verse: 'Verse' = None,
                 parent: 'World' = None):
        self.name: str = name
        self.verse: 'Verse' = verse
        self.parent: 'World' = parent

        self.tick: int = 0
        self._next_fact_id: int = 0

        # All facts ever created (including retracted ones)
        self._all_facts: dict[FactID, Fact] = {}

        # Primary indices for fast lookup (only point to currently-alive facts)
        self._by_subject: dict[Any, set[FactID]] = defaultdict(set)
        self._by_relation: dict[Any, set[FactID]] = defaultdict(set)
        self._by_object: dict[Any, set[FactID]] = defaultdict(set)

        # Compound indices for multi-key lookup (critical for performance)
        # These enable O(1) lookup instead of O(N) filter
        self._by_sr: dict[tuple, set[FactID]] = defaultdict(set)  # (subject, relation) -> facts
        self._by_ro: dict[tuple, set[FactID]] = defaultdict(set)  # (relation, object) -> facts
        self._by_sro: dict[tuple, set[FactID]] = defaultdict(set) # (subject, relation, object) -> facts

        # Functional relations: single-valued, auto-retract on update
        self._functional_relations: set[Any] = set()

        # Ephemeral relations: consumed after first match
        self._ephemeral_relations: set[Any] = set()

        # Rules (stored as facts, but also indexed separately for efficiency)
        self._derivation_rules: list['DerivationRule'] = []
        self._reaction_rules: list['ReactionRule'] = []

        # Change tracking for reactive rules
        self._changes_this_tick: list[tuple[str, Fact]] = []  # ('added', fact) or ('retracted', fact)

        # Deferred rules: micro-iteration support
        # Deferred rules queue their effects for the next micro-iteration
        self._deferred_queue: list[tuple] = []  # (subject, relation, object, cause, cause_facts, is_retraction)
        self._deferred_pending: set[tuple] = set()  # Track (subj, rel, obj, is_retraction) already queued
        self._micro_iteration: int = 0  # Current micro-iteration within tick

        # Once-per-tick tracking: prevents rules from firing multiple times per tick
        # Key: (rule_name, binding_key_tuple)
        self._fired_this_tick: set[tuple] = set()

        # Multi-World: exports and inbox
        self._exports: set[Any] = set()  # Relations visible to parent
        self._internals: set[Any] = set()  # Relations explicitly hidden (for documentation)
        self._inbox: list[tuple] = []  # Messages received from parent

        # Sync tick with parent if nested
        if self.parent is not None:
            self.tick = self.parent.tick

    def _make_fact_id(self) -> FactID:
        fid = FactID(self._next_fact_id)
        self._next_fact_id += 1
        return fid

    # =========================================================================
    # FUNCTIONAL RELATIONS
    # =========================================================================

    def declare_functional(self, relation: Any):
        """
        Declare a relation as functional (single-valued).

        Functional relations can have at most one object per subject.
        When asserting a new value, any existing value is automatically retracted.

        Example:
            world.declare_functional("hp")
            world.assert_fact("hero", "hp", 100)
            world.assert_fact("hero", "hp", 80)  # Auto-retracts (hero hp 100)

        This eliminates RETRACT boilerplate for relations like hp, location, gold.
        """
        self._functional_relations.add(relation)
        # Also record as a fact (everything is a fact)
        self.assert_fact(relation, "is_a", "functional_relation")

    def is_functional(self, relation: Any) -> bool:
        """Check if a relation has been declared as functional."""
        return relation in self._functional_relations

    # =========================================================================
    # EPHEMERAL RELATIONS
    # =========================================================================

    def declare_ephemeral(self, relation: Any):
        """
        Declare a relation as ephemeral (consumed after first match).

        Ephemeral facts are automatically retracted when a rule successfully
        matches them. This is for events/commands that should be processed
        exactly once, not persistent state.

        Example:
            world.declare_ephemeral("command")
            world.assert_fact("input", "command", "north")
            # First rule that matches (input command ?dir) consumes it
            # The fact is gone after that rule fires

        This is different from FUNCTIONAL:
        - FUNCTIONAL: single value per subject (hp can only be one number)
        - EPHEMERAL: single use per fact (command processed exactly once)
        """
        self._ephemeral_relations.add(relation)
        self.assert_fact(relation, "is_a", "ephemeral_relation")

    def is_ephemeral(self, relation: Any) -> bool:
        """Check if a relation has been declared as ephemeral."""
        return relation in self._ephemeral_relations

    # =========================================================================
    # MULTI-WORLD: EXPORTS AND INHERITANCE
    # =========================================================================

    def declare_export(self, relation: Any):
        """
        Declare a relation as exported (visible to parent World).

        Exported facts are the only facts from this World that the parent can see.
        This enables isolation: child's internal state is hidden unless explicitly exported.

        Example:
            world.declare_export("position")  # Parent can see where we are
            world.declare_export("state")     # Parent can see our status
            # But internal hp, mana, inventory remain hidden
        """
        self._exports.add(relation)
        self.assert_fact(relation, "is_a", "exported_relation")

    def declare_internal(self, relation: Any):
        """
        Declare a relation as internal (never visible to parent).

        This is documentation/enforcement only — unexported relations are already
        hidden. Use this to make the privacy boundary explicit in code.
        """
        self._internals.add(relation)
        self.assert_fact(relation, "is_a", "internal_relation")

    def is_exported(self, relation: Any) -> bool:
        """Check if a relation is exported to parent."""
        return relation in self._exports

    def get_exported_facts(self) -> list[Fact]:
        """
        Get all currently-alive facts that are exported.

        Used by parent World to see this child's visible state.
        """
        return [
            f for f in self._all_facts.values()
            if f.is_alive(self.tick) and f.relation in self._exports
        ]

    def receive_message(self, subject: Any, relation: Any, obj: Any,
                        from_world: str = None):
        """
        Receive a message into the inbox.

        Messages appear as facts in the inbox that rules can pattern-match on.
        They have provenance indicating where they came from.
        """
        self._inbox.append((subject, relation, obj, from_world))
        # Assert as a fact with boundary provenance
        cause = f"received_from:{from_world}" if from_world else "received"
        self.assert_fact(subject, relation, obj, cause=cause)

    def get_children(self) -> list['World']:
        """Get all child Worlds of this World."""
        if self.verse is None:
            return []
        return [w for w in self.verse.worlds.values() if w.parent is self]

    # =========================================================================
    # ASSERTION AND RETRACTION
    # =========================================================================

    def assert_fact(self, subject: Any, relation: Any, obj: Any,
                    cause: str = "asserted", cause_facts: tuple = (),
                    micro_iter: int = None) -> FactID:
        """
        Assert a new fact into the world.

        Returns the FactID. If an identical fact is already alive, returns its ID
        without creating a duplicate.

        For functional relations, any existing fact with the same (subject, relation)
        is automatically retracted before asserting the new one.

        micro_iter: Which micro-iteration this fact was created in (for deferred rules).
                    If None, uses the current _micro_iteration.
        """
        # Check if this fact is already alive (use exact triple index for O(1) lookup)
        for fid in self._by_sro.get((subject, relation, obj), set()):
            f = self._all_facts[fid]
            if f.is_alive(self.tick):
                return fid  # Already exists

        # For functional relations, auto-retract any existing value
        if relation in self._functional_relations:
            existing = list(self._by_sr.get((subject, relation), set()))
            for fid in existing:
                f = self._all_facts[fid]
                if f.is_alive(self.tick) and f.object != obj:
                    self.retract_fact(subject, relation, f.object)

        # Create new fact
        fid = self._make_fact_id()
        fact = Fact(
            id=fid,
            subject=subject,
            relation=relation,
            object=obj,
            from_tick=self.tick,
            cause=cause,
            cause_facts=cause_facts,
            micro_iter=micro_iter if micro_iter is not None else self._micro_iteration
        )

        self._all_facts[fid] = fact
        self._by_subject[subject].add(fid)
        self._by_relation[relation].add(fid)
        self._by_object[obj].add(fid)

        # Maintain compound indices
        self._by_sr[(subject, relation)].add(fid)
        self._by_ro[(relation, obj)].add(fid)
        self._by_sro[(subject, relation, obj)].add(fid)

        self._changes_this_tick.append(('added', fact))

        return fid

    def retract_fact(self, subject: Any, relation: Any, obj: Any) -> bool:
        """
        Retract a fact (mark it as no longer true as of this tick).

        The fact isn't deleted — its history is preserved. It just gets an end time.
        """
        for fid in list(self._by_subject.get(subject, set())):
            f = self._all_facts[fid]
            if f.relation == relation and f.object == obj and f.is_alive(self.tick):
                # Mark as retracted
                # We need to create a new Fact object since Fact is mostly immutable
                # Actually, let's make to_tick mutable for this purpose
                f.to_tick = self.tick

                # Remove from live indices
                self._by_subject[subject].discard(fid)
                self._by_relation[relation].discard(fid)
                self._by_object[obj].discard(fid)

                # Remove from compound indices
                self._by_sr[(subject, relation)].discard(fid)
                self._by_ro[(relation, obj)].discard(fid)
                self._by_sro[(subject, relation, obj)].discard(fid)

                self._changes_this_tick.append(('retracted', f))
                return True

        return False

    def update_fact(self, subject: Any, relation: Any, old_obj: Any, new_obj: Any,
                    cause: str = "updated") -> FactID:
        """
        Update a fact's object value. This retracts the old and asserts the new,
        preserving the causal chain.
        """
        # Find the old fact to get its provenance
        old_fact = None
        for fid in self._by_subject.get(subject, set()):
            f = self._all_facts[fid]
            if f.relation == relation and f.object == old_obj and f.is_alive(self.tick):
                old_fact = f
                break

        self.retract_fact(subject, relation, old_obj)

        cause_facts = (old_fact.id,) if old_fact else ()
        return self.assert_fact(subject, relation, new_obj, cause=cause, cause_facts=cause_facts)

    # =========================================================================
    # QUERYING
    # =========================================================================

    def query(self, *patterns, at_tick: Optional[int] = None,
              include_inherited: bool = True) -> list[dict[str, Any]]:
        """
        Query for facts matching patterns.

        Each pattern is (subject, relation, object) where any element can be a Var.
        Returns all variable bindings that satisfy ALL patterns.

        By default queries current tick. Pass at_tick to query historical state.

        Multi-World inheritance:
        - If include_inherited=True (default) and this World has a parent,
          the query also searches the parent's facts.
        - Inherited facts are read-only (child cannot retract parent facts).
        - This enables shared visible state (terrain, physics constants).
        """
        if at_tick is None:
            at_tick = self.tick

        if not patterns:
            return [{}]

        results = []
        self._query_recursive(patterns, {}, at_tick, results, include_inherited)
        return results

    def _query_recursive(self, patterns: tuple, bindings: dict, tick: int,
                         results: list, include_inherited: bool = True):
        """Recursive conjunctive query with backtracking."""
        if not patterns:
            results.append(bindings.copy())
            return

        pattern, *rest = patterns
        p_subj, p_rel, p_obj = pattern

        # Resolve any bound variables in the pattern
        if isinstance(p_subj, Var) and p_subj.name in bindings:
            p_subj = bindings[p_subj.name]
        if isinstance(p_rel, Var) and p_rel.name in bindings:
            p_rel = bindings[p_rel.name]
        if isinstance(p_obj, Var) and p_obj.name in bindings:
            p_obj = bindings[p_obj.name]

        # Find candidate facts using indices (local facts)
        candidates = self._get_candidates(p_subj, p_rel, p_obj, tick)

        for fact in candidates:
            new_bindings = self._match_pattern((p_subj, p_rel, p_obj), fact, bindings)
            if new_bindings is not None:
                self._query_recursive(tuple(rest), new_bindings, tick, results,
                                     include_inherited)

        # Also search parent's facts if inheritance enabled
        if include_inherited and self.parent is not None:
            parent_candidates = self.parent._get_candidates(
                p_subj, p_rel, p_obj, tick
            )
            for fact in parent_candidates:
                new_bindings = self._match_pattern((p_subj, p_rel, p_obj), fact, bindings)
                if new_bindings is not None:
                    self._query_recursive(tuple(rest), new_bindings, tick, results,
                                         include_inherited)

    def _get_candidates(self, subj, rel, obj, tick: int) -> Iterator[Fact]:
        """
        Get candidate facts for a pattern, using the most selective index.

        Index selection priority (most selective first):
        1. (subject, relation, object) - exact match, returns 0 or 1 fact
        2. (subject, relation) - when subject and relation are bound
        3. (relation, object) - when relation and object are bound (e.g., is_a combatant)
        4. (subject) - when only subject is bound
        5. (relation) - when only relation is bound
        6. (object) - when only object is bound
        7. Full scan - only when all are variables
        """
        subj_bound = not isinstance(subj, Var)
        rel_bound = not isinstance(rel, Var)
        obj_bound = not isinstance(obj, Var)

        # For current tick, use live indices
        if tick == self.tick:
            # Choose the most selective index based on what's bound
            if subj_bound and rel_bound and obj_bound:
                # Exact triple lookup
                fids = self._by_sro.get((subj, rel, obj), set())
            elif subj_bound and rel_bound:
                # (subject, relation) compound index
                fids = self._by_sr.get((subj, rel), set())
            elif rel_bound and obj_bound:
                # (relation, object) compound index - the big win for "is_a combatant"
                fids = self._by_ro.get((rel, obj), set())
            elif subj_bound:
                fids = self._by_subject.get(subj, set())
            elif rel_bound:
                fids = self._by_relation.get(rel, set())
            elif obj_bound:
                fids = self._by_object.get(obj, set())
            else:
                # All variables - need to scan everything alive
                fids = set()
                for s in self._by_subject.values():
                    fids.update(s)

            for fid in fids:
                yield self._all_facts[fid]
        else:
            # Historical query - scan all facts
            for fact in self._all_facts.values():
                if fact.is_alive(tick):
                    yield fact

    def _match_pattern(self, pattern: tuple, fact: Fact, bindings: dict) -> Optional[dict]:
        """Try to match a pattern against a fact, returning extended bindings or None."""
        p_subj, p_rel, p_obj = pattern

        new_bindings = bindings.copy()

        for pattern_elem, fact_elem in [(p_subj, fact.subject),
                                         (p_rel, fact.relation),
                                         (p_obj, fact.object)]:
            if isinstance(pattern_elem, Var):
                name = pattern_elem.name
                if name in new_bindings:
                    if new_bindings[name] != fact_elem:
                        return None
                else:
                    new_bindings[name] = fact_elem
            else:
                if pattern_elem != fact_elem:
                    return None

        return new_bindings

    # =========================================================================
    # PROVENANCE: WHY IS THIS TRUE?
    # =========================================================================

    def explain(self, subject: Any, relation: Any, obj: Any) -> Optional[dict]:
        """
        Explain why a fact is true: what caused it, and what that depended on.

        Returns a provenance tree, or None if the fact doesn't exist.
        """
        # Find the fact
        for fid in self._by_subject.get(subject, set()):
            f = self._all_facts[fid]
            if f.relation == relation and f.object == obj and f.is_alive(self.tick):
                return self._build_explanation(f)
        return None

    def _build_explanation(self, fact: Fact, depth: int = 0) -> dict:
        """Build a provenance tree for a fact."""
        explanation = {
            'fact': f"({fact.subject} {fact.relation} {fact.object})",
            'from_tick': fact.from_tick,
            'micro_iter': fact.micro_iter,
            'cause': fact.cause,
            'depends_on': []
        }

        if depth < 10:  # Prevent infinite recursion
            for cause_fid in fact.cause_facts:
                cause_fact = self._all_facts.get(cause_fid)
                if cause_fact:
                    explanation['depends_on'].append(
                        self._build_explanation(cause_fact, depth + 1)
                    )

        return explanation

    def history(self, subject: Any, relation: Any) -> list[Fact]:
        """
        Get the complete history of a (subject, relation) pair.

        Returns all facts ever true for this pair, in chronological order.
        """
        results = []
        for fact in self._all_facts.values():
            if fact.subject == subject and fact.relation == relation:
                results.append(fact)
        return sorted(results, key=lambda f: f.from_tick)

    # =========================================================================
    # RULES
    # =========================================================================

    def add_derivation_rule(self, name: str, patterns: list[tuple],
                            template: tuple = None, retractions: list[tuple] = None,
                            guard: 'Expr' = None, templates: list[tuple] = None,
                            deferred: bool = False, once_per_tick: bool = False,
                            once_key_vars: list[str] = None):
        """
        Add a rule that derives new facts from existing ones.

        When patterns match:
        1. Guard is evaluated (if present) - skip binding if false
        2. All templates are instantiated and asserted
        3. Retractions are instantiated and retracted

        The derived fact knows it came from this rule and which facts matched.

        Example with retraction (apply damage):
            patterns: [(X, "hp", HP), (X, "pending_damage", DMG)]
            template: (X, "hp", Expr('-', [HP, DMG]))
            retractions: [(X, "hp", HP), (X, "pending_damage", DMG)]

        Example with multiple templates:
            patterns: [(X, "wants_to_buy", ITEM)]
            templates: [(X, "purchased", ITEM), (X, "gold", Expr('-', [GOLD, PRICE]))]

        Example with guard (only apply if alive):
            patterns: [(X, "hp", HP), (X, "pending_damage", DMG)]
            template: (X, "hp", Expr('-', [HP, DMG]))
            guard: Expr('>', [HP, 0])
            retractions: [(X, "hp", HP), (X, "pending_damage", DMG)]

        Aggregate rules (containing sum/count/max/min with WHERE in template)
        cannot have retractions and run in Phase 2 after base rules reach fixpoint.

        Deferred rules (deferred=True):
            - Effects are queued for the next micro-iteration, not applied immediately
            - Creates causal ordering within a tick without marker facts
            - Use for combat chains: damage -> hp update -> death check -> loot drop

        Spec reference: §5.1, §5.2, §5.4, §10, §14 (deferred rules)
        """
        # Accept either single template or list of templates for backward compatibility
        if templates is not None:
            template_list = templates
        elif template is not None:
            template_list = [template]
        else:
            raise ValueError("Either 'template' or 'templates' must be provided")

        rule = DerivationRule(name, patterns, template_list, retractions or [], guard, deferred,
                              once_per_tick, once_key_vars)

        # Validate the rule (spec §5.4 - aggregate rules can't have retractions)
        errors = rule.validate()
        if errors:
            raise ValueError("\n".join(errors))

        self._derivation_rules.append(rule)

        # Also store the rule as a fact (rules are facts!)
        self.assert_fact(name, "is_a", "derivation_rule")
        self.assert_fact(name, "pattern_count", len(patterns))
        if rule.is_aggregate():
            self.assert_fact(name, "is_aggregate", True)
        if rule.has_negation():
            self.assert_fact(name, "has_negation", True)
        if rule.is_phase2():
            self.assert_fact(name, "is_phase2", True)
        if rule.deferred:
            self.assert_fact(name, "is_deferred", True)
        if retractions:
            self.assert_fact(name, "retraction_count", len(retractions))
        if guard is not None:
            self.assert_fact(name, "has_guard", True)

    def add_reaction_rule(self, name: str, trigger: str, patterns: list[tuple],
                          action: Callable[['World', dict], None]):
        """
        Add a rule that executes an action when patterns match after a change.

        trigger: 'on_add' or 'on_retract'
        patterns: must match for the action to fire
        action: function(world, bindings) to execute
        """
        rule = ReactionRule(name, trigger, patterns, action)
        self._reaction_rules.append(rule)

        self.assert_fact(name, "is_a", "reaction_rule")
        self.assert_fact(name, "trigger", trigger)

    # =========================================================================
    # TIME
    # =========================================================================

    def _stratify_rules(self) -> list[list['DerivationRule']]:
        """
        Compute N-phase stratification for derivation rules.

        Returns list of strata, where strata[i] contains rules for stratum i.
        Strata are ordered: stratum 0 runs first, then 1, then 2, etc.

        Datalog-style stratification algorithm:
        1. Build dependency graph: relations → (depends_on, negatively_depends_on)
        2. Identify "aggregate-produced" relations (need to stabilize before consumers)
        3. Compute stratum for each relation:
           - Positive dep: stratum(B) >= stratum(A) if rule patterns on A, produces B
           - Negative dep: stratum(B) > stratum(A) if rule aggregates/negates over A
           - Aggregate-produced dep: stratum(B) > stratum(A) if A is aggregate-produced
        4. Assign each rule to the stratum of its output relation
        5. Check for negative cycles (would be unsatisfiable)

        This generalizes the old fixed Phase 1/2/3 to handle arbitrary depth.
        Aggregate over Phase 3? That's stratum 4. RETRACT on stratum 4? Stratum 5.

        Spec reference: §6.1
        """
        if not self._derivation_rules:
            return []

        # Step 0: Identify "base relations" - FUNCTIONAL relations with asserted facts
        # Reading a base FUNCTIONAL relation doesn't create a dependency on rules that
        # produce derived values for it, because:
        # 1. The reader gets the current (base) value
        # 2. Writers update for future readers
        # 3. There's no "complete all writes before read" requirement
        # This prevents false cycles like: read tax_rate -> vote -> count -> pass -> write tax_rate
        base_functional_relations: set = set()
        for fid, fact in self._all_facts.items():
            if fact.cause == "asserted" and fact.relation in self._functional_relations:
                base_functional_relations.add(fact.relation)

        # Step 1: Collect all relations and build dependency graph
        # relation_deps[rel] = (positive_deps, negative_deps)
        # positive_deps: relations this one depends on (patterns on)
        # negative_deps: relations this one negatively depends on (aggregates/negates over)
        relation_deps: dict[Any, tuple[set, set]] = defaultdict(lambda: (set(), set()))

        # Track which relations are produced by aggregate/negation rules
        aggregate_produced_relations: set = set()

        # Also track which rules produce which relations
        rules_by_output: dict[Any, list['DerivationRule']] = defaultdict(list)

        for rule in self._derivation_rules:
            # Identify "transform" relations: produced AND retracted by this rule.
            # These represent value transformations (status:voting -> status:decided)
            # rather than new data production.
            rule_retracted_rels = set()
            if rule.retractions:
                for retraction in rule.retractions:
                    ret_rel = retraction[1]
                    if not isinstance(ret_rel, Var):
                        rule_retracted_rels.add(ret_rel)

            # What relations does this rule produce? (can be multiple)
            out_rels = set()
            for template in rule.templates:
                out_rel = template[1]
                if not isinstance(out_rel, Var):
                    # For transform relations, we track them for internal
                    # stratum computation but don't add to rules_by_output.
                    # This prevents cycles: other rules that pattern on this
                    # relation depend on the EARLIER producer, not this transformer.
                    is_transform = out_rel in rule_retracted_rels
                    out_rels.add(out_rel)
                    if not is_transform:
                        rules_by_output[out_rel].append(rule)
                    # Track if this relation is produced by an aggregate/negation rule
                    if rule.is_phase2():
                        aggregate_produced_relations.add(out_rel)

            # What relations does this rule pattern on?
            # Exclude:
            # 1. Base FUNCTIONAL relations - reading them doesn't create
            #    a dependency on rules that write derived values
            # 2. "Transform" relations: where the rule PATTERNS on X, PRODUCES X,
            #    and RETRACTS X. This is a value transformation (e.g., status:proposed
            #    -> status:voting) not a dependency. Only applies when the rule
            #    produces the SAME relation it retracts.
            transform_rels = set()
            if rule.retractions:
                for retraction in rule.retractions:
                    ret_rel = retraction[1]
                    if not isinstance(ret_rel, Var):
                        # Check if this rule also PRODUCES the same relation
                        for template in rule.templates:
                            if template[1] == ret_rel:
                                # This is a transform: patterns X, produces X, retracts X
                                transform_rels.add(ret_rel)
                                break

            pattern_rels = set()
            for pattern in rule.patterns:
                rel = pattern[1]
                if not isinstance(rel, Var):
                    if rel not in base_functional_relations and rel not in transform_rels:
                        pattern_rels.add(rel)

            # What relations does this rule aggregate/negate over?
            agg_rels = set()
            if rule.is_aggregate():
                # Find relations in aggregate WHERE clauses (check all templates)
                for template in rule.templates:
                    agg_rels.update(self._extract_aggregate_relations(template))
            if rule.has_negation() and rule.guard:
                # Find relations in not-exists patterns
                agg_rels.update(self._extract_negation_relations(rule.guard))

            # Build dependencies for each output relation
            for out_rel in out_rels:
                # Skip building dependencies for transform relations.
                # Transform = rule patterns on X, produces X, retracts X.
                # The transformed output doesn't create new dependencies;
                # other rules depending on X depend on EARLIER producers.
                if out_rel in transform_rels:
                    continue

                pos_deps, neg_deps = relation_deps[out_rel]
                # Positive dependencies: all pattern relations
                pos_deps.update(pattern_rels)
                # Negative dependencies: relations we aggregate/negate over
                neg_deps.update(agg_rels)

        # Step 2: Compute stratum for each relation
        # Start all at 0, then iterate until stable
        relation_stratum: dict[Any, int] = defaultdict(int)
        all_relations = set(relation_deps.keys())

        # Also include relations that are only read, not produced
        for pos_deps, neg_deps in relation_deps.values():
            all_relations.update(pos_deps)
            all_relations.update(neg_deps)

        # Iterate until strata stabilize
        max_iterations = len(all_relations) + 10  # Safety limit
        for _ in range(max_iterations):
            changed = False
            for rel in all_relations:
                if rel not in relation_deps:
                    continue  # Base relation (never produced by a rule)

                pos_deps, neg_deps = relation_deps[rel]
                current = relation_stratum[rel]

                # Positive constraint: stratum >= max(deps)
                # BUT if a dependency is aggregate-produced, we need stratum > it
                if pos_deps:
                    for dep in pos_deps:
                        dep_stratum = relation_stratum[dep]
                        if dep in aggregate_produced_relations:
                            # Consumer of aggregate-produced relation needs strictly greater stratum
                            required = dep_stratum + 1
                        else:
                            required = dep_stratum
                        if current < required:
                            relation_stratum[rel] = required
                            changed = True
                            current = required

                # Negative constraint: stratum > max(neg_deps)
                if neg_deps:
                    min_from_neg = max(relation_stratum[d] for d in neg_deps) + 1
                    if current < min_from_neg:
                        relation_stratum[rel] = min_from_neg
                        changed = True

            if not changed:
                break
        else:
            # Didn't converge - likely a negative cycle
            raise RuntimeError(
                "Stratification failed: possible negative cycle in rule dependencies. "
                "A relation cannot aggregate/negate over itself (directly or indirectly)."
            )

        # Step 3: Assign rules to strata
        # Rule goes to max of:
        # - Its output relations' strata
        # - Its input relations' strata (for proper sequencing when output is transform)
        # - Input strata + 1 if the input is aggregate-produced
        rule_strata: dict[str, int] = {}  # rule.name -> stratum
        max_stratum = 0

        for rule in self._derivation_rules:
            stratum = 0

            # Consider output relations
            for template in rule.templates:
                out_rel = template[1]
                if not isinstance(out_rel, Var):
                    stratum = max(stratum, relation_stratum[out_rel])

            # Also consider input relations (what the rule patterns on)
            # This is crucial for rules with transform outputs that would
            # otherwise be placed too early in the execution order.
            # Exclude base functional relations (they're read-current-value, not dependencies).
            for pattern in rule.patterns:
                rel = pattern[1]
                if not isinstance(rel, Var) and rel not in base_functional_relations:
                    input_stratum = relation_stratum[rel]
                    if rel in aggregate_produced_relations:
                        # Consumer of aggregate-produced needs to be strictly later
                        input_stratum += 1
                    stratum = max(stratum, input_stratum)

            rule_strata[rule.name] = stratum
            max_stratum = max(max_stratum, stratum)

        # Step 4: Build stratum lists
        strata: list[list['DerivationRule']] = [[] for _ in range(max_stratum + 1)]
        for rule in self._derivation_rules:
            strata[rule_strata[rule.name]].append(rule)

        # Store stratum info for diagnostics
        self._rule_strata = rule_strata
        self._relation_strata = dict(relation_stratum)

        return strata

    def _extract_aggregate_relations(self, template: tuple) -> set:
        """Extract relations from aggregate WHERE clauses in a template."""
        relations = set()

        def extract_from_value(val):
            if isinstance(val, AggregateExpr):
                for pattern in val.patterns:
                    rel = pattern[1]
                    if not isinstance(rel, Var):
                        relations.add(rel)
            elif isinstance(val, Expr):
                for arg in val.args:
                    extract_from_value(arg)

        for elem in template:
            extract_from_value(elem)

        return relations

    def _extract_negation_relations(self, guard: 'Expr') -> set:
        """Extract relations from not-exists patterns in a guard."""
        relations = set()

        def extract_from_expr(expr):
            if isinstance(expr, NotExistsExpr):
                for pattern in expr.patterns:
                    rel = pattern[1]
                    if not isinstance(rel, Var):
                        relations.add(rel)
            elif isinstance(expr, Expr):
                for arg in expr.args:
                    extract_from_expr(arg)

        extract_from_expr(guard)
        return relations

    def get_rule_stratum(self, rule_name: str) -> Optional[int]:
        """Get the stratum a rule was assigned to (for diagnostics)."""
        if not hasattr(self, '_rule_strata'):
            return None
        return self._rule_strata.get(rule_name)

    def get_relation_stratum(self, relation: Any) -> Optional[int]:
        """Get the stratum a relation is produced in (for diagnostics)."""
        if not hasattr(self, '_relation_strata'):
            return None
        return self._relation_strata.get(relation)

    def print_stratification(self):
        """
        Print detailed stratification information for diagnostics.

        Shows which stratum each rule is assigned to and why.
        Call after advance() or _stratify_rules() to see current classification.
        """
        if not hasattr(self, '_rule_strata'):
            print("Stratification not computed yet. Call advance() first.")
            return

        strata = self._stratify_rules()

        print("\n=== HERB Stratification Report ===")
        print(f"Total rules: {len(self._derivation_rules)}")
        print(f"Total strata: {len(strata)}")

        # Show rules by stratum
        for i, stratum_rules in enumerate(strata):
            if not stratum_rules:
                continue
            print(f"\n--- Stratum {i} ---")
            for rule in stratum_rules:
                # Gather rule info
                info = []
                if rule.is_aggregate():
                    info.append("aggregate")
                if rule.has_negation():
                    info.append("negation")
                if rule.retractions:
                    info.append(f"retracts:{len(rule.retractions)}")

                patterns_str = ", ".join(
                    str(p[1]) for p in rule.patterns
                    if not isinstance(p[1], Var)
                )
                # Show all output relations
                out_rels = []
                for template in rule.templates:
                    out_rel = template[1]
                    out_rels.append(str(out_rel) if not isinstance(out_rel, Var) else "?")
                out_str = ", ".join(out_rels)

                info_str = f" [{', '.join(info)}]" if info else ""
                print(f"  {rule.name}: patterns({patterns_str}) -> {out_str}{info_str}")

        # Show relation strata
        if self._relation_strata:
            print("\n--- Relation Strata ---")
            by_stratum = {}
            for rel, stratum in self._relation_strata.items():
                if stratum not in by_stratum:
                    by_stratum[stratum] = []
                by_stratum[stratum].append(rel)

            for stratum in sorted(by_stratum.keys()):
                rels = by_stratum[stratum]
                print(f"  Stratum {stratum}: {', '.join(str(r) for r in rels)}")

        print("=" * 35)

    def advance(self, max_iterations: int = 100, max_micro_iterations: int = 20):
        """
        Advance the world by one tick using N-phase stratified derivation
        with micro-iteration support for deferred rules.

        Spec reference: §6.1, §14 (deferred rules)

        A tick consists of multiple micro-iterations:
        1. Run all strata to fixpoint (micro-iteration 0)
        2. If deferred effects exist, apply them and increment micro-iteration
        3. Run all strata to fixpoint again
        4. Repeat until no deferred effects remain
        5. Run reaction rules, advance tick

        Stratification runs rules in order of their stratum:
        - Stratum 0: Base rules (no aggregate/negation dependencies)
        - Stratum 1+: Rules that depend on aggregate/negation outputs from prior strata

        Within each stratum, rules run to fixpoint before advancing to the next.
        This ensures aggregate/negation rules see stable input.

        Deferred rules create causal ordering within a tick:
        - attack => pending_damage (micro-iter 0)
        - pending_damage =>> hp update (micro-iter 1)
        - hp <= 0 =>> death (micro-iter 2)
        - death =>> loot drop (micro-iter 3)
        """
        # Reset micro-iteration counter for this tick
        self._micro_iteration = 0
        self._deferred_queue = []
        self._deferred_pending = set()  # Clear pending tracking
        self._fired_this_tick = set()  # Clear once-per-tick tracking

        # Compute N-phase stratification once (doesn't change during tick)
        strata = self._stratify_rules()

        # Outer loop: micro-iterations
        for micro_iter in range(max_micro_iterations):
            self._micro_iteration = micro_iter

            # Inner loop: run all strata to fixpoint
            for stratum_idx, stratum_rules in enumerate(strata):
                if not stratum_rules:
                    continue

                iterations = 0
                while iterations < max_iterations:
                    derived = 0
                    for rule in stratum_rules:
                        derived += rule.apply(self)
                    if derived == 0:
                        break
                    iterations += 1

                if iterations >= max_iterations:
                    raise RuntimeError(
                        f"Stratum {stratum_idx} derivation did not reach fixpoint after "
                        f"{max_iterations} iterations (micro-iter {micro_iter}). "
                        "Possible infinite loop in rules."
                    )

            # Check if there are deferred effects to apply
            if not self._deferred_queue:
                # No deferred effects - tick is complete
                break

            # Apply deferred effects for next micro-iteration
            # These become active facts that rules can pattern-match on
            next_micro = micro_iter + 1
            for item in self._deferred_queue:
                subj, rel, obj, cause, cause_facts, is_retraction = item
                if is_retraction:
                    self.retract_fact(subj, rel, obj)
                else:
                    self.assert_fact(subj, rel, obj, cause=cause,
                                    cause_facts=cause_facts, micro_iter=next_micro)

            self._deferred_queue = []
            self._deferred_pending = set()  # Clear for next micro-iteration

        else:
            # Hit max micro-iterations - likely an infinite deferred chain
            raise RuntimeError(
                f"Tick did not complete after {max_micro_iterations} micro-iterations. "
                "Possible infinite deferred rule chain."
            )

        # Reactions on changes
        for rule in self._reaction_rules:
            rule.apply(self, self._changes_this_tick)

        # Advance time
        self.tick += 1
        self._changes_this_tick = []
        self._micro_iteration = 0

    # =========================================================================
    # INSPECTION
    # =========================================================================

    def __len__(self):
        """Number of currently-alive facts."""
        return sum(1 for f in self._all_facts.values() if f.is_alive(self.tick))

    def all_facts(self, include_dead: bool = False) -> list[Fact]:
        """Get all facts (optionally including historical/retracted ones)."""
        if include_dead:
            return list(self._all_facts.values())
        return [f for f in self._all_facts.values() if f.is_alive(self.tick)]

    def print_state(self):
        """Print current world state."""
        print(f"\n=== World '{self.name}' at tick {self.tick} ({len(self)} facts alive) ===")
        for fact in sorted(self.all_facts(), key=lambda f: (f.subject, f.relation)):
            print(f"  {fact}")


# =============================================================================
# VERSE: MULTI-WORLD CONTAINER
# =============================================================================

class Verse:
    """
    A container for multiple Worlds with parent-child relationships.

    Verse manages the tree structure of Worlds and coordinates their ticks.
    This enables process isolation (OS) and player isolation (games).

    Key properties:
    - Worlds form a tree (parent-child)
    - Children inherit parent facts (read-only)
    - Children export selected facts to parent
    - Siblings cannot see each other (true isolation)
    - Messages pass via inbox/SEND mechanism
    """

    def __init__(self):
        self.worlds: dict[str, World] = {}
        self.root: World = None
        self._global_tick: int = 0

    def create_world(self, name: str, parent: str = None) -> World:
        """
        Create a new World, optionally as child of an existing parent.

        Args:
            name: Unique name for the World
            parent: Name of parent World (None for root)

        Returns:
            The newly created World

        Raises:
            ValueError: If name already exists or parent not found
        """
        if name in self.worlds:
            raise ValueError(f"World '{name}' already exists")

        parent_world = None
        if parent is not None:
            if parent not in self.worlds:
                raise ValueError(f"Parent world '{parent}' not found")
            parent_world = self.worlds[parent]

        world = World(name=name, verse=self, parent=parent_world)
        world.tick = self._global_tick
        self.worlds[name] = world

        if parent_world is None:
            if self.root is not None:
                raise ValueError("Verse already has a root World")
            self.root = world

        return world

    def get_world(self, name: str) -> World:
        """Get a World by name."""
        return self.worlds.get(name)

    def get_children(self, parent_name: str) -> list[World]:
        """Get all child Worlds of a given parent."""
        parent = self.worlds.get(parent_name)
        if parent is None:
            return []
        return [w for w in self.worlds.values() if w.parent is parent]

    def tick(self, max_iterations: int = 100):
        """
        Advance all Worlds by one tick.

        Order: root derives first, then children (can parallelize siblings).
        This ensures inherited facts are stable before children derive.

        After derivation:
        1. Root derives to fixpoint
        2. Children derive to fixpoint (stable inherited base)
        3. Exports collected (visible on next tick)
        4. Global tick increments
        """
        if self.root is None:
            return

        # Phase 1: Root derives to fixpoint
        self.root.advance(max_iterations)

        # Phase 2: Children derive (order doesn't matter, siblings isolated)
        def derive_children(parent: World):
            for child in self.get_children(parent.name):
                # Sync child tick with global
                child.tick = self._global_tick
                child.advance(max_iterations)
                # Recurse to grandchildren
                derive_children(child)

        derive_children(self.root)

        # Advance global tick
        self._global_tick += 1

    def send_message(self, from_world: str, to_world: str,
                     subject: Any, relation: Any, obj: Any):
        """
        Send a message from one World to another.

        Messages are delivered to the target's inbox as facts.
        Only parent-to-child or child-to-parent messaging is allowed
        (siblings cannot message directly — must go through parent).

        Args:
            from_world: Name of sending World
            to_world: Name of receiving World
            subject, relation, obj: The message content (as a triple)

        Raises:
            ValueError: If worlds don't have parent-child relationship
        """
        sender = self.worlds.get(from_world)
        receiver = self.worlds.get(to_world)

        if sender is None or receiver is None:
            raise ValueError(f"World not found")

        # Validate relationship: must be parent-child or child-parent
        if sender.parent is not receiver and receiver.parent is not sender:
            raise ValueError(
                f"Cannot send message between '{from_world}' and '{to_world}': "
                "not parent-child relationship. Use parent as intermediary."
            )

        receiver.receive_message(subject, relation, obj, from_world=from_world)

    def query_child_exports(self, parent_name: str, child_name: str,
                           *patterns) -> list[dict[str, Any]]:
        """
        Query exported facts from a child World.

        Only exported facts are visible. Internal facts remain hidden.
        Results have provenance indicating they came from the child.
        """
        parent = self.worlds.get(parent_name)
        child = self.worlds.get(child_name)

        if parent is None or child is None:
            return []

        if child.parent is not parent:
            raise ValueError(f"'{child_name}' is not a child of '{parent_name}'")

        # Get exported facts
        exported = child.get_exported_facts()

        # Filter by patterns
        results = []
        for fact in exported:
            for pattern in patterns:
                p_subj, p_rel, p_obj = pattern
                bindings = {}

                # Try to match
                matched = True
                for pattern_elem, fact_elem in [(p_subj, fact.subject),
                                                 (p_rel, fact.relation),
                                                 (p_obj, fact.object)]:
                    if isinstance(pattern_elem, Var):
                        name = pattern_elem.name
                        if name in bindings:
                            if bindings[name] != fact_elem:
                                matched = False
                                break
                        else:
                            bindings[name] = fact_elem
                    else:
                        if pattern_elem != fact_elem:
                            matched = False
                            break

                if matched:
                    results.append(bindings)

        return results

    def print_tree(self):
        """Print the World tree structure."""
        def print_world(world: World, indent: int = 0):
            prefix = "  " * indent
            export_str = f" [exports: {', '.join(str(r) for r in world._exports)}]" if world._exports else ""
            print(f"{prefix}- {world.name} ({len(world)} facts){export_str}")
            for child in self.get_children(world.name):
                print_world(child, indent + 1)

        print(f"\n=== Verse (tick {self._global_tick}) ===")
        if self.root:
            print_world(self.root)
        else:
            print("  (empty)")


# =============================================================================
# RULES
# =============================================================================

@dataclass
class DerivationRule:
    """
    A rule that derives new facts when patterns match.

    Can both assert new facts (templates) and retract existing ones (retractions).
    Retractions happen after all assertions for a given binding.

    Rules are classified as "aggregate" if any template contains any aggregate
    expression (sum, count, max, min with WHERE). Aggregate rules:
    - Run only in Phase 2 after base rules reach fixpoint
    - Cannot have retractions (static error)
    - See a stable set of facts to aggregate over

    Rules are classified as "negation" if their guard contains any not-exists
    expression. Negation rules also run in Phase 2.

    Guards (§10) are optional boolean expressions that filter bindings after
    pattern matching. Only bindings where the guard evaluates to true proceed.

    Deferred rules (deferred=True):
    - Effects are queued for the next micro-iteration instead of applying immediately
    - This creates causal ordering within a tick: damage -> hp -> death -> loot
    - The ordering is visible in provenance (micro_iter field on facts)
    - Deferred rules CAN have retractions (they're properly sequenced)

    Once-per-tick rules (once_per_tick=True):
    - Each unique binding fires at most once per tick
    - Engine tracks (rule, binding_key) pairs that have fired
    - Prevents infinite loops from actions that re-enable their preconditions
    - Essential for multi-agent simulation where each agent acts once per turn

    Spec reference: §5.1, §5.2, §5.4, §6.1, §6.3, §10, §11, §14 (deferred), §15 (once-per-tick)
    """
    name: str
    patterns: list[tuple]
    templates: list[tuple]  # List of (subject, relation, object) - can contain Vars and Exprs
    retractions: list[tuple] = field(default_factory=list)  # Facts to retract when rule fires
    guard: Optional[Expr] = None  # Optional guard condition (must evaluate to boolean)
    deferred: bool = False  # If True, effects queue for next micro-iteration
    once_per_tick: bool = False  # If True, each binding fires at most once per tick
    once_key_vars: list[str] = None  # Variables to include in binding key (None = all pattern vars)
    _is_aggregate: bool = field(default=None, init=False)  # Cached aggregate check
    _has_negation: bool = field(default=None, init=False)  # Cached negation check

    def is_aggregate(self) -> bool:
        """Check if this rule contains aggregate expressions in any template."""
        if self._is_aggregate is None:
            self._is_aggregate = any(
                contains_aggregate(template[i])
                for template in self.templates
                for i in range(3)
            )
        return self._is_aggregate

    def has_negation(self) -> bool:
        """Check if this rule contains not-exists expressions in its guard."""
        if self._has_negation is None:
            self._has_negation = (
                self.guard is not None and contains_negation(self.guard)
            )
        return self._has_negation

    def is_phase2(self) -> bool:
        """Check if this rule should run in Phase 2 (aggregate or negation)."""
        return self.is_aggregate() or self.has_negation()

    def validate(self) -> list[str]:
        """
        Validate the rule, returning a list of errors (empty if valid).

        Spec reference: §5.4, §11.5 - aggregate/negation rules cannot have retractions
        """
        errors = []
        if self.is_aggregate() and self.retractions:
            errors.append(
                f"Rule '{self.name}': Aggregate rules cannot have RETRACT clauses. "
                "Aggregates run in Phase 2 and must be side-effect free."
            )
        if self.has_negation() and self.retractions:
            errors.append(
                f"Rule '{self.name}': Rules with not-exists cannot have RETRACT clauses. "
                "Negation rules run in Phase 2 and must be side-effect free."
            )
        return errors

    def _binding_still_valid(self, bindings: dict, world: 'World') -> bool:
        """
        Check if a binding is still valid (all matched facts still exist).

        This implements spec §6.1: "bindings found in the same scan may be
        invalidated by earlier bindings in that scan."

        If a prior firing retracted a fact that this binding depends on,
        we should skip this binding rather than fire with stale data.
        """
        def resolve(val):
            if isinstance(val, Var):
                return bindings.get(val.name, val)
            return val

        for pattern in self.patterns:
            p_subj = resolve(pattern[0])
            p_rel = resolve(pattern[1])
            p_obj = resolve(pattern[2])

            # Check if this specific fact still exists
            matches = world.query((p_subj, p_rel, p_obj))
            if not matches:
                return False

        return True

    def apply(self, world: World) -> int:
        """
        Apply this rule, returning number of changes made.

        For each binding that matches patterns:
        0. Re-validate binding (spec §6.1) - skip if facts no longer exist
        1. Evaluate guard (if present) - skip binding if false
        2. Assert the template (if not already exists)
        3. Retract any facts matching the retractions list

        For deferred rules (self.deferred=True):
        - Instead of applying effects immediately, queue them for the next micro-iteration
        - This creates causal ordering within a tick

        Spec reference: §5.2, §6.1, §10, §14 (deferred)
        """
        count = 0
        ephemeral_to_consume = set()  # Track ephemeral facts to consume after ALL bindings

        for bindings in world.query(*self.patterns):
            # --- Re-validate binding (§6.1) ---
            # Earlier firings in this iteration may have retracted facts
            # that this binding depends on. If so, skip this binding.
            if not self._binding_still_valid(bindings, world):
                continue

            # --- Once-per-tick check (§15) ---
            # If this rule is marked once_per_tick, check if this binding
            # has already fired this tick. Skip if so.
            if self.once_per_tick:
                # Compute binding key from specified vars or all pattern vars
                if self.once_key_vars is not None:
                    key_values = tuple(bindings.get(v) for v in self.once_key_vars)
                else:
                    # Use all bound variables from patterns
                    key_values = tuple(sorted(bindings.items()))
                fired_key = (self.name, key_values)
                if fired_key in world._fired_this_tick:
                    continue  # Already fired for this binding this tick

            # --- Evaluate guard (§10) ---
            if self.guard is not None:
                try:
                    guard_result = evaluate_expr(self.guard, bindings, world)
                    if guard_result is not True:
                        # Guard failed or returned non-boolean - skip this binding
                        continue
                except (ValueError, TypeError):
                    # Guard evaluation error - skip this binding
                    continue
            # Closure capture issue: need to bind bindings in the scope
            def make_resolver(b, w):
                def resolve(x):
                    if isinstance(x, Var):
                        return b.get(x.name, x)
                    elif isinstance(x, AggregateExpr):
                        return evaluate_aggregate_expr(x, b, w)
                    elif isinstance(x, Expr):
                        return evaluate_expr(x, b, w)
                    return x
                return resolve

            resolve = make_resolver(bindings, world)

            # --- Get cause facts for provenance (shared by all templates) ---
            cause_facts = []
            for pattern in self.patterns:
                p_subj = resolve(pattern[0])
                p_rel = resolve(pattern[1])
                p_obj = resolve(pattern[2])
                for fid, fact in world._all_facts.items():
                    if (fact.subject == p_subj and fact.relation == p_rel
                        and fact.object == p_obj and fact.is_alive(world.tick)):
                        cause_facts.append(fid)
                        break

            if self.deferred:
                # --- DEFERRED: Queue effects for next micro-iteration ---
                # This creates causal ordering: current facts must settle
                # before these effects are applied
                #
                # Key: We track what's already queued in _deferred_pending
                # to prevent duplicate queueing (since the source facts
                # won't be retracted until the next micro-iteration).
                #
                # IMPORTANT: If this rule has retractions and any of them
                # are already queued, skip this binding entirely. This prevents
                # the same input from being processed multiple times (e.g.,
                # apply_damage firing twice on the same pending_damage).

                # Check if any retractions are already queued
                should_skip = False
                for retraction in self.retractions:
                    r_subj = resolve(retraction[0])
                    r_rel = resolve(retraction[1])
                    r_obj = resolve(retraction[2])
                    pending_key = (r_subj, r_rel, r_obj, True)
                    if pending_key in world._deferred_pending:
                        should_skip = True
                        break

                if should_skip:
                    continue  # Skip this binding entirely

                for template in self.templates:
                    subj = resolve(template[0])
                    rel = resolve(template[1])
                    obj = resolve(template[2])

                    # Check if already queued this exact assertion
                    pending_key = (subj, rel, obj, False)
                    if pending_key in world._deferred_pending:
                        continue

                    # Check if this would be a new fact
                    existing = world.query((subj, rel, obj))
                    if not existing:
                        # Queue for next micro-iteration
                        world._deferred_queue.append((
                            subj, rel, obj,
                            f"rule:{self.name}",
                            tuple(cause_facts),
                            False  # is_retraction = False
                        ))
                        world._deferred_pending.add(pending_key)
                        count += 1

                for retraction in self.retractions:
                    r_subj = resolve(retraction[0])
                    r_rel = resolve(retraction[1])
                    r_obj = resolve(retraction[2])

                    # Check if already queued this exact retraction
                    pending_key = (r_subj, r_rel, r_obj, True)
                    if pending_key in world._deferred_pending:
                        continue

                    # Check if fact exists to retract
                    existing = world.query((r_subj, r_rel, r_obj))
                    if existing:
                        world._deferred_queue.append((
                            r_subj, r_rel, r_obj,
                            f"rule:{self.name}",
                            tuple(cause_facts),
                            True  # is_retraction = True
                        ))
                        world._deferred_pending.add(pending_key)
                        count += 1

            else:
                # --- IMMEDIATE: Apply effects now ---

                # Assert ALL templates
                for template in self.templates:
                    subj = resolve(template[0])
                    rel = resolve(template[1])
                    obj = resolve(template[2])

                    # Check if this would be a new fact
                    existing = world.query((subj, rel, obj))
                    if not existing:
                        world.assert_fact(subj, rel, obj,
                                          cause=f"rule:{self.name}",
                                          cause_facts=tuple(cause_facts))
                        count += 1

                # Process retractions (after ALL assertions)
                for retraction in self.retractions:
                    r_subj = resolve(retraction[0])
                    r_rel = resolve(retraction[1])
                    r_obj = resolve(retraction[2])
                    if world.retract_fact(r_subj, r_rel, r_obj):
                        count += 1

            # --- Mark this binding as fired for once-per-tick rules ---
            if self.once_per_tick:
                world._fired_this_tick.add(fired_key)

            # --- Track ephemeral facts to consume (but don't consume yet) ---
            # We'll consume them AFTER processing ALL bindings so that
            # multiple bindings can match the same ephemeral fact
            for pattern in self.patterns:
                p_rel = resolve(pattern[1])
                if world.is_ephemeral(p_rel):
                    p_subj = resolve(pattern[0])
                    p_obj = resolve(pattern[2])
                    ephemeral_to_consume.add((p_subj, p_rel, p_obj))

        # --- Consume ephemeral facts AFTER all bindings processed ---
        # This allows area effects (one command hits all targets)
        for subj, rel, obj in ephemeral_to_consume:
            if world.retract_fact(subj, rel, obj):
                count += 1

        return count


@dataclass
class ReactionRule:
    """A rule that fires an action when patterns match after a change."""
    name: str
    trigger: str  # 'on_add' or 'on_retract'
    patterns: list[tuple]
    action: Callable[[World, dict], None]

    def apply(self, world: World, changes: list[tuple[str, Fact]]):
        """Check if any changes trigger this rule."""
        trigger_type = 'added' if self.trigger == 'on_add' else 'retracted'

        for change_type, fact in changes:
            if change_type == trigger_type:
                # Check if patterns match with this fact as part of the match
                for bindings in world.query(*self.patterns):
                    self.action(world, bindings)


# =============================================================================
# DEMO
# =============================================================================

if __name__ == "__main__":
    print("=" * 60)
    print("HERB Core — Temporal Facts with Provenance")
    print("=" * 60)

    world = World()

    # Build a small world
    world.assert_fact("alice", "is_a", "person")
    world.assert_fact("alice", "hp", 100)
    world.assert_fact("alice", "location", "town")

    world.assert_fact("bob", "is_a", "person")
    world.assert_fact("bob", "hp", 80)
    world.assert_fact("bob", "location", "forest")

    world.assert_fact("goblin", "is_a", "monster")
    world.assert_fact("goblin", "hp", 30)
    world.assert_fact("goblin", "location", "forest")

    # Add a rule: if person and monster are in same location, they're in_combat
    world.add_derivation_rule(
        "combat_proximity",
        [(X, "is_a", "person"), (Y, "is_a", "monster"),
         (X, "location", Z), (Y, "location", Z)],
        (X, "in_combat_with", Y)
    )

    world.print_state()

    # Advance (runs derivation)
    print("\n--- Advancing tick (derivation runs) ---")
    world.advance()
    world.print_state()

    # Query: who is in combat?
    print("\n--- Query: Who is in combat? ---")
    for b in world.query((X, "in_combat_with", Y)):
        print(f"  {b['x']} is in combat with {b['y']}")

    # Explain why bob is in combat
    print("\n--- Explain: Why is bob in combat with goblin? ---")
    explanation = world.explain("bob", "in_combat_with", "goblin")
    if explanation:
        def print_explanation(exp, indent=0):
            prefix = "  " * indent
            print(f"{prefix}{exp['fact']}")
            print(f"{prefix}  caused by: {exp['cause']} at tick {exp['from_tick']}")
            for dep in exp['depends_on']:
                print_explanation(dep, indent + 1)
        print_explanation(explanation)

    # Simulate damage (update HP)
    print("\n--- Bob takes 20 damage ---")
    world.update_fact("bob", "hp", 80, 60, cause="combat_damage")
    world.advance()

    # History of bob's HP
    print("\n--- History of bob's HP ---")
    for fact in world.history("bob", "hp"):
        status = "alive" if fact.is_alive(world.tick) else f"ended tick {fact.to_tick}"
        print(f"  {fact.object} (tick {fact.from_tick}, {status}, cause: {fact.cause})")

    # Time travel query
    print("\n--- What was bob's HP at tick 0? ---")
    for b in world.query(("bob", "hp", X), at_tick=0):
        print(f"  bob's HP was {b['x']}")

    print(f"\n--- Final stats ---")
    print(f"Total facts ever created: {len(world._all_facts)}")
    print(f"Currently alive: {len(world)}")
    print(f"Current tick: {world.tick}")
