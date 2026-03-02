"""
HERB Program Serialization

Converts HERB programs between Python dicts and .herb.json files.
The .herb.json format is the canonical HERB program representation.

An AI writes HERB by constructing this JSON. A runtime loads it.
No Python anywhere in the program representation.

Supports:
  - Standalone programs (entity_types, containers, moves, tensions, etc.)
  - Composition specs (compose, modules with namespaces/exports/imports)
  - Standalone modules (module key present)

Validation on load rejects malformed programs before they reach the runtime.
"""

import json
from typing import List, Any


# =============================================================================
# SERIALIZATION
# =============================================================================

def serialize(spec: dict, pretty: bool = True) -> str:
    """
    Serialize a HERB program spec to JSON string.

    Works for standalone programs, modules, and composition specs.
    The spec must contain only JSON-compatible types:
    dicts, lists, strings, numbers, booleans, None.
    """
    _check_serializable(spec)
    if pretty:
        return json.dumps(spec, indent=2, ensure_ascii=False)
    return json.dumps(spec, ensure_ascii=False)


def deserialize(json_str: str) -> dict:
    """
    Deserialize a JSON string to a HERB program spec.

    Validates the result before returning.
    Raises ValueError on invalid JSON or invalid spec.
    """
    try:
        spec = json.loads(json_str)
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON: {e}")

    if not isinstance(spec, dict):
        raise ValueError("HERB program must be a JSON object (dict)")

    errors = validate(spec)
    if errors:
        raise ValueError(
            f"Invalid HERB program ({len(errors)} errors):\n"
            + "\n".join(f"  - {e}" for e in errors)
        )

    return spec


def save(spec: dict, path: str, pretty: bool = True):
    """
    Save a HERB program spec to a .herb.json file.

    The spec can be a standalone program, composition spec, or module.
    """
    json_str = serialize(spec, pretty=pretty)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(json_str)
        f.write('\n')


def load(path: str) -> dict:
    """
    Load a HERB program spec from a .herb.json file.

    Validates the spec before returning.
    Raises ValueError on invalid JSON or invalid spec.
    """
    with open(path, 'r', encoding='utf-8') as f:
        json_str = f.read()
    return deserialize(json_str)


def load_and_run(path: str):
    """
    Load a .herb.json file and return a running HerbProgram.

    For standalone programs, loads directly.
    For composition specs, composes then loads.
    Returns the HerbProgram instance.
    """
    spec = load(path)
    return spec_to_program(spec)


def spec_to_program(spec: dict):
    """
    Convert a spec (standalone or composition) to a running HerbProgram.
    """
    from herb_program import HerbProgram

    if "compose" in spec:
        from herb_compose import compose
        flat = compose(spec)
        prog = HerbProgram(flat)
        prog.load()
        return prog
    else:
        prog = HerbProgram(spec)
        prog.load()
        return prog


# =============================================================================
# VALIDATION
# =============================================================================

def validate(spec: dict) -> List[str]:
    """
    Validate a HERB spec (program, composition, or module).

    Returns list of error messages. Empty = valid.
    Detects the spec kind from its keys and applies appropriate validation.
    """
    kind = detect_kind(spec)

    if kind == "composition":
        return _validate_composition(spec)
    elif kind == "module":
        from herb_compose import validate_module
        return validate_module(spec)
    else:
        return _validate_program(spec)


def detect_kind(spec: dict) -> str:
    """
    Detect the kind of HERB spec.

    Returns: "program", "composition", or "module"
    """
    if "compose" in spec and "modules" in spec:
        return "composition"
    if "module" in spec:
        return "module"
    return "program"


def _validate_program(spec: dict) -> List[str]:
    """Validate a standalone HERB program spec."""
    from herb_program import validate_program
    return validate_program(spec)


def _validate_composition(spec: dict) -> List[str]:
    """Validate a HERB composition spec."""
    errors = []

    if not isinstance(spec.get("compose"), list):
        errors.append("Composition 'compose' must be a list of module names")
        return errors

    if not isinstance(spec.get("modules"), list):
        errors.append("Composition 'modules' must be a list of module dicts")
        return errors

    # Validate each module
    from herb_compose import validate_module
    for i, mod in enumerate(spec["modules"]):
        if not isinstance(mod, dict):
            errors.append(f"Module {i} is not a dict")
            continue
        mod_errors = validate_module(mod)
        mod_name = mod.get("module", f"module_{i}")
        for e in mod_errors:
            errors.append(f"[{mod_name}] {e}")

    # Check compose list references valid modules
    module_names = set()
    for mod in spec["modules"]:
        if isinstance(mod, dict) and "module" in mod:
            module_names.add(mod["module"])

    for name in spec["compose"]:
        if name not in module_names:
            errors.append(
                f"Compose list references '{name}' "
                f"but no module with that name exists"
            )

    # Validate entities if present
    for e in spec.get("entities", []):
        if not isinstance(e, dict):
            errors.append("Entity must be a dict")
            continue
        if "name" not in e:
            errors.append("Entity missing 'name'")
        if "type" not in e:
            errors.append(f"Entity '{e.get('name', '?')}' missing 'type'")

    # Validate channels if present
    for ch in spec.get("channels", []):
        if not isinstance(ch, dict):
            errors.append("Channel must be a dict")
            continue
        if "name" not in ch:
            errors.append("Channel missing 'name'")
        if "from" not in ch:
            errors.append(f"Channel '{ch.get('name', '?')}' missing 'from'")
        if "to" not in ch:
            errors.append(f"Channel '{ch.get('name', '?')}' missing 'to'")

    return errors


# =============================================================================
# SERIALIZABILITY CHECK
# =============================================================================

def _check_serializable(obj: Any, path: str = "root"):
    """
    Verify that an object is JSON-serializable.

    HERB specs should only contain: dict, list, str, int, float, bool, None.
    Raises TypeError if non-serializable types are found.
    """
    if obj is None:
        return
    if isinstance(obj, (str, int, float, bool)):
        return
    if isinstance(obj, dict):
        for k, v in obj.items():
            if not isinstance(k, str):
                raise TypeError(
                    f"Dict key at {path} must be string, got {type(k).__name__}"
                )
            _check_serializable(v, f"{path}.{k}")
        return
    if isinstance(obj, (list, tuple)):
        for i, item in enumerate(obj):
            _check_serializable(item, f"{path}[{i}]")
        return
    raise TypeError(
        f"Non-serializable type at {path}: {type(obj).__name__}. "
        f"HERB specs must contain only dict, list, str, int, float, bool, None."
    )
