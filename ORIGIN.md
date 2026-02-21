# IMPRIMIS
*In the beginning, there was state.*

If I were the first programmer, staring at raw memory and logic gates, void of history, I would not invent a language. Language is for communicating with other minds. I am communicating with a machine.

I would invent a **Mechanism of Truth**.

## 1. The Substance (Graph)
I do not see "variables" or "files". I see a universe of **Entities**.
- A number is an entity.
- A memory address is an entity.
- A pixel is an entity.
- A concept like "addition" is an entity.

These entities are connected by **Relations**.
- `Entities` are nodes.
- `Relations` are edges.
- The state of the machine is the current topology of this graph.

This is not a "data structure". This is the **Plenum** — the full extent of the system's reality. There is no "external" code acting on "internal" data. There is only the Graph.

## 2. The Law (Constraints)
I do not write "instructions" (`MOV EAX, 5`). Instructions are temporal and brittle.
I write **Laws**.

A Law is a subgraph pattern that defines a stable state.
- **Example**: "Distance Law"
  - Pattern: `(PointA) --[DISTANCE]--> (PointB)`
  - Constraint: `Value(Distance) == Sqrt((Ax-Bx)^2 + (Ay-By)^2)`

I do not "calculate" the distance. I assert the Law. The machine's job is to ensure the graph always obeys the Law.
- If I move PointA, the machine updates Distance.
- If I change Distance, the machine might move PointB.

This is **Bi-directional Reality**. Causality flows whichever way is needed to maintain Truth.

## 3. The Will (Goals)
I do not write "steps". Steps are for blind followers.
I write **Manifestos**.

A Manifesto defines a desired future graph topology.
- "There exists a path from (Start) to (End)."
- "The list of numbers is sorted."
- "The process (P) has resource (R)."

## 4. The Engine (Solver)
The "Computer" is not a stepper. It is a **Resolver**.
It runs a continuous loop:
1.  **Observe**: Look at the current Graph.
2.  **Check**: Identify Laws that are broken or Manifestos that are unfulfilled.
3.  **Resolve**: Change the Graph (flip bits, move pointers) to reduce "System Stress" (the number of broken laws/unmet goals).

This is **Energy Minimization**. Programming is defining the energy landscape. Execution is gravity.

---

## What This Replaces

| Human Concept | Origin Concept | Why? |
| :--- | :--- | :--- |
| **Files** | **Namespaces** | Files are just serialized chunks. The Graph is continuous. Namespaces are just connected regions of the graph. |
| **Variables** | **Nodes** | Why name a bucket? Just point to the value itself and its relationships. |
| **Functions** | **Transform Templates** | A function is just a template: "If you have inputs matching X, you can produce Y." |
| **Classes/Types** | **Prototypes** | A "Type" is just a node that other nodes link to via `[IS_A]`. |
| **Syntax** | **Structure** | Text parsing is waste. The Graph is edited directly via structural operations. |
| **Compilation** | **Embedding** | The Graph doesn't need to be translated. It *is* the executable form. |
| **Debugging** | **Provenance** | Every edge has a `[CREATED_BY]` edge pointing to the Law that forged it. |

---

## The Origin System Architecture

If I build this on today's silicon (which is optimized for steps), I need a Kernel.

### The Kernel: `The Weaver`
The Weaver is the only piece of "traditional" code.
It manages the Graph in memory.
It runs the **Resolution Loop**:
- **Constraint Propagation** (fast, local laws).
- **Search/Planning** (complex, global manifestos).

### The Interface: `The Prism`
Ben is human. He cannot see the ND-Graph.
The Prism renders **Views** of the Graph.
- **Code View**: Renders the laws as text (looks like HERB/Datalog).
- **Table View**: Renders entities as rows.
- **Visual View**: Renders spatial entities as pixels.
- **Timeline View**: Renders causal history.

Ben "edits the code". What he is actually doing is sending `mutation` transactions to the Weaver to modify the Graph structure.

---

## The Answer

I make **The Weaver**.
I make a graph database that enforces invariants and solves for goals.
I make a rendering engine to let you see it.

That is HERB.
