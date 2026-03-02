#!/usr/bin/env python3
"""
HERB Binary Compiler — .herb.json → .herb

Compiles a HERB program from JSON representation to native binary format.
Every byte has HERB semantics. No general-purpose serialization.

Usage: python herb_compile.py input.herb.json output.herb
"""

import json
import struct
import sys
import os

# ============================================================
# BINARY FORMAT CONSTANTS
# ============================================================

# Section tags
SEC_ENTITY_TYPES = 0x01
SEC_CONTAINERS   = 0x02
SEC_MOVES        = 0x03
SEC_POOLS        = 0x04
SEC_TRANSFERS    = 0x05
SEC_ENTITIES     = 0x06
SEC_CHANNELS     = 0x07
SEC_CONFIG       = 0x08
SEC_TENSIONS     = 0x09
SEC_END          = 0xFF

# Expression kinds
EX_INT             = 0x00
EX_FLOAT           = 0x01
EX_STRING          = 0x02
EX_BOOL            = 0x03
EX_PROP            = 0x04
EX_COUNT_CONTAINER = 0x05
EX_COUNT_SCOPED    = 0x06
EX_COUNT_CHANNEL   = 0x07
EX_BINARY          = 0x08
EX_UNARY_NOT       = 0x09
EX_IN_OF           = 0x0A
EX_NULL            = 0xFF

# Match clause kinds
MC_ENTITY_IN    = 0x00
MC_EMPTY_IN     = 0x01
MC_CONTAINER_IS = 0x02
MC_GUARD        = 0x03

# Emit clause kinds
EC_MOVE      = 0x00
EC_SET       = 0x01
EC_SEND      = 0x02
EC_RECEIVE   = 0x03
EC_TRANSFER  = 0x04
EC_DUPLICATE = 0x05

# Select modes
SEL_FIRST  = 0
SEL_EACH   = 1
SEL_MAX_BY = 2
SEL_MIN_BY = 3

# Target reference kinds
REF_NORMAL = 0x00
REF_SCOPED = 0x01
REF_NONE   = 0x02

# Container kinds
CK_SIMPLE = 0
CK_SLOT   = 1

# Sentinel for "no string"
NONE_IDX = 0xFFFF


class HerbCompiler:
    def __init__(self):
        self.strings = []
        self.string_map = {}
        self.buf = bytearray()

    # ---- String table ----

    def add_string(self, s):
        """Add a string to the table, return its index. None maps to NONE_IDX."""
        if s is None:
            return NONE_IDX
        if s not in self.string_map:
            self.string_map[s] = len(self.strings)
            self.strings.append(s)
        return self.string_map[s]

    def collect_strings(self, prog):
        """Walk the entire program and pre-collect all unique strings."""
        for et in prog.get("entity_types", []):
            self.add_string(et["name"])
            for sc in et.get("scoped_containers", []):
                self.add_string(sc["name"])
                self.add_string(sc.get("entity_type"))

        for c in prog.get("containers", []):
            self.add_string(c["name"])
            self.add_string(c.get("entity_type"))

        for m in prog.get("moves", []):
            self.add_string(m["name"])
            self.add_string(m.get("entity_type"))
            for f in m.get("from", []):      self.add_string(f)
            for t in m.get("to", []):        self.add_string(t)
            for f in m.get("scoped_from", []): self.add_string(f)
            for t in m.get("scoped_to", []):   self.add_string(t)

        for p in prog.get("pools", []):
            self.add_string(p["name"])
            self.add_string(p["property"])

        for t in prog.get("transfers", []):
            self.add_string(t["name"])
            self.add_string(t.get("pool"))
            self.add_string(t.get("entity_type"))

        for ch in prog.get("channels", []):
            self.add_string(ch["name"])
            self.add_string(ch["from"])
            self.add_string(ch["to"])
            self.add_string(ch.get("entity_type"))

        for t in prog.get("tensions", []):
            self.add_string(t["name"])
            for mc in t.get("match", []):  self._collect_match_strings(mc)
            for ec in t.get("emit", []):   self._collect_emit_strings(ec)

        for e in prog.get("entities", []):
            self.add_string(e["name"])
            self.add_string(e["type"])
            in_spec = e.get("in")
            if isinstance(in_spec, str):
                self.add_string(in_spec)
            elif isinstance(in_spec, dict):
                self.add_string(in_spec.get("scope"))
                self.add_string(in_spec.get("container"))
            for k, v in e.get("properties", {}).items():
                self.add_string(k)
                if isinstance(v, str):
                    self.add_string(v)

    def _collect_match_strings(self, mc):
        self.add_string(mc.get("bind"))
        if "guard" in mc:
            self._collect_expr_strings(mc["guard"])
        self.add_string(mc.get("container"))
        in_spec = mc.get("in")
        if isinstance(in_spec, str):
            self.add_string(in_spec)
        elif isinstance(in_spec, dict):
            self.add_string(in_spec.get("scope"))
            self.add_string(in_spec.get("container"))
            self.add_string(in_spec.get("channel"))
        if "empty_in" in mc:
            for c in mc["empty_in"]:
                self.add_string(c)
        self.add_string(mc.get("key"))
        if "where" in mc:
            self._collect_expr_strings(mc["where"])

    def _collect_emit_strings(self, ec):
        if "move" in ec:
            self.add_string(ec["move"])
            self.add_string(ec.get("entity"))
            self._collect_ref_strings(ec.get("to"))
        elif "set" in ec:
            self.add_string(ec["set"])
            self.add_string(ec.get("property"))
            self._collect_expr_strings(ec.get("value"))
        elif "send" in ec:
            self.add_string(ec["send"])
            self.add_string(ec.get("entity"))
        elif "receive" in ec:
            self.add_string(ec["receive"])
            self.add_string(ec.get("entity"))
            self._collect_ref_strings(ec.get("to"))
        elif "transfer" in ec:
            self.add_string(ec["transfer"])
            self.add_string(ec.get("from"))
            self.add_string(ec.get("to"))
            self._collect_expr_strings(ec.get("amount"))
        elif "duplicate" in ec:
            self.add_string(ec["duplicate"])
            self._collect_ref_strings(ec.get("in"))

    def _collect_ref_strings(self, ref):
        if ref is None: return
        if isinstance(ref, str):
            self.add_string(ref)
        elif isinstance(ref, dict):
            self.add_string(ref.get("scope"))
            self.add_string(ref.get("container"))

    def _collect_expr_strings(self, expr):
        if expr is None or isinstance(expr, (int, float, bool)): return
        if isinstance(expr, str):
            self.add_string(expr)
            return
        if isinstance(expr, dict):
            if "prop" in expr:
                self.add_string(expr["prop"])
                self.add_string(expr.get("of"))
            elif "count" in expr:
                count = expr["count"]
                if isinstance(count, str):
                    self.add_string(count)
                elif isinstance(count, dict):
                    self.add_string(count.get("scope"))
                    self.add_string(count.get("container"))
                    self.add_string(count.get("channel"))
            elif "in" in expr and "of" in expr and "op" not in expr:
                self.add_string(expr["in"])
                self.add_string(expr["of"])
            elif "op" in expr:
                self.add_string(expr["op"])
                self._collect_expr_strings(expr.get("arg"))
                self._collect_expr_strings(expr.get("left"))
                self._collect_expr_strings(expr.get("right"))

    # ---- Binary writers ----

    def w_u8(self, v):  self.buf += struct.pack('<B', v & 0xFF)
    def w_u16(self, v): self.buf += struct.pack('<H', v & 0xFFFF)
    def w_i16(self, v): self.buf += struct.pack('<h', v)
    def w_i64(self, v): self.buf += struct.pack('<q', v)
    def w_f64(self, v): self.buf += struct.pack('<d', v)

    def write_expr(self, expr):
        """Write an expression tree inline (recursive encoding)."""
        if expr is None:
            self.w_u8(EX_NULL)
            return

        if isinstance(expr, bool):
            self.w_u8(EX_BOOL)
            self.w_u8(1 if expr else 0)
            return
        if isinstance(expr, int):
            self.w_u8(EX_INT)
            self.w_i64(expr)
            return
        if isinstance(expr, float):
            self.w_u8(EX_FLOAT)
            self.w_f64(expr)
            return
        if isinstance(expr, str):
            self.w_u8(EX_STRING)
            self.w_u16(self.add_string(expr))
            return

        if isinstance(expr, dict):
            if "prop" in expr:
                self.w_u8(EX_PROP)
                self.w_u16(self.add_string(expr["prop"]))
                self.w_u16(self.add_string(expr.get("of")))
                return
            if "count" in expr:
                count = expr["count"]
                if isinstance(count, str):
                    self.w_u8(EX_COUNT_CONTAINER)
                    self.w_u16(self.add_string(count))
                elif isinstance(count, dict):
                    if "scope" in count:
                        self.w_u8(EX_COUNT_SCOPED)
                        self.w_u16(self.add_string(count["scope"]))
                        self.w_u16(self.add_string(count.get("container")))
                    elif "channel" in count:
                        self.w_u8(EX_COUNT_CHANNEL)
                        self.w_u16(self.add_string(count["channel"]))
                return
            if "in" in expr and "of" in expr and "op" not in expr:
                self.w_u8(EX_IN_OF)
                self.w_u16(self.add_string(expr["in"]))
                self.w_u16(self.add_string(expr["of"]))
                return
            if "op" in expr:
                if expr["op"] == "not":
                    self.w_u8(EX_UNARY_NOT)
                    self.write_expr(expr.get("arg"))
                else:
                    self.w_u8(EX_BINARY)
                    self.w_u16(self.add_string(expr["op"]))
                    self.write_expr(expr.get("left"))
                    self.write_expr(expr.get("right"))
                return

        self.w_u8(EX_NULL)

    def write_to_ref(self, ref):
        """Write a target reference (normal string, scoped, or none)."""
        if ref is None:
            self.w_u8(REF_NONE)
        elif isinstance(ref, str):
            self.w_u8(REF_NORMAL)
            self.w_u16(self.add_string(ref))
        elif isinstance(ref, dict):
            self.w_u8(REF_SCOPED)
            self.w_u16(self.add_string(ref.get("scope")))
            self.w_u16(self.add_string(ref.get("container")))
        else:
            self.w_u8(REF_NONE)

    def _write_match(self, mc):
        """Write a single match clause."""
        if "guard" in mc:
            self.w_u8(MC_GUARD)
            self.write_expr(mc["guard"])
            return

        if "container" in mc and "is" in mc:
            self.w_u8(MC_CONTAINER_IS)
            self.w_u16(self.add_string(mc["container"]))
            self.w_u8(1 if mc["is"] == "empty" else 0)
            return

        if "in" in mc:
            self.w_u8(MC_ENTITY_IN)
            self.w_u16(self.add_string(mc.get("bind")))
            self.w_u8(1 if mc.get("required", True) else 0)
            sel = mc.get("select", "first")
            self.w_u8({"first": SEL_FIRST, "each": SEL_EACH,
                        "max_by": SEL_MAX_BY, "min_by": SEL_MIN_BY}.get(sel, SEL_FIRST))
            self.w_u16(self.add_string(mc.get("key")))
            in_spec = mc["in"]
            if isinstance(in_spec, str):
                self.w_u8(0)  # normal
                self.w_u16(self.add_string(in_spec))
            elif isinstance(in_spec, dict):
                if "scope" in in_spec:
                    self.w_u8(1)  # scoped
                    self.w_u16(self.add_string(in_spec["scope"]))
                    self.w_u16(self.add_string(in_spec["container"]))
                elif "channel" in in_spec:
                    self.w_u8(2)  # channel
                    self.w_u16(self.add_string(in_spec["channel"]))
            where = mc.get("where")
            if where is not None:
                self.w_u8(1)
                self.write_expr(where)
            else:
                self.w_u8(0)
            return

        if "empty_in" in mc:
            self.w_u8(MC_EMPTY_IN)
            self.w_u16(self.add_string(mc.get("bind")))
            sel = mc.get("select", "first")
            self.w_u8(SEL_EACH if sel == "each" else SEL_FIRST)
            containers = mc["empty_in"]
            self.w_u8(len(containers))
            for c in containers:
                self.w_u16(self.add_string(c))
            return

    def _write_emit(self, ec):
        """Write a single emit clause."""
        if "move" in ec:
            self.w_u8(EC_MOVE)
            self.w_u16(self.add_string(ec["move"]))
            self.w_u16(self.add_string(ec.get("entity")))
            self.write_to_ref(ec.get("to"))
            return

        if "set" in ec:
            self.w_u8(EC_SET)
            self.w_u16(self.add_string(ec["set"]))
            self.w_u16(self.add_string(ec.get("property")))
            self.write_expr(ec.get("value"))
            return

        if "send" in ec:
            self.w_u8(EC_SEND)
            self.w_u16(self.add_string(ec["send"]))
            self.w_u16(self.add_string(ec.get("entity")))
            return

        if "receive" in ec:
            self.w_u8(EC_RECEIVE)
            self.w_u16(self.add_string(ec["receive"]))
            self.w_u16(self.add_string(ec.get("entity")))
            self.write_to_ref(ec.get("to"))
            return

        if "transfer" in ec:
            self.w_u8(EC_TRANSFER)
            self.w_u16(self.add_string(ec["transfer"]))
            self.w_u16(self.add_string(ec.get("from")))
            self.w_u16(self.add_string(ec.get("to")))
            self.write_expr(ec.get("amount"))
            return

        if "duplicate" in ec:
            self.w_u8(EC_DUPLICATE)
            self.w_u16(self.add_string(ec["duplicate"]))
            self.write_to_ref(ec.get("in"))
            return

    # ---- Main compile ----

    def compile(self, prog):
        """Compile a flat HERB program dict to binary bytes."""
        # Phase 1: Collect all strings
        self.collect_strings(prog)

        # Phase 2: Header (8 bytes)
        self.buf += b'HERB'              # magic
        self.w_u8(1)                     # version
        self.w_u8(0)                     # flags (reserved)
        self.w_u16(len(self.strings))    # string count

        # Phase 3: String table
        for s in self.strings:
            encoded = s.encode('utf-8')
            if len(encoded) > 255:
                encoded = encoded[:255]
            self.w_u8(len(encoded))
            self.buf += encoded

        # Phase 4: Sections (ORDER MATTERS — dependencies must be loaded first)
        # Order: entity_types, containers, moves, pools, transfers,
        #        entities, channels, config, tensions

        # --- Entity types ---
        entity_types = prog.get("entity_types", [])
        self.w_u8(SEC_ENTITY_TYPES)
        self.w_u16(len(entity_types))
        for et in entity_types:
            self.w_u16(self.add_string(et["name"]))
            scoped = et.get("scoped_containers", [])
            self.w_u8(len(scoped))
            for sc in scoped:
                self.w_u16(self.add_string(sc["name"]))
                self.w_u8(CK_SLOT if sc.get("kind") == "slot" else CK_SIMPLE)
                self.w_u16(self.add_string(sc.get("entity_type")))

        # --- Containers ---
        containers = prog.get("containers", [])
        self.w_u8(SEC_CONTAINERS)
        self.w_u16(len(containers))
        for c in containers:
            self.w_u16(self.add_string(c["name"]))
            self.w_u8(CK_SLOT if c.get("kind") == "slot" else CK_SIMPLE)
            self.w_u16(self.add_string(c.get("entity_type")))

        # --- Moves ---
        moves = prog.get("moves", [])
        self.w_u8(SEC_MOVES)
        self.w_u16(len(moves))
        for m in moves:
            self.w_u16(self.add_string(m["name"]))
            self.w_u16(self.add_string(m.get("entity_type")))
            is_scoped = "scoped_from" in m or "scoped_to" in m
            self.w_u8(1 if is_scoped else 0)
            if is_scoped:
                from_list = m.get("scoped_from", [])
                to_list = m.get("scoped_to", [])
            else:
                from_list = m.get("from", [])
                to_list = m.get("to", [])
            self.w_u8(len(from_list))
            for f in from_list: self.w_u16(self.add_string(f))
            self.w_u8(len(to_list))
            for t in to_list: self.w_u16(self.add_string(t))

        # --- Pools ---
        pools = prog.get("pools", [])
        self.w_u8(SEC_POOLS)
        self.w_u16(len(pools))
        for p in pools:
            self.w_u16(self.add_string(p["name"]))
            self.w_u16(self.add_string(p["property"]))

        # --- Transfers ---
        transfers = prog.get("transfers", [])
        self.w_u8(SEC_TRANSFERS)
        self.w_u16(len(transfers))
        for t in transfers:
            self.w_u16(self.add_string(t["name"]))
            self.w_u16(self.add_string(t.get("pool")))
            self.w_u16(self.add_string(t.get("entity_type")))

        # --- Entities (before channels — channels reference entity names) ---
        entities = prog.get("entities", [])
        self.w_u8(SEC_ENTITIES)
        self.w_u16(len(entities))
        for e in entities:
            self.w_u16(self.add_string(e["name"]))
            self.w_u16(self.add_string(e["type"]))
            in_spec = e.get("in")
            if isinstance(in_spec, str):
                self.w_u8(0)  # normal
                self.w_u16(self.add_string(in_spec))
            elif isinstance(in_spec, dict):
                self.w_u8(1)  # scoped
                self.w_u16(self.add_string(in_spec["scope"]))
                self.w_u16(self.add_string(in_spec["container"]))
            else:
                self.w_u8(0)
                self.w_u16(NONE_IDX)
            props = e.get("properties", {})
            self.w_u8(len(props))
            for k, v in props.items():
                self.w_u16(self.add_string(k))
                if isinstance(v, bool):
                    self.w_u8(0); self.w_i64(1 if v else 0)
                elif isinstance(v, int):
                    self.w_u8(0); self.w_i64(v)
                elif isinstance(v, float):
                    self.w_u8(1); self.w_f64(v)
                elif isinstance(v, str):
                    self.w_u8(2); self.w_u16(self.add_string(v))

        # --- Channels (after entities) ---
        channels = prog.get("channels", [])
        self.w_u8(SEC_CHANNELS)
        self.w_u16(len(channels))
        for ch in channels:
            self.w_u16(self.add_string(ch["name"]))
            self.w_u16(self.add_string(ch["from"]))
            self.w_u16(self.add_string(ch["to"]))
            self.w_u16(self.add_string(ch.get("entity_type")))

        # --- Config ---
        self.w_u8(SEC_CONFIG)
        self.w_i16(prog.get("max_nesting_depth", -1))

        # --- Tensions (last — references everything else) ---
        tensions = prog.get("tensions", [])
        self.w_u8(SEC_TENSIONS)
        self.w_u16(len(tensions))
        for t in tensions:
            self.w_u16(self.add_string(t["name"]))
            self.w_i16(t.get("priority", 0))
            pair = t.get("pair", "zip")
            self.w_u8(1 if pair == "cross" else 0)
            matches = t.get("match", [])
            self.w_u8(len(matches))
            for mc in matches:
                self._write_match(mc)
            emits = t.get("emit", [])
            self.w_u8(len(emits))
            for ec in emits:
                self._write_emit(ec)

        # --- End marker ---
        self.w_u8(SEC_END)

        return bytes(self.buf)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.herb.json> <output.herb>", file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]

    with open(input_path) as f:
        prog = json.load(f)

    if "compose" in prog:
        # Compose first, then compile the flat result
        try:
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            from herb_compose import compose
            prog = compose(prog)
        except ImportError:
            print("Error: composed programs require herb_compose.py", file=sys.stderr)
            sys.exit(1)

    compiler = HerbCompiler()
    binary = compiler.compile(prog)

    with open(output_path, 'wb') as f:
        f.write(binary)

    json_size = os.path.getsize(input_path)
    bin_size = len(binary)
    print(f"Compiled {input_path} -> {output_path}")
    print(f"  JSON size:   {json_size:,} bytes")
    print(f"  Binary size: {bin_size:,} bytes")
    print(f"  Strings:     {len(compiler.strings)}")
    print(f"  Reduction:   {(1 - bin_size/json_size)*100:.0f}%")


if __name__ == "__main__":
    main()
