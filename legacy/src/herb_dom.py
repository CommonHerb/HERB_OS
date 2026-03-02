"""
HERB DOM Layout Pipeline — Pure Data

A browser layout/paint pipeline expressed as a HERB program.
Demonstrates cascading tensions: a style change triggers
invalidation → layout → paint → clean, all autonomously.

Each element has a layout state (which container it's in).
Style change signals trigger invalidation of clean elements.
The pipeline runs itself to equilibrium.

This is the second proof that the representation works
across domains — OS scheduling AND browser rendering.
"""

DOM_LAYOUT = {
    "entity_types": [
        {"name": "Element"},
        {"name": "StyleChange"},
    ],

    "containers": [
        # Layout pipeline states
        {"name": "NEEDS_LAYOUT",  "kind": "simple", "entity_type": "Element"},
        {"name": "LAID_OUT",      "kind": "simple", "entity_type": "Element"},
        {"name": "NEEDS_PAINT",   "kind": "simple", "entity_type": "Element"},
        {"name": "PAINTED",       "kind": "simple", "entity_type": "Element"},
        {"name": "CLEAN",         "kind": "simple", "entity_type": "Element"},

        # Style change signal containers
        {"name": "STYLE_PENDING", "kind": "simple", "entity_type": "StyleChange"},
        {"name": "STYLE_APPLIED", "kind": "simple", "entity_type": "StyleChange"},
    ],

    "moves": [
        # Layout pipeline transitions
        {"name": "do_layout",
         "from": ["NEEDS_LAYOUT"],
         "to": ["LAID_OUT"],
         "entity_type": "Element"},

        {"name": "mark_needs_paint",
         "from": ["LAID_OUT"],
         "to": ["NEEDS_PAINT"],
         "entity_type": "Element"},

        {"name": "do_paint",
         "from": ["NEEDS_PAINT"],
         "to": ["PAINTED"],
         "entity_type": "Element"},

        {"name": "mark_clean",
         "from": ["PAINTED"],
         "to": ["CLEAN"],
         "entity_type": "Element"},

        # Invalidation: clean/painted elements need re-layout
        {"name": "invalidate",
         "from": ["CLEAN", "PAINTED"],
         "to": ["NEEDS_LAYOUT"],
         "entity_type": "Element"},

        # Style change processing
        {"name": "apply_style",
         "from": ["STYLE_PENDING"],
         "to": ["STYLE_APPLIED"],
         "entity_type": "StyleChange"},
    ],

    "tensions": [
        # Style change triggers invalidation of ALL clean elements
        # Priority 20: process style changes before running layout
        {
            "name": "style_invalidation",
            "priority": 20,
            "match": [
                {"bind": "change", "in": "STYLE_PENDING", "select": "first"},
                {"bind": "el", "in": "CLEAN", "select": "each"},
            ],
            "emit": [
                {"move": "apply_style", "entity": "change", "to": "STYLE_APPLIED"},
                {"move": "invalidate", "entity": "el", "to": "NEEDS_LAYOUT"},
            ],
        },

        # Layout pipeline: automatic cascade through states
        # Priority 10: layout runs after invalidation
        {
            "name": "run_layout",
            "priority": 10,
            "match": [{"bind": "el", "in": "NEEDS_LAYOUT", "select": "each"}],
            "emit": [{"move": "do_layout", "entity": "el", "to": "LAID_OUT"}],
        },

        # Priority 8: mark as needing paint after layout
        {
            "name": "needs_paint",
            "priority": 8,
            "match": [{"bind": "el", "in": "LAID_OUT", "select": "each"}],
            "emit": [{"move": "mark_needs_paint", "entity": "el", "to": "NEEDS_PAINT"}],
        },

        # Priority 5: paint after layout
        {
            "name": "run_paint",
            "priority": 5,
            "match": [{"bind": "el", "in": "NEEDS_PAINT", "select": "each"}],
            "emit": [{"move": "do_paint", "entity": "el", "to": "PAINTED"}],
        },

        # Priority 1: finalize
        {
            "name": "finalize",
            "priority": 1,
            "match": [{"bind": "el", "in": "PAINTED", "select": "each"}],
            "emit": [{"move": "mark_clean", "entity": "el", "to": "CLEAN"}],
        },
    ],

    "entities": [
        # Three elements that need initial layout
        {"name": "header",  "type": "Element", "in": "NEEDS_LAYOUT"},
        {"name": "content", "type": "Element", "in": "NEEDS_LAYOUT"},
        {"name": "footer",  "type": "Element", "in": "NEEDS_LAYOUT"},
    ],
}
