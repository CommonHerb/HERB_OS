"""
HERB Program Composition

Modules are self-contained units of system behavior. Composition merges
modules into a unified program through namespace prefixing, export/import
resolution, entity type extension, and dependency ordering.

The output is a standard HERB program spec that HerbProgram can load.
The composition mechanism is pure data — no Python wiring code.

Module spec keys (beyond standard program keys):
  "module": "name"                — namespace identifier
  "exports": [...]                — names visible to other modules
  "imports": ["mod.name", ...]    — qualified external dependencies
  "entity_type_extensions": [...]  — scoped containers added to imported types

Composition spec:
  "compose": ["mod1", "mod2"]     — module names
  "modules": [MOD1, MOD2]         — module dicts
  "entities": [...]               — initial entities (qualified names)
  "tensions": [...]               — bridge tensions (optional)
  "channels": [...]               — cross-module channels (optional)
  "max_nesting_depth": int        — optional global depth bound
"""

from typing import Dict, List, Set, Optional, Any


# =============================================================================
# MODULE VALIDATION
# =============================================================================

def validate_module(spec: dict) -> List[str]:
    """
    Validate a HERB module specification.

    Returns list of error messages. Empty = valid.
    """
    errors = []

    if "module" not in spec:
        errors.append("Missing 'module' name")
        return errors

    mod_name = spec["module"]

    # Collect all locally defined names
    defined_names = set()
    for et in spec.get("entity_types", []):
        defined_names.add(et["name"])
    for c in spec.get("containers", []):
        defined_names.add(c["name"])
    for m in spec.get("moves", []):
        defined_names.add(m["name"])
    for p in spec.get("pools", []):
        defined_names.add(p["name"])
    for t in spec.get("transfers", []):
        defined_names.add(t["name"])

    # Collect scoped container names
    scoped_names = set()
    for et in spec.get("entity_types", []):
        for sc in et.get("scoped_containers", []):
            scoped_names.add(sc["name"])
    for ext in spec.get("entity_type_extensions", []):
        for sc in ext.get("add_scoped_containers", []):
            scoped_names.add(sc["name"])

    # Exports must reference defined or scoped names
    for exp in spec.get("exports", []):
        if exp not in defined_names and exp not in scoped_names:
            errors.append(
                f"Export '{exp}' not defined in module '{mod_name}'"
            )

    # Imports must be qualified
    for imp in spec.get("imports", []):
        if "." not in imp:
            errors.append(
                f"Import '{imp}' must be qualified (module.name)"
            )

    # Check for duplicate import aliases
    aliases = {}
    for imp in spec.get("imports", []):
        alias = imp.rsplit(".", 1)[-1]
        if alias in aliases:
            errors.append(
                f"Import alias '{alias}' is ambiguous: "
                f"'{aliases[alias]}' and '{imp}'"
            )
        aliases[alias] = imp

    # Check import/local name collisions
    for imp in spec.get("imports", []):
        alias = imp.rsplit(".", 1)[-1]
        if alias in defined_names:
            errors.append(
                f"Import alias '{alias}' collides with "
                f"local name in module '{mod_name}'"
            )

    return errors


# =============================================================================
# COMPOSITION
# =============================================================================

def compose(spec: dict) -> dict:
    """
    Compose multiple modules into a unified HERB program spec.

    Returns a standard program spec that HerbProgram.load() can handle.
    All internal names are prefixed with their module namespace.
    Cross-module references are resolved through exports/imports.
    """
    # Parse modules
    modules = {}
    for m in spec["modules"]:
        name = m["module"]
        if name in modules:
            raise ValueError(f"Duplicate module name: '{name}'")
        modules[name] = m

    compose_list = spec.get("compose", list(modules.keys()))
    for name in compose_list:
        if name not in modules:
            raise ValueError(
                f"Module '{name}' in compose list but not in modules"
            )

    # 1. Build dependency graph and topological sort
    dep_graph = {}
    for name in compose_list:
        mod = modules[name]
        deps = set()
        for imp in mod.get("imports", []):
            dep_mod = imp.rsplit(".", 1)[0]
            if dep_mod not in compose_list:
                raise ValueError(
                    f"Module '{name}' imports from '{dep_mod}' "
                    f"which is not in composition"
                )
            deps.add(dep_mod)
        dep_graph[name] = deps

    order = _topological_sort(dep_graph)

    # 2. Build export registry
    export_set = set()
    for name in order:
        mod = modules[name]
        for exp in mod.get("exports", []):
            export_set.add(f"{name}.{exp}")

    # 3. Validate imports resolve to exports
    for name in order:
        mod = modules[name]
        for imp in mod.get("imports", []):
            if imp not in export_set:
                raise ValueError(
                    f"Module '{name}' imports '{imp}' "
                    f"which is not exported"
                )

    # 4. Build unified program spec
    result = {
        "entity_types": [],
        "containers": [],
        "moves": [],
        "tensions": [],
        "pools": [],
        "transfers": [],
        "entities": [],
    }

    all_dimensions = []

    # Composition-level names (channels, entities) are NOT prefixed.
    # Add them to every module's resolve map so module tensions
    # can reference them without auto-prefixing.
    comp_names = {}
    for ch in spec.get("channels", []):
        comp_names[ch["name"]] = ch["name"]
    for ent in spec.get("entities", []):
        comp_names[ent["name"]] = ent["name"]

    for mod_name in order:
        mod = modules[mod_name]

        # Build name resolution map: local_name -> qualified_name
        # Start with composition-level names (channels)
        resolve = dict(comp_names)
        for imp in mod.get("imports", []):
            alias = imp.rsplit(".", 1)[-1]
            resolve[alias] = imp

        # --- Entity types ---
        for et in mod.get("entity_types", []):
            qual = f"{mod_name}.{et['name']}"
            resolve[et["name"]] = qual

            new_et = {"name": qual}
            if "scoped_containers" in et:
                new_et["scoped_containers"] = [
                    _resolve_scoped_container(sc, resolve, mod_name)
                    for sc in et["scoped_containers"]
                ]
            result["entity_types"].append(new_et)

        # --- Entity type extensions ---
        for ext in mod.get("entity_type_extensions", []):
            target = _resolve_name(ext["extend"], resolve, mod_name)

            target_et = None
            for ret in result["entity_types"]:
                if ret["name"] == target:
                    target_et = ret
                    break
            if target_et is None:
                raise ValueError(
                    f"Module '{mod_name}' extends '{ext['extend']}' "
                    f"-> '{target}' which doesn't exist"
                )

            if "scoped_containers" not in target_et:
                target_et["scoped_containers"] = []

            existing = {s["name"] for s in target_et["scoped_containers"]}
            for sc in ext.get("add_scoped_containers", []):
                if sc["name"] in existing:
                    raise ValueError(
                        f"Scope container '{sc['name']}' already "
                        f"exists on '{target}'"
                    )
                target_et["scoped_containers"].append(
                    _resolve_scoped_container(sc, resolve, mod_name)
                )

        # --- Dimensions ---
        for dim in mod.get("dimensions", []):
            qual_dim = f"{mod_name}.{dim}"
            all_dimensions.append(qual_dim)

        # --- Containers ---
        for c in mod.get("containers", []):
            qual = f"{mod_name}.{c['name']}"
            resolve[c["name"]] = qual

            new_c = {"name": qual}
            if "kind" in c:
                new_c["kind"] = c["kind"]
            if "entity_type" in c:
                new_c["entity_type"] = _resolve_name(
                    c["entity_type"], resolve, mod_name
                )
            if "dimension" in c:
                new_c["dimension"] = f"{mod_name}.{c['dimension']}"
            result["containers"].append(new_c)

        # --- Moves ---
        for m in mod.get("moves", []):
            qual = f"{mod_name}.{m['name']}"
            resolve[m["name"]] = qual

            new_m = {"name": qual}
            if "entity_type" in m:
                new_m["entity_type"] = _resolve_name(
                    m["entity_type"], resolve, mod_name
                )
            if "from" in m:
                new_m["from"] = [
                    _resolve_name(n, resolve, mod_name)
                    for n in m["from"]
                ]
            if "to" in m:
                new_m["to"] = [
                    _resolve_name(n, resolve, mod_name)
                    for n in m["to"]
                ]
            if "scoped_from" in m:
                new_m["scoped_from"] = m["scoped_from"]
            if "scoped_to" in m:
                new_m["scoped_to"] = m["scoped_to"]
            result["moves"].append(new_m)

        # --- Pools ---
        for p in mod.get("pools", []):
            qual = f"{mod_name}.{p['name']}"
            resolve[p["name"]] = qual
            result["pools"].append({
                "name": qual,
                "property": p["property"],
            })

        # --- Transfers ---
        for t in mod.get("transfers", []):
            qual = f"{mod_name}.{t['name']}"
            resolve[t["name"]] = qual
            new_t = {
                "name": qual,
                "pool": _resolve_name(t["pool"], resolve, mod_name),
            }
            if "entity_type" in t:
                new_t["entity_type"] = _resolve_name(
                    t["entity_type"], resolve, mod_name
                )
            result["transfers"].append(new_t)

        # --- Tensions (full name resolution) ---
        for t in mod.get("tensions", []):
            qual = f"{mod_name}.{t['name']}"
            new_t = _resolve_tension(t, qual, resolve, mod_name)
            result["tensions"].append(new_t)

    # Add dimensions
    if all_dimensions:
        result["dimensions"] = all_dimensions

    # Composition-level additions
    result["entities"].extend(spec.get("entities", []))

    for t in spec.get("tensions", []):
        result["tensions"].append(t)

    if spec.get("channels"):
        result["channels"] = spec["channels"]

    if "max_nesting_depth" in spec:
        result["max_nesting_depth"] = spec["max_nesting_depth"]

    return result


def compose_and_load(spec: dict):
    """
    Compose modules and load the result into a running HerbProgram.

    Convenience function: compose() + HerbProgram.load() in one step.
    Returns the HerbProgram instance.
    """
    from herb_program import HerbProgram
    flat_spec = compose(spec)
    program = HerbProgram(flat_spec)
    program.load()
    return program


# =============================================================================
# TOPOLOGICAL SORT
# =============================================================================

def _topological_sort(graph: Dict[str, Set[str]]) -> List[str]:
    """
    Topological sort with cycle detection (Kahn's algorithm).

    graph: node -> set of dependencies (nodes it depends on)
    Returns: list in dependency order (dependencies first)
    Raises ValueError on cycle.
    """
    in_degree = {node: len(deps) for node, deps in graph.items()}

    # Reverse edges: dep -> set of dependents
    reverse = {node: set() for node in graph}
    for node, deps in graph.items():
        for dep in deps:
            if dep not in reverse:
                reverse[dep] = set()
            reverse[dep].add(node)

    queue = sorted(n for n in graph if in_degree[n] == 0)
    result = []

    while queue:
        node = queue.pop(0)
        result.append(node)

        for dependent in sorted(reverse.get(node, [])):
            in_degree[dependent] -= 1
            if in_degree[dependent] == 0:
                queue.append(dependent)

    if len(result) != len(graph):
        remaining = set(graph.keys()) - set(result)
        raise ValueError(
            f"Circular dependency detected among modules: {remaining}"
        )

    return result


# =============================================================================
# NAME RESOLUTION HELPERS
# =============================================================================

def _resolve_name(name: str, resolve_map: dict, mod_name: str) -> str:
    """
    Resolve a name through the module's resolution map.

    If the name is an import alias or a previously-registered local name,
    return the qualified form. Otherwise prefix with module name.
    """
    if name in resolve_map:
        return resolve_map[name]
    return f"{mod_name}.{name}"


def _resolve_scoped_container(
    sc: dict,
    resolve_map: dict,
    mod_name: str
) -> dict:
    """Resolve entity_type references within a scoped container def."""
    new_sc = dict(sc)
    if "entity_type" in sc and sc["entity_type"] is not None:
        new_sc["entity_type"] = _resolve_name(
            sc["entity_type"], resolve_map, mod_name
        )
    return new_sc


def _resolve_tension(
    tension: dict,
    qualified_name: str,
    resolve_map: dict,
    mod_name: str
) -> dict:
    """
    Rewrite a tension spec with qualified names.

    Binding names (from match clauses) are preserved unchanged.
    All other names (containers, moves, entity types) are resolved.
    """
    # Collect binding names — these must NOT be resolved
    bindings = set()
    for clause in tension.get("match", []):
        if "bind" in clause:
            bindings.add(clause["bind"])

    def resolve(name):
        if name in bindings:
            return name
        return _resolve_name(name, resolve_map, mod_name)

    def resolve_ref(ref):
        if isinstance(ref, dict):
            if "scope" in ref:
                return {
                    "scope": ref["scope"],
                    "container": ref["container"],
                }
            if "channel" in ref:
                return {"channel": resolve(ref["channel"])}
            return ref
        return resolve(ref)

    def resolve_expr(expr):
        if not isinstance(expr, dict):
            return expr

        if "prop" in expr:
            return dict(expr)

        if "count" in expr:
            ref = expr["count"]
            if isinstance(ref, dict):
                if "channel" in ref:
                    return {"count": {"channel": resolve(ref["channel"])}}
                return {"count": ref}
            return {"count": resolve(ref)}

        if "in" in expr and "of" in expr:
            return {"in": resolve(expr["in"]), "of": expr["of"]}

        if "op" in expr:
            result = {"op": expr["op"]}
            if "arg" in expr:
                result["arg"] = resolve_expr(expr["arg"])
            if "left" in expr:
                result["left"] = resolve_expr(expr["left"])
            if "right" in expr:
                result["right"] = resolve_expr(expr["right"])
            return result

        return expr

    # Resolve match clauses
    new_match = []
    for clause in tension.get("match", []):
        nc = dict(clause)
        if "in" in clause:
            nc["in"] = resolve_ref(clause["in"])
        if "empty_in" in clause:
            nc["empty_in"] = [resolve(n) for n in clause["empty_in"]]
        if "container" in clause:
            nc["container"] = resolve(clause["container"])
        if "where" in clause:
            nc["where"] = resolve_expr(clause["where"])
        if "guard" in clause:
            nc["guard"] = resolve_expr(clause["guard"])
        new_match.append(nc)

    # Resolve emit clauses
    new_emit = []
    for emit in tension.get("emit", []):
        ne = dict(emit)

        if "move" in emit:
            ne["move"] = resolve(emit["move"])
            if "entity" in emit:
                ne["entity"] = resolve_ref(emit["entity"])
            if "to" in emit:
                ne["to"] = resolve_ref(emit["to"])

        elif "transfer" in emit:
            ne["transfer"] = resolve(emit["transfer"])
            if "from" in emit:
                ne["from"] = resolve_ref(emit["from"])
            if "to" in emit:
                ne["to"] = resolve_ref(emit["to"])
            if "amount" in emit:
                ne["amount"] = resolve_expr(emit["amount"])

        elif "create" in emit:
            ne["create"] = resolve(emit["create"])
            if "in" in emit:
                ne["in"] = resolve_ref(emit["in"])
            if "properties" in emit:
                ne["properties"] = {
                    k: resolve_expr(v)
                    for k, v in emit["properties"].items()
                }

        elif "set" in emit:
            ne["set"] = resolve_ref(emit["set"])
            if "value" in emit:
                ne["value"] = resolve_expr(emit["value"])

        elif "send" in emit:
            ne["send"] = resolve(emit["send"])
            if "entity" in emit:
                ne["entity"] = resolve_ref(emit["entity"])

        elif "receive" in emit:
            ne["receive"] = resolve(emit["receive"])
            if "entity" in emit:
                ne["entity"] = resolve_ref(emit["entity"])
            if "to" in emit:
                ne["to"] = resolve_ref(emit["to"])

        elif "duplicate" in emit:
            ne["duplicate"] = resolve_ref(emit["duplicate"])
            if "in" in emit:
                ne["in"] = resolve_ref(emit["in"])

        new_emit.append(ne)

    result = {
        "name": qualified_name,
        "priority": tension.get("priority", 0),
        "match": new_match,
        "emit": new_emit,
    }
    if "pair" in tension:
        result["pair"] = tension["pair"]

    return result
