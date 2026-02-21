"""
HERB Program Representation

A HERB program is a data structure — not code. It declares:
  - Entity types
  - Containers (states, queues, slots)
  - Moves (the operation set)
  - Tensions (energy gradients as declarative patterns)
  - Pools (conservation tracking for quantities)
  - Transfers (quantity moves between entities)
  - Initial entities (with properties)

The runtime interprets this structure directly. No Python callables.
No arbitrary code. Pure data.

THE KEY DISTINCTION: A HERB program has no functions, no lambdas,
no control flow. Behavior emerges from tension resolution against
the operation set. The AI constructs a world description; the
runtime makes it live.

Match clause types:
  {"bind": "var", "in": "container_name"}
      Find entities in a container. Binds to entity IDs.

  {"bind": "var", "empty_in": ["c1", "c2", ...]}
      Find empty containers from a list. Binds to container IDs.

  {"container": "name", "is": "empty" | "occupied"}
      Boolean guard. No binding, just a condition.

  {"guard": <expression>}
      Expression guard. Evaluated against complete binding sets.
      If false, the binding set is discarded.

All entity match clauses support:
  "select": "first" (default) — one match (lowest entity ID)
  "select": "each" — all matches (produces vectors for pairing)
  "select": "max_by" — entity with highest value for "key" property
  "select": "min_by" — entity with lowest value for "key" property
  "key": "property_name" — required for max_by / min_by
  "where": <expression> — pre-pairing per-entity filter
  "required": true (default) — if no match, tension doesn't fire
  "required": false — if no match, binding is absent

Scoped container references (used in match "in" and emit "to"/"in"):
  {"scope": "binding_name", "container": "scope_container_name"}
      Resolves to a specific entity's scoped container.
      The scope entity must be bound by a previous match clause.

Emit clauses:
  {"move": "move_name", "entity": "ref", "to": "ref"}
      Containment move. "to" can be a scoped ref.

  {"transfer": "transfer_name", "from": "ref", "to": "ref", "amount": <expr>}
      Quantity transfer between entities.

  {"create": "TypeName", "in": "container_ref", "properties": {...}}
      Dynamic entity creation. Property values can be expressions.
      "in" can be a scoped ref.

  {"set": "entity_ref", "property": "name", "value": <expr>}
      Property mutation. Only for non-conserved properties.
      Conserved properties (in pools) can only change via transfer.

Expression language (pure data, no Python):
  Literal: 5, 3.14, "hello", true
  Property: {"prop": "priority", "of": "binding_name"}
  Binary op: {"op": "+", "left": <expr>, "right": <expr>}
  Unary op: {"op": "not", "arg": <expr>}
  Count: {"count": "container_name"}

Pairing (when multiple "each" clauses exist):
  "pair": "zip" (default) — first-to-first, second-to-second
  "pair": "cross" — Cartesian product of all matches
"""

from __future__ import annotations
from typing import Dict, List, Optional, Any, Set
from herb_move import (
    MoveGraph, ContainerKind, IntendedMove,
    IntendedTransfer, IntendedCreate, IntendedSet,
    IntendedSend, IntendedReceive, IntendedDuplicate
)


# =============================================================================
# EXPRESSION EVALUATOR
# =============================================================================

def _eval_expr(
    expr: Any,
    bindings: dict,
    graph: MoveGraph,
    entity_ids: dict,
    container_ids: dict
) -> Any:
    """
    Evaluate a declarative expression.

    Expressions are pure data — dicts, lists, and literals.
    The runtime interprets them against the current graph state
    and variable bindings.

    Returns the evaluated value, or None if unresolvable.
    """
    # Literal values pass through
    if isinstance(expr, (int, float, bool)):
        return expr
    if isinstance(expr, str):
        return expr

    if not isinstance(expr, dict):
        return None

    # Property access: {"prop": "priority", "of": "proc"}
    if "prop" in expr:
        prop_name = expr["prop"]
        entity_ref = expr.get("of")
        if entity_ref is None:
            return None

        # Resolve entity reference: check bindings first, then named entities
        entity_id = bindings.get(entity_ref)
        if entity_id is None:
            entity_id = entity_ids.get(entity_ref)
        if entity_id is None:
            return None

        return graph.get_property(entity_id, prop_name)

    # Container count: {"count": "READY_QUEUE"} or {"count": {"scope": ..., "container": ...}}
    # or {"count": {"channel": "pipe_AB"}}
    if "count" in expr:
        count_ref = expr["count"]
        if isinstance(count_ref, dict):
            if "channel" in count_ref:
                ch = graph.channels.get(count_ref["channel"])
                if ch is None:
                    return None
                cid = ch["buffer_container"]
            else:
                scope_ref = count_ref.get("scope")
                scope_cname = count_ref.get("container")
                scope_eid = bindings.get(scope_ref) or entity_ids.get(scope_ref)
                if scope_eid is None:
                    return None
                cid = graph.get_scoped_container(scope_eid, scope_cname)
        else:
            cid = container_ids.get(count_ref)
        if cid is None:
            return None
        return graph.containers[cid].count

    # Dimensional check: {"in": "PRIO_HIGH", "of": "proc"}
    # Checks if the entity bound to "proc" is in the container "PRIO_HIGH"
    # (in whatever dimension that container belongs to). Works across all dimensions.
    if "in" in expr and "of" in expr:
        container_name = expr["in"]
        entity_ref = expr["of"]

        # Resolve entity
        entity_id = bindings.get(entity_ref)
        if entity_id is None:
            entity_id = entity_ids.get(entity_ref)
        if entity_id is None:
            return None

        # Resolve container
        if isinstance(container_name, dict):
            cid = None  # Scoped/channel refs not supported here
        else:
            cid = container_ids.get(container_name)
        if cid is None:
            return None

        return graph.is_entity_in_container(entity_id, cid)

    # Binary/unary operations: {"op": ">", "left": ..., "right": ...}
    if "op" in expr:
        op = expr["op"]

        # Unary: not
        if op == "not":
            arg = _eval_expr(expr.get("arg"), bindings, graph, entity_ids, container_ids)
            if arg is None:
                return None
            return not arg

        # Binary operations
        left = _eval_expr(expr.get("left"), bindings, graph, entity_ids, container_ids)
        right = _eval_expr(expr.get("right"), bindings, graph, entity_ids, container_ids)

        if left is None or right is None:
            return None

        _ops = {
            "+":  lambda a, b: a + b,
            "-":  lambda a, b: a - b,
            "*":  lambda a, b: a * b,
            "//": lambda a, b: a // b if b != 0 else None,
            "%":  lambda a, b: a % b if b != 0 else None,
            ">":  lambda a, b: a > b,
            "<":  lambda a, b: a < b,
            ">=": lambda a, b: a >= b,
            "<=": lambda a, b: a <= b,
            "==": lambda a, b: a == b,
            "!=": lambda a, b: a != b,
            "and": lambda a, b: a and b,
            "or":  lambda a, b: a or b,
        }

        fn = _ops.get(op)
        if fn is None:
            return None
        return fn(left, right)

    return None


# =============================================================================
# PROGRAM LOADER
# =============================================================================

class HerbProgram:
    """
    A HERB program loader and interpreter.

    Takes a program specification (pure data dict) and produces
    a running MoveGraph with declarative tensions compiled into
    the runtime's callable format.

    The program dict is the canonical representation of a HERB program.
    An AI reads, writes, and modifies this dict directly.
    """

    def __init__(self, spec: dict):
        self.spec = spec
        self._type_ids: Dict[str, int] = {}       # type_name -> type_id
        self._container_ids: Dict[str, int] = {}   # container_name -> container_id
        self._entity_ids: Dict[str, int] = {}      # entity_name -> entity_id
        self.graph: Optional[MoveGraph] = None

    def load(self) -> MoveGraph:
        """
        Load the program specification into a MoveGraph.

        This is the bridge from data to running system:
        1a. Define entity types
        1b. Register scoped container templates (after all types known)
        2. Define containers
        3. Define moves (regular and scoped)
        4. Define pools and transfers (conservation)
        5. Create initial entities (with properties + scoped containers)
        6. Compile declarative tensions into runtime callables
        """
        g = MoveGraph()

        # 1a. Entity types (first pass — names only)
        for et in self.spec.get("entity_types", []):
            tid = g.define_entity_type(et["name"])
            self._type_ids[et["name"]] = tid

        # 1b. Scoped container templates (second pass — all types known)
        for et in self.spec.get("entity_types", []):
            if "scoped_containers" in et:
                tid = self._type_ids[et["name"]]
                scope_defs = []
                for sc in et["scoped_containers"]:
                    scope_defs.append({
                        "name": sc["name"],
                        "kind": _parse_container_kind(sc.get("kind", "simple")),
                        "entity_type": self._type_ids.get(sc.get("entity_type")),
                    })
                g.define_entity_type_scopes(tid, scope_defs)

        # 2. Containers (with optional dimension)
        for c in self.spec.get("containers", []):
            kind = _parse_container_kind(c.get("kind", "simple"))
            et_id = self._type_ids.get(c.get("entity_type"))
            dim = c.get("dimension")
            cid = g.define_container(c["name"], kind, et_id, dimension=dim)
            self._container_ids[c["name"]] = cid

        # 3. Moves (regular and scoped)
        for m in self.spec.get("moves", []):
            et_id = self._type_ids.get(m.get("entity_type"))
            if "scoped_from" in m or "scoped_to" in m:
                # Scoped move — from/to are scope container names
                g.define_move(
                    m["name"],
                    entity_type=et_id,
                    is_scoped=True,
                    scoped_from=m.get("scoped_from", []),
                    scoped_to=m.get("scoped_to", []),
                )
            else:
                from_ids = [self._container_ids[n] for n in m["from"]]
                to_ids = [self._container_ids[n] for n in m["to"]]
                g.define_move(m["name"], from_ids, to_ids, et_id)

        # 4. Pools and transfers (conservation)
        for p in self.spec.get("pools", []):
            g.define_pool(p["name"], p["property"])

        for t in self.spec.get("transfers", []):
            et_id = self._type_ids.get(t.get("entity_type"))
            g.define_transfer(t["name"], t["pool"], et_id)

        # 5. Initial entities (with properties + auto-created scoped containers)
        for e in self.spec.get("entities", []):
            tid = self._type_ids[e["type"]]
            in_spec = e.get("in")
            if isinstance(in_spec, dict):
                # Scoped initial placement: {"scope": "proc_A", "container": "FD_FREE"}
                scope_eid = self._entity_ids[in_spec["scope"]]
                cid = g.get_scoped_container(scope_eid, in_spec["container"])
            elif in_spec is not None:
                cid = self._container_ids.get(in_spec)
            else:
                cid = None
            props = e.get("properties")
            eid = g.create_entity(tid, e["name"], cid, props)
            self._entity_ids[e["name"]] = eid

            # Multi-dimensional placement: {"also_in": {"priority": "PRIO_HIGH"}}
            also_in = e.get("also_in")
            if also_in and isinstance(also_in, dict):
                for dim_name, container_name in also_in.items():
                    dim_cid = self._container_ids.get(container_name)
                    if dim_cid is not None:
                        g.enroll_in_dimension(eid, dim_cid)

        # 6. Channels (after entities — channels reference entity names)
        for ch in self.spec.get("channels", []):
            sender_id = self._entity_ids[ch["from"]]
            receiver_id = self._entity_ids[ch["to"]]
            et_id = self._type_ids.get(ch.get("entity_type"))
            buffer_cid = g.define_channel(
                ch["name"], sender_id, receiver_id, et_id
            )
            self._container_ids[f"channel:{ch['name']}"] = buffer_cid

        # 7. Nesting depth bound
        max_depth = self.spec.get("max_nesting_depth")
        if max_depth is not None:
            g.max_nesting_depth = max_depth

        # 8. Compile and register tensions
        for t in self.spec.get("tensions", []):
            check_fn = self._compile_tension(t)
            g.define_tension(t["name"], check_fn, t.get("priority", 0))

        self.graph = g
        return g

    # =========================================================================
    # TENSION COMPILER
    # =========================================================================

    def _compile_tension(self, tension_spec: dict):
        """
        Convert a declarative tension specification into a callable
        that the MoveGraph runtime can execute.

        This is the core of the representation → runtime bridge.
        The callable closes over the resolved container/entity IDs
        and the match/emit structure. At runtime, it queries the
        graph state and produces IntendedMoves, IntendedTransfers,
        and IntendedCreates.
        """
        match_clauses = tension_spec.get("match", [])
        emit_clauses = tension_spec.get("emit", [])
        pair_mode = tension_spec.get("pair", "zip")

        # Capture resolved IDs for the closure
        container_ids = dict(self._container_ids)
        entity_ids = dict(self._entity_ids)
        type_ids = dict(self._type_ids)

        def check(graph: MoveGraph) -> list:
            # Phase 1: Resolve match clauses to bindings
            scalars = {}       # bind_name -> value
            vectors = []       # [(bind_name, [values])] — order preserved
            unbound: Set[str] = set()  # optional bindings that didn't match
            guards = []        # expression guards for Phase 2.5

            for clause in match_clauses:
                required = clause.get("required", True)
                bind_name = clause.get("bind")
                select = clause.get("select", "first")

                # --- Expression guard clause ---
                if "guard" in clause:
                    guards.append(clause["guard"])
                    continue

                # --- Entity query: find entities in a container ---
                if "in" in clause:
                    in_spec = clause["in"]
                    if isinstance(in_spec, dict):
                        if "channel" in in_spec:
                            # Channel buffer: {"channel": "pipe_AB"}
                            ch = graph.channels.get(in_spec["channel"])
                            if ch is None:
                                if required:
                                    return []
                                if bind_name:
                                    unbound.add(bind_name)
                                continue
                            cid = ch["buffer_container"]
                        else:
                            # Scoped: {"scope": "proc", "container": "FD_FREE"}
                            scope_ref = in_spec["scope"]
                            scope_cname = in_spec["container"]
                            scope_eid = scalars.get(scope_ref)
                            if scope_eid is None:
                                scope_eid = entity_ids.get(scope_ref)
                            if scope_eid is None:
                                if required:
                                    return []
                                if bind_name:
                                    unbound.add(bind_name)
                                continue
                            cid = graph.get_scoped_container(scope_eid, scope_cname)
                            if cid is None:
                                if required:
                                    return []
                                if bind_name:
                                    unbound.add(bind_name)
                                continue
                    else:
                        cid = container_ids[in_spec]
                    entities = sorted(graph.contents_of(cid))

                    # Apply "where" filter (per-entity expression)
                    if "where" in clause and bind_name and entities:
                        where_expr = clause["where"]
                        filtered = []
                        for eid in entities:
                            test_bs = {bind_name: eid}
                            result = _eval_expr(
                                where_expr, test_bs, graph,
                                entity_ids, container_ids
                            )
                            if result:
                                filtered.append(eid)
                        entities = filtered

                    if not entities:
                        if required:
                            return []
                        if bind_name:
                            unbound.add(bind_name)
                        continue

                    if bind_name:
                        if select == "first":
                            scalars[bind_name] = entities[0]
                        elif select == "each":
                            vectors.append((bind_name, entities))
                        elif select == "max_by":
                            key_prop = clause["key"]
                            best = max(
                                entities,
                                key=lambda eid: graph.get_property(eid, key_prop) or 0
                            )
                            scalars[bind_name] = best
                        elif select == "min_by":
                            key_prop = clause["key"]
                            best = min(
                                entities,
                                key=lambda eid: graph.get_property(eid, key_prop) or 0
                            )
                            scalars[bind_name] = best

                # --- Empty container query ---
                elif "empty_in" in clause:
                    cnames = clause["empty_in"]
                    empty_cids = []
                    for cn in cnames:
                        cid = container_ids[cn]
                        if graph.containers[cid].is_empty():
                            empty_cids.append(cid)

                    if not empty_cids:
                        if required:
                            return []
                        if bind_name:
                            unbound.add(bind_name)
                        continue

                    if bind_name:
                        if select == "first":
                            scalars[bind_name] = empty_cids[0]
                        elif select == "each":
                            vectors.append((bind_name, empty_cids))

                # --- Boolean guard: container state ---
                elif "container" in clause:
                    cid = container_ids[clause["container"]]
                    condition = clause["is"]

                    if condition == "empty":
                        if not graph.containers[cid].is_empty():
                            if required:
                                return []
                    elif condition == "occupied":
                        if graph.containers[cid].is_empty():
                            if required:
                                return []

            # Phase 2: Build binding sets from scalars + vectors
            if not vectors:
                binding_sets = [dict(scalars)]
            else:
                vec_names = [name for name, _ in vectors]
                vec_lists = [vals for _, vals in vectors]

                if pair_mode == "zip":
                    min_len = min(len(v) for v in vec_lists)
                    binding_sets = []
                    for i in range(min_len):
                        bs = dict(scalars)
                        for j, name in enumerate(vec_names):
                            bs[name] = vec_lists[j][i]
                        binding_sets.append(bs)
                elif pair_mode == "cross":
                    from itertools import product
                    binding_sets = []
                    for combo in product(*vec_lists):
                        bs = dict(scalars)
                        for j, name in enumerate(vec_names):
                            bs[name] = combo[j]
                        binding_sets.append(bs)
                else:
                    binding_sets = [dict(scalars)]

            # Phase 2.5: Filter binding sets through expression guards
            if guards:
                filtered_sets = []
                for bs in binding_sets:
                    all_pass = True
                    for guard_expr in guards:
                        result = _eval_expr(
                            guard_expr, bs, graph,
                            entity_ids, container_ids
                        )
                        if not result:
                            all_pass = False
                            break
                    if all_pass:
                        filtered_sets.append(bs)
                binding_sets = filtered_sets

            # Phase 3: Generate actions from emit clauses + bindings
            actions = []
            for bs in binding_sets:
                for emit in emit_clauses:
                    # --- Containment move ---
                    if "move" in emit:
                        entity_ref = emit["entity"]
                        to_ref = emit["to"]

                        entity_id = _resolve_ref(
                            entity_ref, bs, entity_ids, unbound
                        )
                        if entity_id is None:
                            continue

                        to_id = _resolve_container_ref(
                            to_ref, bs, container_ids,
                            entity_ids, graph, unbound
                        )
                        if to_id is None:
                            continue

                        actions.append(IntendedMove(
                            emit["move"], entity_id, to_id
                        ))

                    # --- Quantity transfer ---
                    elif "transfer" in emit:
                        from_ref = emit["from"]
                        to_ref = emit["to"]
                        amount_expr = emit["amount"]

                        from_id = _resolve_ref(
                            from_ref, bs, entity_ids, unbound
                        )
                        if from_id is None:
                            continue

                        to_id = _resolve_ref(
                            to_ref, bs, entity_ids, unbound
                        )
                        if to_id is None:
                            continue

                        amount = _eval_expr(
                            amount_expr, bs, graph,
                            entity_ids, container_ids
                        )
                        if amount is None:
                            continue

                        actions.append(IntendedTransfer(
                            emit["transfer"], from_id, to_id, amount
                        ))

                    # --- Dynamic entity creation ---
                    elif "create" in emit:
                        type_name = emit["create"]
                        tid = type_ids.get(type_name)
                        if tid is None:
                            continue

                        container_ref = emit["in"]
                        cid = _resolve_container_ref(
                            container_ref, bs, container_ids,
                            entity_ids, graph, unbound
                        )
                        if cid is None:
                            continue

                        # Resolve property expressions
                        props = {}
                        for key, val_expr in emit.get("properties", {}).items():
                            val = _eval_expr(
                                val_expr, bs, graph,
                                entity_ids, container_ids
                            )
                            if val is not None:
                                props[key] = val

                        actions.append(IntendedCreate(
                            tid, cid, props, emit.get("name")
                        ))

                    # --- Property mutation ---
                    elif "set" in emit:
                        entity_ref = emit["set"]
                        entity_id = _resolve_ref(
                            entity_ref, bs, entity_ids, unbound
                        )
                        if entity_id is None:
                            continue

                        value = _eval_expr(
                            emit["value"], bs, graph,
                            entity_ids, container_ids
                        )
                        if value is None:
                            continue

                        actions.append(IntendedSet(
                            entity_id, emit["property"], value
                        ))

                    # --- Channel send ---
                    elif "send" in emit:
                        channel_name = emit["send"]
                        entity_ref = emit["entity"]
                        entity_id = _resolve_ref(
                            entity_ref, bs, entity_ids, unbound
                        )
                        if entity_id is None:
                            continue

                        actions.append(IntendedSend(
                            channel_name, entity_id
                        ))

                    # --- Channel receive ---
                    elif "receive" in emit:
                        channel_name = emit["receive"]
                        entity_ref = emit["entity"]
                        entity_id = _resolve_ref(
                            entity_ref, bs, entity_ids, unbound
                        )
                        if entity_id is None:
                            continue

                        to_ref = emit["to"]
                        to_id = _resolve_container_ref(
                            to_ref, bs, container_ids,
                            entity_ids, graph, unbound
                        )
                        if to_id is None:
                            continue

                        actions.append(IntendedReceive(
                            channel_name, entity_id, to_id
                        ))

                    # --- Entity duplication ---
                    elif "duplicate" in emit:
                        entity_ref = emit["duplicate"]
                        entity_id = _resolve_ref(
                            entity_ref, bs, entity_ids, unbound
                        )
                        if entity_id is None:
                            continue

                        container_ref = emit["in"]
                        cid = _resolve_container_ref(
                            container_ref, bs, container_ids,
                            entity_ids, graph, unbound
                        )
                        if cid is None:
                            continue

                        actions.append(IntendedDuplicate(
                            entity_id, cid, emit.get("name")
                        ))

            return actions

        return check

    # =========================================================================
    # RUNTIME HELPERS
    # =========================================================================

    def create_entity(
        self,
        name: str,
        type_name: str,
        container_name: str,
        properties: Optional[dict] = None
    ) -> int:
        """Create an entity at runtime (for signals, dynamic entities)."""
        tid = self._type_ids[type_name]
        cid = self._container_ids[container_name]
        eid = self.graph.create_entity(tid, name, cid, properties)
        self._entity_ids[name] = eid
        return eid

    def entity_id(self, name: str) -> int:
        """Get entity ID by name."""
        return self._entity_ids[name]

    def container_id(self, name: str) -> int:
        """Get container ID by name."""
        return self._container_ids[name]

    def type_id(self, name: str) -> int:
        """Get entity type ID by name."""
        return self._type_ids[name]

    def where_is(self, entity_name: str) -> Optional[str]:
        """Get the container name an entity is in."""
        eid = self._entity_ids.get(entity_name)
        if eid is None:
            return None
        return self.graph.where_is_named(eid)

    def get_property(self, entity_name: str, prop: str) -> Any:
        """Get a property value from a named entity."""
        eid = self._entity_ids.get(entity_name)
        if eid is None:
            return None
        return self.graph.get_property(eid, prop)


# =============================================================================
# HELPERS
# =============================================================================

def _parse_container_kind(kind_str: str) -> ContainerKind:
    """Parse container kind from string."""
    return {
        "simple": ContainerKind.SIMPLE,
        "slot": ContainerKind.SLOT,
        "pool": ContainerKind.POOL,
    }[kind_str]


def _resolve_ref(
    ref: str,
    bindings: dict,
    named_lookup: dict,
    unbound: Set[str]
) -> Optional[int]:
    """
    Resolve a reference to an ID.

    Resolution order:
    1. Check if ref is a binding name → use bound value
    2. Check if ref is in named_lookup (entity or container names) → use ID
    3. If ref is in unbound set → return None (optional binding didn't match)
    4. Return None (unresolvable)
    """
    if ref in bindings:
        return bindings[ref]
    if ref in named_lookup:
        return named_lookup[ref]
    if ref in unbound:
        return None  # Optional binding, not available
    return None


def _resolve_container_ref(
    ref,
    bindings: dict,
    container_ids: dict,
    entity_ids: dict,
    graph: 'MoveGraph',
    unbound: Set[str]
) -> Optional[int]:
    """
    Resolve a container reference that may be scoped or channel.

    If ref is a dict like {"scope": "proc", "container": "FD_FREE"},
    resolves through the entity's scoped containers.
    If ref is a dict like {"channel": "pipe_AB"},
    resolves to the channel's buffer container.
    If ref is a string, uses the standard resolution path.
    """
    if isinstance(ref, dict):
        if "channel" in ref:
            ch = graph.channels.get(ref["channel"])
            if ch is None:
                return None
            return ch["buffer_container"]
        scope_ref = ref.get("scope")
        scope_cname = ref.get("container")
        if scope_ref is None or scope_cname is None:
            return None
        scope_eid = bindings.get(scope_ref)
        if scope_eid is None:
            scope_eid = entity_ids.get(scope_ref)
        if scope_eid is None:
            return None
        return graph.get_scoped_container(scope_eid, scope_cname)
    else:
        return _resolve_ref(ref, bindings, container_ids, unbound)


# =============================================================================
# PROGRAM VALIDATION
# =============================================================================

def validate_program(spec: dict) -> List[str]:
    """
    Validate a HERB program specification for structural errors.

    Returns list of error messages. Empty list = valid.
    This is a static check — it doesn't execute the program.
    """
    errors = []

    # Check required sections
    if "entity_types" not in spec:
        errors.append("Missing 'entity_types' section")
    if "containers" not in spec:
        errors.append("Missing 'containers' section")

    # Collect names for cross-referencing
    type_names = {et["name"] for et in spec.get("entity_types", [])}
    container_names = {c["name"] for c in spec.get("containers", [])}
    entity_names = {e["name"] for e in spec.get("entities", [])}
    pool_names = {p["name"] for p in spec.get("pools", [])}

    # Collect dimension names
    declared_dimensions = set(spec.get("dimensions", []))
    container_dimensions = {}  # container_name -> dimension
    for c in spec.get("containers", []):
        dim = c.get("dimension")
        if dim is not None:
            container_dimensions[c["name"]] = dim
            if declared_dimensions and dim not in declared_dimensions:
                errors.append(f"Container '{c['name']}': unknown dimension '{dim}'")

    # Collect scoped container names from entity types
    scoped_container_names = set()
    for et in spec.get("entity_types", []):
        for sc in et.get("scoped_containers", []):
            scoped_container_names.add(sc["name"])
            if "entity_type" in sc and sc["entity_type"] not in type_names:
                errors.append(f"Entity type '{et['name']}' scoped container '{sc['name']}': unknown entity_type '{sc['entity_type']}'")
            if sc.get("kind") and sc["kind"] not in ("simple", "slot", "pool"):
                errors.append(f"Entity type '{et['name']}' scoped container '{sc['name']}': invalid kind '{sc['kind']}'")

    # Validate containers
    for c in spec.get("containers", []):
        if c.get("kind") and c["kind"] not in ("simple", "slot", "pool"):
            errors.append(f"Container '{c['name']}': invalid kind '{c['kind']}'")
        if "entity_type" in c and c["entity_type"] not in type_names:
            errors.append(f"Container '{c['name']}': unknown entity_type '{c['entity_type']}'")

    # Validate moves
    move_names = set()
    for m in spec.get("moves", []):
        move_names.add(m["name"])
        if "scoped_from" in m or "scoped_to" in m:
            # Scoped move — validate scope container names
            for sn in m.get("scoped_from", []):
                if sn not in scoped_container_names:
                    errors.append(f"Move '{m['name']}': unknown scoped_from container '{sn}'")
            for sn in m.get("scoped_to", []):
                if sn not in scoped_container_names:
                    errors.append(f"Move '{m['name']}': unknown scoped_to container '{sn}'")
        else:
            for cn in m.get("from", []):
                if cn not in container_names:
                    errors.append(f"Move '{m['name']}': unknown from container '{cn}'")
            for cn in m.get("to", []):
                if cn not in container_names:
                    errors.append(f"Move '{m['name']}': unknown to container '{cn}'")
        if "entity_type" in m and m["entity_type"] not in type_names:
            errors.append(f"Move '{m['name']}': unknown entity_type '{m['entity_type']}'")

        # Check dimension consistency: all containers in a move should be in same dimension
        if "scoped_from" not in m and "scoped_to" not in m:
            move_dims = set()
            for cn in m.get("from", []) + m.get("to", []):
                move_dims.add(container_dimensions.get(cn))
            if len(move_dims) > 1:
                errors.append(f"Move '{m['name']}': containers span multiple dimensions {move_dims}")

    # Validate pools
    for p in spec.get("pools", []):
        if "name" not in p:
            errors.append("Pool missing 'name'")
        if "property" not in p:
            errors.append(f"Pool '{p.get('name', '?')}': missing 'property'")

    # Validate transfers
    transfer_names = set()
    for t in spec.get("transfers", []):
        transfer_names.add(t["name"])
        if t.get("pool") not in pool_names:
            errors.append(f"Transfer '{t['name']}': unknown pool '{t.get('pool')}'")
        if "entity_type" in t and t["entity_type"] not in type_names:
            errors.append(f"Transfer '{t['name']}': unknown entity_type '{t['entity_type']}'")

    # Validate channels
    channel_names = set()
    for ch in spec.get("channels", []):
        channel_names.add(ch["name"])
        if "from" not in ch:
            errors.append(f"Channel '{ch['name']}': missing 'from' (sender entity)")
        elif ch["from"] not in entity_names:
            errors.append(f"Channel '{ch['name']}': unknown sender entity '{ch['from']}'")
        if "to" not in ch:
            errors.append(f"Channel '{ch['name']}': missing 'to' (receiver entity)")
        elif ch["to"] not in entity_names:
            errors.append(f"Channel '{ch['name']}': unknown receiver entity '{ch['to']}'")
        if "entity_type" in ch and ch["entity_type"] not in type_names:
            errors.append(f"Channel '{ch['name']}': unknown entity_type '{ch['entity_type']}'")

    # Validate nesting depth bound
    max_depth = spec.get("max_nesting_depth")
    if max_depth is not None:
        if not isinstance(max_depth, int) or max_depth < 1:
            errors.append(f"max_nesting_depth must be a positive integer, got {max_depth}")

    # Validate entities
    for e in spec.get("entities", []):
        if e.get("type") not in type_names:
            errors.append(f"Entity '{e['name']}': unknown type '{e['type']}'")
        if "in" in e:
            in_spec = e["in"]
            if isinstance(in_spec, dict):
                # Scoped placement: {"scope": "entity_name", "container": "scope_name"}
                scope_entity = in_spec.get("scope")
                scope_cname = in_spec.get("container")
                if scope_entity and scope_entity not in entity_names:
                    errors.append(f"Entity '{e['name']}': unknown scope entity '{scope_entity}'")
                if scope_cname and scope_cname not in scoped_container_names:
                    errors.append(f"Entity '{e['name']}': unknown scoped container '{scope_cname}'")
            elif in_spec not in container_names:
                errors.append(f"Entity '{e['name']}': unknown container '{in_spec}'")
        # Validate also_in (multi-dimensional placement)
        also_in = e.get("also_in")
        if also_in and isinstance(also_in, dict):
            for dim_name, cname in also_in.items():
                if cname not in container_names:
                    errors.append(f"Entity '{e['name']}': unknown container '{cname}' in also_in")
                elif container_dimensions.get(cname) != dim_name:
                    actual_dim = container_dimensions.get(cname)
                    errors.append(f"Entity '{e['name']}': container '{cname}' is in dimension '{actual_dim}', not '{dim_name}'")

    # Validate tensions
    all_names = container_names | entity_names

    for t in spec.get("tensions", []):
        bind_names = set()
        for clause in t.get("match", []):
            if "bind" in clause:
                bind_names.add(clause["bind"])
            if "in" in clause:
                in_spec = clause["in"]
                if isinstance(in_spec, dict):
                    if "channel" in in_spec:
                        if in_spec["channel"] not in channel_names:
                            errors.append(f"Tension '{t['name']}': unknown channel '{in_spec['channel']}' in match")
                    else:
                        # Scoped: {"scope": "proc", "container": "FD_FREE"}
                        scope_ref = in_spec.get("scope")
                        scope_cname = in_spec.get("container")
                        if scope_cname and scope_cname not in scoped_container_names:
                            errors.append(f"Tension '{t['name']}': unknown scoped container '{scope_cname}' in match")
                elif in_spec not in container_names:
                    errors.append(f"Tension '{t['name']}': unknown container '{in_spec}' in match")
            if "empty_in" in clause:
                for cn in clause["empty_in"]:
                    if cn not in container_names:
                        errors.append(f"Tension '{t['name']}': unknown container '{cn}' in empty_in")
            if "container" in clause and clause["container"] not in container_names:
                errors.append(f"Tension '{t['name']}': unknown container '{clause['container']}' in guard")

        for emit in t.get("emit", []):
            # Move emit
            if "move" in emit:
                if emit["move"] not in move_names:
                    errors.append(f"Tension '{t['name']}': unknown move '{emit['move']}' in emit")
                entity_ref = emit.get("entity")
                if entity_ref and entity_ref not in bind_names and entity_ref not in all_names:
                    errors.append(f"Tension '{t['name']}': unresolvable ref '{entity_ref}' in emit.entity")
                to_ref = emit.get("to")
                if to_ref and not isinstance(to_ref, dict):
                    if to_ref not in bind_names and to_ref not in all_names:
                        errors.append(f"Tension '{t['name']}': unresolvable ref '{to_ref}' in emit.to")

            # Transfer emit
            elif "transfer" in emit:
                if emit["transfer"] not in transfer_names:
                    errors.append(f"Tension '{t['name']}': unknown transfer '{emit['transfer']}' in emit")
                for key in ("from", "to"):
                    ref = emit.get(key)
                    if ref and ref not in bind_names and ref not in all_names:
                        errors.append(f"Tension '{t['name']}': unresolvable ref '{ref}' in emit.{key}")

            # Create emit
            elif "create" in emit:
                if emit["create"] not in type_names:
                    errors.append(f"Tension '{t['name']}': unknown type '{emit['create']}' in create emit")
                if "in" in emit:
                    ref = emit["in"]
                    if not isinstance(ref, dict):
                        if ref not in bind_names and ref not in container_names:
                            errors.append(f"Tension '{t['name']}': unresolvable container '{ref}' in create emit")

            # Set emit
            elif "set" in emit:
                entity_ref = emit.get("set")
                if entity_ref and entity_ref not in bind_names and entity_ref not in all_names:
                    errors.append(f"Tension '{t['name']}': unresolvable ref '{entity_ref}' in set emit")
                if "property" not in emit:
                    errors.append(f"Tension '{t['name']}': set emit missing 'property'")
                if "value" not in emit:
                    errors.append(f"Tension '{t['name']}': set emit missing 'value'")

            # Channel send emit
            elif "send" in emit:
                if emit["send"] not in channel_names:
                    errors.append(f"Tension '{t['name']}': unknown channel '{emit['send']}' in send emit")
                entity_ref = emit.get("entity")
                if entity_ref and entity_ref not in bind_names and entity_ref not in all_names:
                    errors.append(f"Tension '{t['name']}': unresolvable ref '{entity_ref}' in send emit")
                if "entity" not in emit:
                    errors.append(f"Tension '{t['name']}': send emit missing 'entity'")

            # Channel receive emit
            elif "receive" in emit:
                if emit["receive"] not in channel_names:
                    errors.append(f"Tension '{t['name']}': unknown channel '{emit['receive']}' in receive emit")
                entity_ref = emit.get("entity")
                if entity_ref and entity_ref not in bind_names and entity_ref not in all_names:
                    errors.append(f"Tension '{t['name']}': unresolvable ref '{entity_ref}' in receive emit")
                if "entity" not in emit:
                    errors.append(f"Tension '{t['name']}': receive emit missing 'entity'")
                if "to" not in emit:
                    errors.append(f"Tension '{t['name']}': receive emit missing 'to'")

            # Duplicate emit
            elif "duplicate" in emit:
                entity_ref = emit.get("duplicate")
                if entity_ref and entity_ref not in bind_names and entity_ref not in all_names:
                    errors.append(f"Tension '{t['name']}': unresolvable ref '{entity_ref}' in duplicate emit")
                if "in" not in emit:
                    errors.append(f"Tension '{t['name']}': duplicate emit missing 'in'")

    return errors
