#!/usr/bin/env python3
"""
HERB Source Format Verification

Parses .herb source files, converts to JSON dict, compiles with HerbCompiler,
and diffs against Python-compiled .herb binary to validate byte-identical output.

Usage: python herb_source_verify.py [program_name ...]
  If no names given, verifies all programs with both .herb and .herb.json.
"""

import sys
import os
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from herb_compile import HerbCompiler


# ============================================================
# Expression Parser (recursive descent with precedence)
# ============================================================

class ExprParser:
    """Parses token list into expression dict matching .herb.json format."""

    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0

    def parse(self):
        expr = self._or_expr()
        return expr

    def _peek(self):
        if self.pos < len(self.tokens):
            return self.tokens[self.pos]
        return None

    def _advance(self):
        tok = self.tokens[self.pos]
        self.pos += 1
        return tok

    def _or_expr(self):
        left = self._and_expr()
        while self._peek() == '||':
            self._advance()
            right = self._and_expr()
            left = {"op": "or", "left": left, "right": right}
        return left

    def _and_expr(self):
        left = self._cmp_expr()
        while self._peek() == '&&':
            self._advance()
            right = self._cmp_expr()
            left = {"op": "and", "left": left, "right": right}
        return left

    def _cmp_expr(self):
        left = self._add_expr()
        if self._peek() in ('==', '!=', '<', '>', '<=', '>='):
            op = self._advance()
            right = self._add_expr()
            left = {"op": op, "left": left, "right": right}
        return left

    def _add_expr(self):
        left = self._primary()
        while self._peek() in ('+', '-'):
            op = self._advance()
            right = self._primary()
            left = {"op": op, "left": left, "right": right}
        return left

    def _primary(self):
        tok = self._peek()
        if tok is None:
            raise SyntaxError("Unexpected end of expression")

        # Parenthesized expression
        if tok == '(':
            self._advance()
            expr = self._or_expr()
            if self._peek() == ')':
                self._advance()
            return expr

        # count(container) or count(scoped ...) or count(channel ...)
        if tok.startswith('count(') and tok.endswith(')'):
            self._advance()
            inner = tok[6:-1]
            if inner.startswith('scoped '):
                parts = inner.split()
                return {"count": {"scope": parts[1], "container": parts[2]}}
            elif inner.startswith('channel '):
                parts = inner.split()
                return {"count": {"channel": parts[1]}}
            return {"count": inner}

        # Integer literal (including negative)
        try:
            val = int(tok)
            self._advance()
            return val
        except ValueError:
            pass

        # Property reference: bind.prop
        if '.' in tok:
            self._advance()
            dot = tok.index('.')
            of_name = tok[:dot]
            prop_name = tok[dot + 1:]
            return {"prop": prop_name, "of": of_name}

        # Bare identifier (shouldn't happen in well-formed expressions)
        self._advance()
        return tok


# ============================================================
# .herb Source Parser (full program support)
# ============================================================

class HerbSourceParser:
    """Parses .herb source format into JSON dict for HerbCompiler."""

    def __init__(self, text):
        self.lines = text.split('\n')
        self.pos = 0

    def parse(self):
        """Parse entire source file, return JSON dict."""
        prog = {
            "entity_types": [],
            "containers": [],
            "moves": [],
            "tensions": [],
            "entities": [],
        }
        while self.pos < len(self.lines):
            line = self.lines[self.pos]
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                self.pos += 1
                continue
            indent = self._indent(line)
            if indent == 0:
                tokens = stripped.split()
                kw = tokens[0]
                if kw == 'tension':
                    prog["tensions"].append(self._parse_tension(tokens))
                elif kw == 'type':
                    prog["entity_types"].append(self._parse_type(tokens))
                elif kw == 'container':
                    prog["containers"].append(self._parse_container(tokens))
                elif kw == 'move':
                    prog["moves"].append(self._parse_move(tokens))
                elif kw == 'entity':
                    prog["entities"].append(self._parse_entity(tokens))
                elif kw == 'channel':
                    ch = self._parse_channel(tokens)
                    if "channels" not in prog:
                        prog["channels"] = []
                    prog["channels"].append(ch)
                    self.pos += 1
                elif kw == 'config':
                    self._parse_config(tokens, prog)
                    self.pos += 1
                else:
                    self.pos += 1
            else:
                self.pos += 1
        # Remove empty keys to match fragment behavior
        for key in list(prog.keys()):
            if isinstance(prog[key], list) and len(prog[key]) == 0 and key != "tensions":
                del prog[key]
        return prog

    def _indent(self, line):
        """Count leading spaces, divide by 2."""
        spaces = len(line) - len(line.lstrip(' '))
        return spaces // 2

    def _parse_type(self, tokens):
        """Parse: type <name> with optional scope sub-lines."""
        name = tokens[1]
        et = {"name": name}
        self.pos += 1

        scoped = []
        while self.pos < len(self.lines):
            line = self.lines[self.pos]
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                self.pos += 1
                continue
            indent = self._indent(line)
            if indent == 0:
                break
            if indent == 1:
                sub_tokens = stripped.split()
                if sub_tokens[0] == 'scope':
                    sc = {"name": sub_tokens[1], "kind": sub_tokens[2]}
                    if len(sub_tokens) > 3:
                        sc["entity_type"] = sub_tokens[3]
                    scoped.append(sc)
            self.pos += 1

        if scoped:
            et["scoped_containers"] = scoped
        return et

    def _parse_container(self, tokens):
        """Parse: container <name> <kind> <entity_type>"""
        c = {"name": tokens[1], "kind": tokens[2]}
        if len(tokens) > 3:
            c["entity_type"] = tokens[3]
        self.pos += 1
        return c

    def _parse_move(self, tokens):
        """Parse: move <name> <etype> from/scoped_from ..."""
        m = {"name": tokens[1]}
        if len(tokens) > 2:
            m["entity_type"] = tokens[2]

        # Find from/to keywords
        i = 3
        if i < len(tokens) and tokens[i] == 'from':
            i += 1
            from_list = []
            while i < len(tokens) and tokens[i] != 'to':
                from_list.append(tokens[i])
                i += 1
            m["from"] = from_list
            if i < len(tokens) and tokens[i] == 'to':
                i += 1
                to_list = []
                while i < len(tokens):
                    to_list.append(tokens[i])
                    i += 1
                m["to"] = to_list
        elif i < len(tokens) and tokens[i] == 'scoped_from':
            i += 1
            from_list = []
            while i < len(tokens) and tokens[i] != 'scoped_to':
                from_list.append(tokens[i])
                i += 1
            m["scoped_from"] = from_list
            if i < len(tokens) and tokens[i] == 'scoped_to':
                i += 1
                to_list = []
                while i < len(tokens):
                    to_list.append(tokens[i])
                    i += 1
                m["scoped_to"] = to_list

        self.pos += 1
        return m

    def _parse_entity(self, tokens):
        """Parse: entity <name> <type> in [scoped <scope>] <container>
        with optional prop sub-lines."""
        e = {"name": tokens[1], "type": tokens[2]}

        # Parse in-spec
        if len(tokens) > 3 and tokens[3] == 'in':
            if len(tokens) > 4 and tokens[4] == 'scoped':
                e["in"] = {"scope": tokens[5], "container": tokens[6]}
            else:
                e["in"] = tokens[4]

        self.pos += 1

        # Parse properties
        props = {}
        while self.pos < len(self.lines):
            line = self.lines[self.pos]
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                self.pos += 1
                continue
            indent = self._indent(line)
            if indent == 0:
                break
            if indent == 1:
                sub_tokens = self._tokenize_line(stripped)
                if sub_tokens[0] == 'prop':
                    key = sub_tokens[1]
                    val_str = sub_tokens[2]
                    # Detect type
                    if val_str.startswith('"') and val_str.endswith('"'):
                        props[key] = val_str[1:-1]
                    else:
                        try:
                            props[key] = int(val_str)
                        except ValueError:
                            try:
                                props[key] = float(val_str)
                            except ValueError:
                                props[key] = val_str
            self.pos += 1

        if props:
            e["properties"] = props
        return e

    def _tokenize_line(self, line):
        """Tokenize a line, handling quoted strings."""
        tokens = []
        i = 0
        while i < len(line):
            if line[i] == ' ' or line[i] == '\t':
                i += 1
                continue
            if line[i] == '"':
                # Quoted string — find closing quote
                j = i + 1
                while j < len(line) and line[j] != '"':
                    j += 1
                # Include quotes in token so caller can detect string type
                tokens.append(line[i:j + 1])
                i = j + 1
            else:
                j = i
                while j < len(line) and line[j] != ' ' and line[j] != '\t':
                    j += 1
                tokens.append(line[i:j])
                i = j
        return tokens

    def _parse_channel(self, tokens):
        """Parse: channel <name> <from> <to> <entity_type>"""
        ch = {"name": tokens[1], "from": tokens[2], "to": tokens[3]}
        if len(tokens) > 4:
            ch["entity_type"] = tokens[4]
        return ch

    def _parse_config(self, tokens, prog):
        """Parse: config <key> <value>"""
        if tokens[1] == 'max_nesting_depth':
            prog["max_nesting_depth"] = int(tokens[2])

    def _parse_tension(self, tokens):
        """Parse tension declaration and its body."""
        # tension <name> priority <N>
        name = tokens[1]
        priority = 0
        if len(tokens) >= 4 and tokens[2] == 'priority':
            priority = int(tokens[3])

        tension = {"name": name, "priority": priority, "match": [], "emit": []}
        self.pos += 1

        while self.pos < len(self.lines):
            line = self.lines[self.pos]
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                self.pos += 1
                continue
            indent = self._indent(line)
            if indent == 0:
                break  # Next top-level entry
            if indent == 1:
                tokens = stripped.split()
                if tokens[0] == 'match':
                    tension["match"].append(self._parse_match(tokens))
                elif tokens[0] == 'emit':
                    tension["emit"].append(self._parse_emit(tokens))
                elif tokens[0] == 'guard':
                    expr = self._parse_expr_from_tokens(tokens[1:])
                    tension["match"].append({"guard": expr})
                    self.pos += 1
                else:
                    self.pos += 1
            elif indent >= 2:
                # Stray indented line (where already consumed by _parse_match)
                self.pos += 1
            else:
                self.pos += 1

        return tension

    def _parse_match(self, tokens):
        """Parse a match clause. tokens[0] is 'match'."""
        bind = tokens[1]

        if len(tokens) > 3 and tokens[2] == 'empty_in':
            # match <bind> empty_in <container1> [<container2> ...]
            containers = tokens[3:]
            self.pos += 1
            return {"bind": bind, "empty_in": containers}

        if len(tokens) > 3 and tokens[2] == 'in':
            # Determine in-spec type
            if tokens[3] == 'scoped':
                # match <bind> in scoped <scope> <container> [select ...]
                in_spec = {"scope": tokens[4], "container": tokens[5]}
                match = {"bind": bind, "in": in_spec}
                i = 6
            elif tokens[3] == 'channel':
                # match <bind> in channel <channel_name> [select ...]
                in_spec = {"channel": tokens[4]}
                match = {"bind": bind, "in": in_spec}
                i = 5
            else:
                # match <bind> in <container> [select <mode> [<key>]] [optional]
                match = {"bind": bind, "in": tokens[3]}
                i = 4

            while i < len(tokens):
                if tokens[i] == 'select':
                    match["select"] = tokens[i + 1]
                    i += 2
                    if match["select"] in ("max_by", "min_by") and i < len(tokens):
                        match["key"] = tokens[i]
                        i += 1
                elif tokens[i] == 'optional':
                    match["required"] = False
                    i += 1
                else:
                    i += 1

            self.pos += 1

            # Check for where clause on next line (indent 2)
            if self.pos < len(self.lines):
                next_line = self.lines[self.pos]
                next_stripped = next_line.strip()
                if (next_stripped
                        and self._indent(next_line) >= 2
                        and next_stripped.startswith('where ')):
                    expr_tokens = next_stripped.split()[1:]
                    match["where"] = self._parse_expr_from_tokens(expr_tokens)
                    self.pos += 1

            return match

        # Fallback
        self.pos += 1
        return {"bind": bind}

    def _parse_emit(self, tokens):
        """Parse an emit clause. tokens[0] is 'emit'."""
        kind = tokens[1]
        self.pos += 1

        if kind == 'move':
            # emit move <move_name> <entity> to [scoped <scope>] <target>
            move_name = tokens[2]
            entity = tokens[3]
            to_idx = tokens.index('to', 4)
            if to_idx + 1 < len(tokens) and tokens[to_idx + 1] == 'scoped':
                to_ref = {"scope": tokens[to_idx + 2], "container": tokens[to_idx + 3]}
            else:
                to_ref = tokens[to_idx + 1]
            return {"move": move_name, "entity": entity, "to": to_ref}

        if kind == 'set':
            # emit set <entity> <property> <expression>
            entity = tokens[2]
            prop = tokens[3]
            expr_tokens = tokens[4:]
            value = self._parse_expr_from_tokens(expr_tokens)
            return {"set": entity, "property": prop, "value": value}

        if kind == 'send':
            # emit send <channel> <entity>
            return {"send": tokens[2], "entity": tokens[3]}

        if kind == 'receive':
            # emit receive <channel> <entity> to [scoped <scope>] <container>
            channel = tokens[2]
            entity = tokens[3]
            to_idx = tokens.index('to', 4)
            if to_idx + 1 < len(tokens) and tokens[to_idx + 1] == 'scoped':
                to_ref = {"scope": tokens[to_idx + 2], "container": tokens[to_idx + 3]}
            else:
                to_ref = tokens[to_idx + 1]
            return {"receive": channel, "entity": entity, "to": to_ref}

        raise SyntaxError(f"Unknown emit kind: {kind}")

    def _parse_expr_from_tokens(self, tokens):
        """Parse an expression from a list of token strings."""
        parser = ExprParser(tokens)
        return parser.parse()


# ============================================================
# Verification
# ============================================================

def verify_program(name, programs_dir):
    """Verify that .herb source compiles to byte-identical binary as .herb.json."""
    source_path = os.path.join(programs_dir, f"{name}.herb")
    json_path = os.path.join(programs_dir, f"{name}.herb.json")

    if not os.path.exists(source_path):
        print(f"  SKIP {name}: no .herb source file")
        return False
    if not os.path.exists(json_path):
        print(f"  SKIP {name}: no .herb.json file")
        return False

    # Compile from JSON (reference)
    with open(json_path) as f:
        json_prog = json.load(f)

    # If multi-module, compose first
    if "compose" in json_prog:
        from herb_compose import compose
        json_prog = compose(json_prog)

    ref_compiler = HerbCompiler()
    ref_binary = ref_compiler.compile(json_prog)

    # Parse source and compile
    with open(source_path) as f:
        source_text = f.read()
    parser = HerbSourceParser(source_text)
    src_prog = parser.parse()
    src_compiler = HerbCompiler()
    src_binary = src_compiler.compile(src_prog)

    # Compare
    if ref_binary == src_binary:
        print(f"  PASS {name}: {len(ref_binary)} bytes, byte-identical")
        return True
    else:
        min_len = min(len(ref_binary), len(src_binary))
        diff_pos = -1
        for i in range(min_len):
            if ref_binary[i] != src_binary[i]:
                diff_pos = i
                break
        if diff_pos == -1:
            diff_pos = min_len

        print(f"  FAIL {name}: first diff at byte {diff_pos}")
        print(f"    ref len={len(ref_binary)}, src len={len(src_binary)}")
        if diff_pos < len(ref_binary):
            print(f"    ref[{diff_pos}] = 0x{ref_binary[diff_pos]:02X}")
        if diff_pos < len(src_binary):
            print(f"    src[{diff_pos}] = 0x{src_binary[diff_pos]:02X}")
        print(f"    ref strings ({len(ref_compiler.strings)}): "
              f"{ref_compiler.strings[:20]}")
        print(f"    src strings ({len(src_compiler.strings)}): "
              f"{src_compiler.strings[:20]}")
        return False


def main():
    programs_dir = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), '..', 'programs')

    all_programs = [
        'schedule_priority', 'schedule_roundrobin',
        'worker', 'producer', 'consumer', 'beacon', 'shell',
        'interactive_kernel'
    ]

    if len(sys.argv) > 1:
        programs = sys.argv[1:]
    else:
        programs = all_programs

    print("HERB Source Format Verification")
    print("=" * 50)

    passed = 0
    failed = 0
    for name in programs:
        if verify_program(name, programs_dir):
            passed += 1
        else:
            failed += 1

    print("=" * 50)
    print(f"Results: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
