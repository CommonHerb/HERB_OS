#!/usr/bin/env python3
"""
HERB JSON to Source Converter

Loads interactive_kernel.herb.json, composes it via herb_compose,
converts the composed flat dict to .herb source text format.

Usage: python herb_json_to_source.py [input.herb.json [output.herb]]
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from herb_compose import compose


# ============================================================
# Expression serializer
# ============================================================

# Precedence levels (higher = binds tighter)
PREC = {
    'or': 1, '||': 1,
    'and': 2, '&&': 2,
    '==': 3, '!=': 3, '<': 3, '>': 3, '<=': 3, '>=': 3,
    '+': 4, '-': 4,
}


def _op_prec(op):
    return PREC.get(op, 0)


def _expr_to_source(expr, parent_prec=0):
    """Convert an expression dict to source text string."""
    if expr is None:
        return "0"
    if isinstance(expr, bool):
        return "true" if expr else "false"
    if isinstance(expr, int):
        return str(expr)
    if isinstance(expr, float):
        return str(expr)
    if isinstance(expr, str):
        return expr

    if isinstance(expr, dict):
        if "prop" in expr:
            return f"{expr['of']}.{expr['prop']}"

        if "count" in expr:
            count = expr["count"]
            if isinstance(count, str):
                return f"count({count})"
            elif isinstance(count, dict):
                if "scope" in count:
                    return f"count(scoped {count['scope']} {count['container']})"
                elif "channel" in count:
                    return f"count(channel {count['channel']})"
            return "count(???)"

        if "in" in expr and "of" in expr and "op" not in expr:
            return f"{expr['of']}.in({expr['in']})"

        if "op" in expr:
            op = expr["op"]
            # Map internal op names to source syntax
            src_op = op
            if op == "and":
                src_op = "&&"
            elif op == "or":
                src_op = "||"

            if op == "not":
                arg = _expr_to_source(expr.get("arg"), 99)
                return f"!{arg}"

            my_prec = _op_prec(op)
            left = _expr_to_source(expr.get("left"), my_prec)
            right = _expr_to_source(expr.get("right"), my_prec + 1)

            result = f"{left} {src_op} {right}"
            if my_prec < parent_prec:
                result = f"( {result} )"
            return result

    return "0"


# ============================================================
# Source format emitter
# ============================================================

def _in_spec_to_source(in_spec):
    """Convert an in-spec to source tokens after 'in' keyword."""
    if isinstance(in_spec, str):
        return in_spec
    elif isinstance(in_spec, dict):
        if "scope" in in_spec:
            return f"scoped {in_spec['scope']} {in_spec['container']}"
        elif "channel" in in_spec:
            return f"channel {in_spec['channel']}"
    return "???"


def _ref_to_source(ref):
    """Convert a to-ref to source tokens."""
    if ref is None:
        return None
    if isinstance(ref, str):
        return ref
    if isinstance(ref, dict):
        if "scope" in ref:
            return f"scoped {ref['scope']} {ref['container']}"
    return str(ref)


def _prop_value_to_source(v):
    """Convert a property value to source text."""
    if isinstance(v, bool):
        return str(int(v))
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return str(v)
    if isinstance(v, str):
        return f'"{v}"'
    return str(v)


def prog_to_source(prog):
    """Convert a flat composed HERB program dict to .herb source text."""
    lines = []
    lines.append("# HERB OS kernel program (generated from interactive_kernel.herb.json)")
    lines.append("")

    # --- Entity types ---
    for et in prog.get("entity_types", []):
        name = et["name"]
        scoped = et.get("scoped_containers", [])
        lines.append(f"type {name}")
        for sc in scoped:
            kind = sc.get("kind", "simple")
            etype = sc.get("entity_type", "")
            lines.append(f"  scope {sc['name']} {kind} {etype}")
        lines.append("")

    # --- Containers ---
    for c in prog.get("containers", []):
        name = c["name"]
        kind = c.get("kind", "simple")
        etype = c.get("entity_type", "")
        lines.append(f"container {name} {kind} {etype}")
    if prog.get("containers"):
        lines.append("")

    # --- Moves ---
    for m in prog.get("moves", []):
        name = m["name"]
        etype = m.get("entity_type", "")
        is_scoped = "scoped_from" in m or "scoped_to" in m
        if is_scoped:
            from_list = m.get("scoped_from", [])
            to_list = m.get("scoped_to", [])
            from_str = " ".join(from_list)
            to_str = " ".join(to_list)
            lines.append(f"move {name} {etype} scoped_from {from_str} scoped_to {to_str}")
        else:
            from_list = m.get("from", [])
            to_list = m.get("to", [])
            from_str = " ".join(from_list)
            to_str = " ".join(to_list)
            lines.append(f"move {name} {etype} from {from_str} to {to_str}")
    if prog.get("moves"):
        lines.append("")

    # --- Channels ---
    for ch in prog.get("channels", []):
        lines.append(f"channel {ch['name']} {ch['from']} {ch['to']} {ch.get('entity_type', '')}")
    if prog.get("channels"):
        lines.append("")

    # --- Config ---
    if "max_nesting_depth" in prog:
        lines.append(f"config max_nesting_depth {prog['max_nesting_depth']}")
        lines.append("")

    # --- Tensions ---
    for t in prog.get("tensions", []):
        name = t["name"]
        priority = t.get("priority", 0)
        lines.append(f"tension {name} priority {priority}")

        for mc in t.get("match", []):
            if "guard" in mc:
                expr_str = _expr_to_source(mc["guard"])
                lines.append(f"  guard {expr_str}")
                continue

            bind = mc.get("bind", "?")

            if "empty_in" in mc:
                containers = " ".join(mc["empty_in"])
                lines.append(f"  match {bind} empty_in {containers}")
                continue

            if "in" in mc:
                in_str = _in_spec_to_source(mc["in"])
                opts = ""
                sel = mc.get("select", "first")
                if sel != "first" or "select" in mc:
                    opts += f" select {sel}"
                    key = mc.get("key")
                    if key and sel in ("max_by", "min_by"):
                        opts += f" {key}"
                if mc.get("required") is False:
                    opts += " optional"
                lines.append(f"  match {bind} in {in_str}{opts}")

                if "where" in mc:
                    where_str = _expr_to_source(mc["where"])
                    lines.append(f"    where {where_str}")
                continue

            # Bare match (shouldn't happen in well-formed data)
            lines.append(f"  match {bind}")

        for ec in t.get("emit", []):
            if "move" in ec:
                move_name = ec["move"]
                entity = ec.get("entity", "?")
                to_ref = ec.get("to")
                to_str = _ref_to_source(to_ref)
                if to_str and isinstance(to_ref, dict) and "scope" in to_ref:
                    lines.append(f"  emit move {move_name} {entity} to {to_str}")
                elif to_str:
                    lines.append(f"  emit move {move_name} {entity} to {to_str}")
                else:
                    lines.append(f"  emit move {move_name} {entity}")

            elif "set" in ec:
                entity = ec["set"]
                prop = ec.get("property", "?")
                value = _expr_to_source(ec.get("value"))
                lines.append(f"  emit set {entity} {prop} {value}")

            elif "send" in ec:
                channel = ec["send"]
                entity = ec.get("entity", "?")
                lines.append(f"  emit send {channel} {entity}")

            elif "receive" in ec:
                channel = ec["receive"]
                entity = ec.get("entity", "?")
                to_ref = ec.get("to")
                to_str = _ref_to_source(to_ref)
                lines.append(f"  emit receive {channel} {entity} to {to_str}")

        lines.append("")

    # --- Entities ---
    for e in prog.get("entities", []):
        name = e["name"]
        etype = e["type"]
        in_spec = e.get("in")
        in_str = _in_spec_to_source(in_spec) if in_spec else "???"
        lines.append(f"entity {name} {etype} in {in_str}")

        props = e.get("properties", {})
        for k, v in props.items():
            val_str = _prop_value_to_source(v)
            lines.append(f"  prop {k} {val_str}")

    # Ensure trailing newline
    text = "\n".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    return text


# ============================================================
# Main
# ============================================================

def main():
    src_dir = os.path.dirname(os.path.abspath(__file__))
    programs_dir = os.path.join(src_dir, '..', 'programs')

    if len(sys.argv) >= 2:
        input_path = sys.argv[1]
    else:
        input_path = os.path.join(programs_dir, 'interactive_kernel.herb.json')

    if len(sys.argv) >= 3:
        output_path = sys.argv[2]
    else:
        output_path = os.path.join(programs_dir, 'interactive_kernel.herb')

    with open(input_path) as f:
        prog = json.load(f)

    # Compose if multi-module
    if "compose" in prog:
        prog = compose(prog)

    source = prog_to_source(prog)

    with open(output_path, 'w', newline='\n') as f:
        f.write(source)

    print(f"Generated {output_path}")
    print(f"  {len(source):,} bytes, {source.count(chr(10)):,} lines")

    # Quick stats
    et_count = len(prog.get("entity_types", []))
    ct_count = len(prog.get("containers", []))
    mv_count = len(prog.get("moves", []))
    en_count = len(prog.get("entities", []))
    ch_count = len(prog.get("channels", []))
    tn_count = len(prog.get("tensions", []))
    print(f"  {et_count} entity types, {ct_count} containers, {mv_count} moves")
    print(f"  {en_count} entities, {ch_count} channels, {tn_count} tensions")


if __name__ == "__main__":
    main()
