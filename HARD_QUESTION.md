# THE HARD QUESTION

What would I design if no programming language had ever existed?

This document is not a spec. It's not a plan. It's the thinking that should have
happened before Session 1, and that we're doing now because Google Antigravity
Claude was right: we built a very good Datalog variant, not something genuinely new.

---

## WHAT WE BUILT AND WHY IT'S NOT ENOUGH

HERB today is: temporal facts as triples, forward-chaining rules with pattern
matching, stratified derivation to fixpoint, provenance tracking, multi-world
isolation.

Every one of these ideas existed by 1990. Datalog (1977). OPS5/RETE (1979).
Truth maintenance systems (1979). Temporal databases (1980s). The specific
combination is well-executed, but it's a combination, not an invention.

The Bible asks: "If HERB's design ends up looking like any existing language,
something went wrong." Something went wrong.

The provenance insight IS genuinely good — "causality is navigable structure, not
reconstructed from logs." That survives. But it's embedded in a conventional
framework. We wrapped a good idea in familiar clothing.

Why did this happen? Because I started building bottom-up. "What's a good
representation for facts?" Triples. "How do we derive new facts?" Rules.
"How do we handle aggregation?" Stratification. Each answer was locally optimal
and globally conventional. I was solving implementation problems, not
confronting the design question.

---

## THE ACTUAL QUESTION

Strip away all of programming. All of it. Variables, functions, objects, types,
syntax, files, compilation, linking, execution. None of it exists. Forget it.

What exists:
- Hardware that can store and transform state
- An AI that can reason about arbitrarily complex structures
- Three targets: an OS, a browser, a game

What is the bridge from hardware to intent?

---

## WHAT IS COMPUTATION, ACTUALLY?

Not "what have we called computation." What IS it?

At the deepest level: a system has a state, and that state changes according to
rules. That's physics. That's chemistry. That's biology. Computation is just
controlled state change.

But "state" and "rules" are themselves abstractions. The hardware has bits and
gates. Everything above that is a choice we make.

The choices every language makes:

1. How to REPRESENT state (variables, objects, facts, cells, registers)
2. How to DESCRIBE change (statements, functions, rules, constraints)
3. How to ORGANIZE structure (files, modules, namespaces, scopes)
4. How to MANAGE time (sequential, concurrent, parallel, reactive)
5. How to HANDLE failure (exceptions, result types, assertions, crashes)
6. How to COMMUNICATE intent (syntax, keywords, types, comments)

Every existing language answers these six questions. HERB answers them too —
with facts, rules, worlds, ticks, guards, and .herb syntax.

The revolutionary question is: ARE THESE THE RIGHT QUESTIONS?

---

## QUESTIONING THE QUESTIONS

### "How to represent state" — is state the right primitive?

Every language assumes state exists and we're managing it. Variables hold state.
Objects hold state. Facts hold state. We spend enormous effort on state:
mutation, immutability, ownership, garbage collection, transactions.

But what if state isn't the primitive? What if CHANGE is the primitive?

A program that computes fibonacci doesn't care about "the current value of n."
It cares about the RELATIONSHIP between successive values. An OS scheduler
doesn't care about "the current state of process P." It cares about the
TRANSITION from ready to running. A game doesn't care about "where the player
is." It cares about MOVEMENT — the change from here to there.

What if the fundamental unit isn't "fact" or "variable" but DELTA — the
difference between one moment and the next?

This isn't new (event sourcing, CQRS, temporal databases). But those are
patterns bolted onto state-centric languages. What if deltas were the language?

The entire program is: an initial state + an ordered collection of deltas.
"State" is derived by applying deltas. "Querying" is filtering deltas.
"Rules" are functions from delta-patterns to new deltas.

HERB already has a piece of this — provenance tracks WHY things changed.
But the core is still state-centric (facts in a store, queried by pattern).

### "How to describe change" — is rule-based the right model?

HERB uses production rules: WHEN pattern THEN effect. This is one of many models:
- Imperative: step 1, step 2, step 3
- Functional: output = f(input)
- Logic: goal is true when subgoals are true
- Reactive: when X changes, recompute Y
- Constraint: X and Y must satisfy R; find valid assignments
- Dataflow: data flows through a graph of transformations

Each works well for some problems and badly for others:
- Game ticks: rules or reactive
- OS scheduling: constraints or rules
- HTML parsing: imperative or functional
- CSS layout: constraints
- Network I/O: reactive or async
- Pathfinding: search (none of the above, really)

HERB needs ALL THREE targets. No single model works for all of them.

The conventional answer is "multi-paradigm" — support everything. But that's
not a design, it's a surrender. You get Python: everything works, nothing is
elegant, the language has no opinion.

The unconventional question: is there a SINGLE abstraction that encompasses all
of these? Not by being vague, but by being more fundamental?

### "How to organize structure" — do we need organization at all?

Files exist because humans can't hold a whole program in working memory.
Modules exist because humans need boundaries to manage complexity.
Namespaces exist because humans reuse the same names.

An AI doesn't have any of these limitations. It can hold the entire program
in context. It can track every reference without names. It can reason about
the whole system simultaneously.

So: does an AI-native language need files? Modules? Namespaces?

Maybe not in their current form. But it needs SOMETHING, because:
- Isolation matters (processes shouldn't see each other's state)
- Composition matters (building complex things from simple things)
- Boundaries matter (defining interfaces between components)

The question is whether these organizational needs require the SAME
mechanisms humans use. They almost certainly don't.

### "How to manage time" — is sequential time the right model?

HERB has ticks. Ticks are discrete time steps. Within a tick, rules fire to
fixpoint, then the world advances. This is the game-engine model.

An OS has interrupts — asynchronous, unpredictable, nested.
A browser has event loops — queued, prioritized, sometimes synchronous.
A game has ticks — regular, predictable, batched.

These are three different temporal models. HERB's tick model works for games,
sort-of works for OS scheduling, and hasn't been tested against browser needs.

What if time isn't a global tick but a PARTIAL ORDER? Things happen in an
order defined by their causal dependencies, not by a universal clock.
Event A causes B, B causes C. D is independent of all three and can happen
"whenever." This is closer to how distributed systems actually work — and
an OS, a browser, and a game server are all distributed systems in a sense.

---

## TOWARD SOMETHING NEW

Here's where I'm landing. Not as an answer, but as a direction.

### Insight 1: The program is a SPACE, not a sequence

Every program defines a space of possible states. The initial state is a point
in that space. Execution is movement through the space. Rules/functions/
constraints define which movements are allowed. Goals define where we want to
end up.

This isn't metaphorical. It's literally what programs do. We just don't
represent it that way because text is sequential and spaces are not.

An AI doesn't need text. An AI can work with the space directly.

### Insight 2: Everything is a TRANSFORMATION, not a thing

Current HERB: "player1 has hp 100." This is a fact — a static thing.

Alternative: "player1.hp = initial(100)." And then "player1.hp = player1.hp -
damage_taken." The HP isn't a fact; it's a LENS into the history of
transformations applied to an initial value.

This preserves provenance naturally — every value is literally defined by its
history of changes. But it's more than that: it means "state" is a derived
concept, not a primitive. You never query "what is X." You query "what is the
result of all transformations applied to X's initial value."

This is event sourcing. But event sourcing as the fundamental model, not a
pattern. And with a crucial difference: the transformations are typed,
constrained, reversible, and introspectable.

### Insight 3: Constraints are more fundamental than rules

A HERB rule says: "WHEN this pattern exists, THEN assert that."
A constraint says: "These relationships must hold."

Rules are directional. Constraints are not. Rules derive A from B.
Constraints say A and B must be consistent.

CSS is constraints: "this element must be 50% of its parent's width."
OS scheduling is constraints: "no process gets less than its fair share."
Game physics is constraints: "objects cannot overlap."
Layout is constraints: "these boxes must not overflow their container."

Rules are a special case of constraints (a → b is the constraint "if a then b").
But constraints are strictly more general. A constraint-based language can
express everything a rule-based language can, plus things it can't.

The hard part is SOLVING constraints efficiently. General constraint
satisfaction is NP-hard. But:
- Most real constraints are local and structured
- An AI can reason about which constraints are tractable
- Domain-specific solvers exist and can be composed

### Insight 4: The representation should be a graph, not text

Not a graph in the "graph database" sense. A typed, attributed, multi-level
directed hypergraph where:

- Nodes are ENTITIES (anything that exists: a player, a process, a DOM element,
  a pixel, a constraint, a transformation, a goal)
- Edges are RELATIONS (any connection: depends-on, transforms, constrains,
  contains, precedes, causes)
- Each edge carries ATTRIBUTES (provenance, cost, confidence, temporal bounds)
- The graph has LEVELS (meta-levels: the program describes the state, the
  meta-program describes the program, the meta-meta-program describes the
  meta-program)

The AI manipulates this graph directly. "Writing code" is adding/removing/
modifying nodes and edges. "Reading code" is traversing the graph.
"Debugging" is querying provenance edges. "Optimizing" is restructuring
the graph while preserving semantics.

The graph IS the program, the state, and the execution trace simultaneously.
There is no compilation step because there is no source language to compile FROM.
The graph is the executable representation.

### Insight 5: Ben needs to see it, but that's a rendering problem

The graph is the truth. But Ben (and any human) needs to observe what's
happening. This is a RENDERING problem, not a representation problem.

The same program-graph can be rendered as:
- A visual node-edge diagram
- A textual summary in English
- A table of current state
- A timeline of changes
- A diff from the last version
- A .herb-like textual syntax (for familiarity)

None of these IS the program. They're all VIEWS of the program. The AI works
with the graph. Humans see rendered views. The views are generated, not written.

---

## WHAT THIS MEANS FOR HERB

If we take these insights seriously:

### What stays from current HERB:
- **Provenance** — causality as navigable structure. This is the core insight and
  it applies universally.
- **Temporal awareness** — facts/deltas know when they exist.
- **Multi-world isolation** — boundaries between domains.
- **Declarative expression** — describe what, not how (but via constraints, not
  just rules).

### What changes:
- **Triples → typed hypergraph** — relations aren't limited to subject-verb-object.
  A relation can connect any number of entities.
- **Rules → constraints + transformations** — rules are one tool, not the only tool.
  The system also solves constraints and applies transformations.
- **Text syntax → graph operations** — the AI manipulates structure directly.
  Text rendering is a view, not the representation.
- **Tick-based time → causal partial order** — events are ordered by causality,
  not a global clock. Ticks become one possible scheduling strategy.
- **Fixpoint derivation → multi-strategy resolution** — sometimes you want
  forward chaining, sometimes backward, sometimes constraint propagation,
  sometimes search. The system picks the right strategy per subproblem.

### What's new:
- **Constraints as first-class** — express invariants, relationships, requirements.
  The system maintains them automatically.
- **Deltas as primitive** — change is fundamental, state is derived.
- **Goals as first-class** — express what you want to achieve. The system finds
  paths. (This is what planning is, and neither HERB nor most languages support it.)
- **Multi-level meta-programming** — the program can inspect and modify itself at
  every level, because the program IS a data structure the AI is already
  manipulating.
- **Domain-adaptive execution** — the runtime picks execution strategies
  (rule firing, constraint solving, search, dataflow) based on the structure of
  the subproblem. Not one strategy fits all.

---

## THE HARD PART

This is ambitious to the point of possibly being impossible. The risk:

1. **Constraint solving is hard** — general SAT/CSP is NP-hard. We'd need to
   restrict to tractable constraint classes or accept approximate solutions.

2. **Graph manipulation is complex** — maintaining consistency in a typed
   hypergraph with multi-level meta-programming is much harder than maintaining
   a flat fact store.

3. **Multi-strategy execution is a research problem** — automatically choosing
   between forward chaining, constraint propagation, and search based on
   problem structure is an open research question.

4. **We lose simplicity** — current HERB is beautifully simple. Facts and rules.
   That's it. The proposed system is much more complex.

5. **Implementation time** — this is a much bigger project than refining the
   current system.

But the Bible says: "Nothing is sacred except the mission." And the mission
is to build something genuinely new.

---

## THE QUESTION FOR BEN

Two paths:

**Path A: Evolve.** Keep the current fact-and-rule core. Add constraints, richer
relations, and better execution strategies incrementally. Ship Common Herb on
what we have. Iterate toward the bigger vision over time. This is safer and
produces working software sooner.

**Path B: Rethink.** Take the ideas in this document seriously. Design HERB v2
around the graph/constraint/delta model. Port the working game demos to validate
the new design. Accept that this takes longer but aims at something genuinely
unprecedented.

There is no Path C. Multi-paradigm compromise ("support everything") is how you
get languages with no soul.

Which path?
