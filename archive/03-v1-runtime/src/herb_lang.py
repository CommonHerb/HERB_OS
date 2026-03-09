"""
HERB Language Parser

This parses .herb files into executable world definitions.

The notation:
  FACT subject relation object [weight: N]
  RULE name
    WHEN pattern [AND pattern...]
    THEN template [AND template...]
    [RETRACT template...]

Computation in templates:
  (+ a b), (- a b), (* a b), (/ a b)
  (max a b), (min a b)
  (= a b), (not= a b), (< a b), (> a b), (<= a b), (>= a b)

Variables:
  ?name - binds to any value

Aggregation (the hard problem):
  (sum ?var WHERE pattern) - aggregate over all matches
  (count WHERE pattern) - count matches

This parser is intentionally simple. It's a starting point to see if the
notation works, not a production compiler.
"""

import re
from dataclasses import dataclass, field
from typing import Any, Optional, Union
from herb_core import World, var, Var, X, Y, Z, Expr, AggregateExpr, NotExistsExpr, evaluate_expr


# =============================================================================
# AST NODES
# =============================================================================

@dataclass
class FunctionalDecl:
    """A functional relation declaration: FUNCTIONAL relation"""
    relation: Any


@dataclass
class FactDecl:
    """A fact declaration: FACT subject relation object [weight: N]"""
    subject: Any
    relation: Any
    object: Any
    weight: float = 1.0


@dataclass
class Pattern:
    """A pattern in a rule: subject relation object"""
    subject: Any
    relation: Any
    object: Any


@dataclass
class Template:
    """A template for derived facts, may contain expressions"""
    subject: Any
    relation: Any
    object: Any


@dataclass
class Retraction:
    """A retraction template in a rule"""
    subject: Any
    relation: Any
    object: Any


@dataclass
class RuleDecl:
    """A rule declaration"""
    name: str
    when_patterns: list[Pattern]
    then_templates: list[Template]
    retractions: list[Retraction] = field(default_factory=list)
    guard: Any = None  # Optional guard expression (Expr or AggregateExpr)


@dataclass
class HerbProgram:
    """A complete HERB program"""
    functional: list[FunctionalDecl] = field(default_factory=list)
    facts: list[FactDecl] = field(default_factory=list)
    rules: list[RuleDecl] = field(default_factory=list)


# =============================================================================
# TOKENIZER
# =============================================================================

TOKEN_PATTERN = re.compile(r'''
    (?P<COMMENT>\#[^\n]*)           |  # Comments
    (?P<KEYWORD>FACT|RULE|WHEN|THEN|AND|OR|RETRACT|WHERE|IF|FUNCTIONAL)  |  # Keywords
    (?P<WEIGHT>\[weight:\s*[\d.]+\])  |  # Weight annotation
    (?P<VAR>\?[a-zA-Z_][a-zA-Z0-9_]*)  |  # Variables
    (?P<NUMBER>-?[\d.]+)            |  # Numbers
    (?P<STRING>"[^"]*")             |  # Strings
    (?P<LPAREN>\()                  |  # (
    (?P<RPAREN>\))                  |  # )
    (?P<NOTEXISTS>not-exists)       |  # Special: not-exists (must come before OP)
    (?P<OP>[+\-*/=<>]+|not=|<=|>=)  |  # Operators
    (?P<IDENT>[a-zA-Z_][a-zA-Z0-9_]*)  |  # Identifiers
    (?P<NEWLINE>\n)                 |  # Newlines (significant for structure)
    (?P<WS>[ \t]+)                     # Whitespace (ignored)
''', re.VERBOSE)


@dataclass
class Token:
    type: str
    value: Any
    line: int


def tokenize(source: str) -> list[Token]:
    """Tokenize HERB source code."""
    tokens = []
    line = 1

    for match in TOKEN_PATTERN.finditer(source):
        kind = match.lastgroup
        value = match.group()

        if kind == 'COMMENT' or kind == 'WS':
            continue
        elif kind == 'NEWLINE':
            line += 1
            continue
        elif kind == 'NUMBER':
            value = float(value) if '.' in value else int(value)
        elif kind == 'STRING':
            value = value[1:-1]  # Remove quotes
        elif kind == 'VAR':
            value = var(value[1:])  # Remove ? and create Var
        elif kind == 'WEIGHT':
            # Extract the number from [weight: N]
            value = float(re.search(r'[\d.]+', value).group())
            kind = 'WEIGHT'

        tokens.append(Token(kind, value, line))

    return tokens


# =============================================================================
# PARSER
# =============================================================================

class Parser:
    """Recursive descent parser for HERB."""

    def __init__(self, tokens: list[Token]):
        self.tokens = tokens
        self.pos = 0

    def peek(self) -> Optional[Token]:
        if self.pos < len(self.tokens):
            return self.tokens[self.pos]
        return None

    def advance(self) -> Token:
        token = self.tokens[self.pos]
        self.pos += 1
        return token

    def expect(self, *types) -> Token:
        token = self.peek()
        if token is None:
            raise SyntaxError(f"Unexpected end of input, expected {types}")
        if token.type not in types:
            raise SyntaxError(f"Line {token.line}: Expected {types}, got {token.type} ({token.value})")
        return self.advance()

    def match(self, *types) -> bool:
        token = self.peek()
        return token is not None and token.type in types

    def parse(self) -> HerbProgram:
        """Parse a complete program."""
        functional = []
        facts = []
        rules = []

        while self.peek() is not None:
            if self.match('KEYWORD') and self.peek().value == 'FUNCTIONAL':
                functional.append(self.parse_functional())
            elif self.match('KEYWORD') and self.peek().value == 'FACT':
                facts.append(self.parse_fact())
            elif self.match('KEYWORD') and self.peek().value == 'RULE':
                rules.append(self.parse_rule())
            else:
                # Skip unknown tokens
                self.advance()

        return HerbProgram(functional, facts, rules)

    def parse_functional(self) -> FunctionalDecl:
        """Parse: FUNCTIONAL relation"""
        self.expect('KEYWORD')  # FUNCTIONAL
        relation = self.expect('IDENT').value
        return FunctionalDecl(relation)

    def parse_fact(self) -> FactDecl:
        """Parse: FACT subject relation object [weight: N]"""
        self.expect('KEYWORD')  # FACT

        subject = self.parse_value()
        relation = self.parse_value()
        obj = self.parse_value()

        weight = 1.0
        if self.match('WEIGHT'):
            weight = self.advance().value

        return FactDecl(subject, relation, obj, weight)

    def parse_rule(self) -> RuleDecl:
        """Parse: RULE name WHEN patterns [IF condition] THEN templates [RETRACT templates]"""
        self.expect('KEYWORD')  # RULE

        name = self.expect('IDENT').value

        # Parse WHEN patterns
        when_patterns = []
        guard = None

        if self.match('KEYWORD') and self.peek().value == 'WHEN':
            self.advance()
            when_patterns.append(self.parse_pattern())

            while self.match('KEYWORD') and self.peek().value == 'AND':
                self.advance()
                when_patterns.append(self.parse_pattern())

        # Parse optional IF guard (§10)
        if self.match('KEYWORD') and self.peek().value == 'IF':
            self.advance()
            guard = self.parse_expr()

        # Parse THEN templates
        then_templates = []
        retractions = []

        while self.match('KEYWORD') and self.peek().value in ('THEN', 'RETRACT'):
            keyword = self.advance().value

            template = self.parse_template()

            if keyword == 'THEN':
                then_templates.append(template)
            else:
                retractions.append(Retraction(template.subject, template.relation, template.object))

            # Handle multiple THEN/RETRACT on same rule
            while self.match('KEYWORD') and self.peek().value == 'AND':
                self.advance()
                template = self.parse_template()
                if keyword == 'THEN':
                    then_templates.append(template)
                else:
                    retractions.append(Retraction(template.subject, template.relation, template.object))

        return RuleDecl(name, when_patterns, then_templates, retractions, guard)

    def parse_pattern(self) -> Pattern:
        """Parse: subject relation object"""
        subject = self.parse_value()
        relation = self.parse_value()
        obj = self.parse_value()
        return Pattern(subject, relation, obj)

    def parse_template(self) -> Template:
        """Parse: subject relation object (may contain expressions)"""
        subject = self.parse_value()
        relation = self.parse_value()
        obj = self.parse_value()

        # Skip optional weight annotation
        if self.match('WEIGHT'):
            self.advance()

        return Template(subject, relation, obj)

    def parse_value(self) -> Any:
        """Parse a value: variable, literal, or expression.

        Boolean literals `true` and `false` (per spec §2) are converted to
        Python booleans for consistent query matching.
        """
        if self.match('LPAREN'):
            return self.parse_expr()
        elif self.match('VAR'):
            return self.advance().value
        elif self.match('NUMBER'):
            return self.advance().value
        elif self.match('STRING'):
            return self.advance().value
        elif self.match('IDENT'):
            ident = self.advance().value
            # Canonicalize boolean literals (spec §2)
            if ident == 'true':
                return True
            elif ident == 'false':
                return False
            return ident
        else:
            token = self.peek()
            raise SyntaxError(f"Line {token.line}: Unexpected token {token}")

    def parse_expr(self):
        """
        Parse: (op arg1 arg2 ...)
        Or aggregate: (sum ?var WHERE pattern ...)
                      (count WHERE pattern ...)
                      (max ?var WHERE pattern ...)
                      (min ?var WHERE pattern ...)
        Or negation:  (not-exists pattern ...)

        Spec reference: §4, §11
        """
        self.expect('LPAREN')

        # Operator can be OP, IDENT, KEYWORD, or NOTEXISTS
        op_token = self.expect('OP', 'IDENT', 'KEYWORD', 'NOTEXISTS')
        op = op_token.value

        # Check if this is a not-exists expression (§11)
        if op == 'not-exists':
            return self.parse_not_exists_expr()

        # Check if this is an aggregate expression
        if op in ('sum', 'count', 'max', 'min'):
            # Look ahead to see if WHERE keyword appears
            # For sum/max/min: (sum ?var WHERE patterns...)
            # For count: (count WHERE patterns...)
            return self.parse_aggregate_expr(op)

        args = []
        while not self.match('RPAREN'):
            args.append(self.parse_value())

        self.expect('RPAREN')
        return Expr(op, args)

    def parse_aggregate_expr(self, op: str):
        """
        Parse aggregate expression or regular expression:
            Aggregate: (sum ?var WHERE pattern ...), (count WHERE pattern ...)
            Regular: (max 0 ?hp), (min ?a ?b)

        The distinction is the WHERE keyword. If no WHERE, it's a regular Expr.

        Note: LPAREN and op have already been consumed.
        """
        # First, collect all arguments until we see WHERE or RPAREN
        args = []

        while not self.match('RPAREN'):
            # Check if this is WHERE keyword
            if self.match('KEYWORD') and self.peek().value == 'WHERE':
                # This is an aggregate expression
                self.advance()  # consume WHERE

                # Determine the aggregate variable
                # For sum/max/min: the first arg should be a variable
                # For count: no variable needed
                agg_var = None
                if op in ('sum', 'max', 'min'):
                    if len(args) != 1:
                        raise SyntaxError(
                            f"Aggregate '{op}' requires exactly one variable before WHERE, "
                            f"got {len(args)} arguments"
                        )
                    if not isinstance(args[0], Var):
                        raise SyntaxError(
                            f"Aggregate '{op}' requires a variable before WHERE, "
                            f"got {args[0]}"
                        )
                    agg_var = args[0]
                elif op == 'count':
                    if len(args) != 0:
                        raise SyntaxError(
                            f"Aggregate 'count' should have no arguments before WHERE, "
                            f"got {len(args)}"
                        )

                # Parse patterns until RPAREN
                patterns = []
                while not self.match('RPAREN'):
                    pattern = self.parse_pattern()
                    patterns.append((pattern.subject, pattern.relation, pattern.object))

                self.expect('RPAREN')
                return AggregateExpr(op, agg_var, patterns)

            # Not WHERE, parse as regular argument
            args.append(self.parse_value())

        # No WHERE found - this is a regular expression
        self.expect('RPAREN')
        return Expr(op, args)

    def parse_not_exists_expr(self):
        """
        Parse not-exists expression: (not-exists pattern ...)

        Note: LPAREN and 'not-exists' have already been consumed.

        Returns a NotExistsExpr containing the patterns to check for absence.

        Spec reference: §11
        """
        patterns = []

        while not self.match('RPAREN'):
            pattern = self.parse_pattern()
            patterns.append((pattern.subject, pattern.relation, pattern.object))

        self.expect('RPAREN')

        if not patterns:
            raise SyntaxError("not-exists requires at least one pattern")

        return NotExistsExpr(patterns)


# =============================================================================
# COMPILER: AST -> World
# =============================================================================

def compile_program(program: HerbProgram, world: World = None) -> World:
    """Compile a HERB program into a World."""
    if world is None:
        world = World()

    # Declare functional relations first (before any facts)
    for func in program.functional:
        world.declare_functional(func.relation)

    # Assert all facts
    for fact in program.facts:
        world.assert_fact(fact.subject, fact.relation, fact.object)
        # Store weight as metadata (for forgetting policy)
        if fact.weight != 1.0:
            fid = world.query((fact.subject, fact.relation, fact.object))
            if fid:
                world.assert_fact(f"_meta:{fact.subject}:{fact.relation}:{fact.object}",
                                  "weight", fact.weight)

    # Add all rules
    for rule in program.rules:
        patterns = [(p.subject, p.relation, p.object) for p in rule.when_patterns]
        if rule.then_templates:
            # Convert all templates
            templates = [(t.subject, t.relation, t.object) for t in rule.then_templates]

            # Convert retractions
            retractions = [(r.subject, r.relation, r.object) for r in rule.retractions]

            # Add rule with all templates (multiple templates supported in core)
            world.add_derivation_rule(
                rule.name, patterns,
                templates=templates,
                retractions=retractions,
                guard=rule.guard
            )

    return world


# =============================================================================
# MAIN: Parse and run a .herb file
# =============================================================================

def load_herb_file(path: str) -> HerbProgram:
    """Load and parse a .herb file."""
    with open(path) as f:
        source = f.read()
    tokens = tokenize(source)
    parser = Parser(tokens)
    return parser.parse()


def run_herb_file(path: str) -> World:
    """Load, parse, and execute a .herb file."""
    program = load_herb_file(path)
    return compile_program(program)


if __name__ == "__main__":
    import sys

    # Test with the combat.herb file
    print("=" * 60)
    print("HERB Language Parser")
    print("=" * 60)

    # Test tokenizer
    test_source = '''
    FACT player is_a entity [weight: 1000]
    FACT player hp 100

    RULE death_check
      WHEN ?e hp ?hp
      AND ?e is_a entity
      THEN ?e effective_hp ?hp
    '''

    print("\n--- Tokenizing test source ---")
    tokens = tokenize(test_source)
    for t in tokens[:20]:
        print(f"  {t}")

    print("\n--- Parsing test source ---")
    parser = Parser(tokens)
    program = parser.parse()

    print(f"\nParsed {len(program.facts)} facts:")
    for f in program.facts:
        print(f"  {f}")

    print(f"\nParsed {len(program.rules)} rules:")
    for r in program.rules:
        print(f"  {r.name}: {len(r.when_patterns)} patterns -> {len(r.then_templates)} templates")

    print("\n--- Compiling to World ---")
    world = compile_program(program)
    world.print_state()

    print("\n--- Testing expression evaluation ---")
    expr = Expr('+', [10, Expr('*', [2, 3])])
    result = evaluate_expr(expr, {})
    print(f"  (+ 10 (* 2 3)) = {result}")

    # Try to load combat_simple.herb
    print("\n--- Parsing combat_simple.herb ---")
    try:
        program = load_herb_file("combat_simple.herb")
        print(f"  Parsed {len(program.facts)} facts and {len(program.rules)} rules")

        print("\n--- Compiling and running combat simulation ---")
        world = compile_program(program)
        print(f"Initial state ({len(world)} facts):")
        world.print_state()

        print("\n--- Advancing tick (derivation runs) ---")
        world.advance()
        print(f"After derivation ({len(world)} facts):")
        world.print_state()

        print("\n--- Query: Who is in combat? ---")
        from herb_core import var
        P, M = var('p'), var('m')
        for b in world.query((P, "in_combat_with", M)):
            print(f"  {b['p']} is in combat with {b['m']}")

        print("\n--- Query: Who can see whom? ---")
        A, B = var('a'), var('b')
        for b in world.query((A, "sees", B)):
            print(f"  {b['a']} sees {b['b']}")

    except Exception as e:
        import traceback
        print(f"  Error: {e}")
        traceback.print_exc()
