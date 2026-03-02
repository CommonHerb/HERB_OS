"""
HERB Economy Demo — Quantity Transfers

Demonstrates conservation pools and quantity transfers.
Three players hold gold. A tax event triggers collection
from each player who can afford it. Conservation is structural:
the total gold never changes.

This proves HERB can handle quantity-based policies, not just
entity-containment state machines.

Key features exercised:
- Entity properties (gold amounts)
- Conservation pools (total gold preserved)
- Quantity transfers in tension emits
- Expression guards (checking if player has enough gold)
- Dynamic entity creation (spawning rewards)
"""

ECONOMY = {
    "entity_types": [
        {"name": "Player"},
        {"name": "TaxEvent"},
        {"name": "Reward"},
    ],

    "containers": [
        {"name": "WORLD",           "kind": "simple", "entity_type": "Player"},
        {"name": "TAX_PENDING",     "kind": "simple", "entity_type": "TaxEvent"},
        {"name": "TAX_DONE",        "kind": "simple", "entity_type": "TaxEvent"},
        {"name": "REWARD_PENDING",  "kind": "simple", "entity_type": "Reward"},
        {"name": "REWARD_DONE",     "kind": "simple", "entity_type": "Reward"},
    ],

    "pools": [
        {"name": "gold", "property": "gold"},
    ],

    "transfers": [
        {"name": "collect_tax", "pool": "gold"},
        {"name": "give_reward", "pool": "gold"},
    ],

    "moves": [
        {"name": "finish_tax",
         "from": ["TAX_PENDING"],
         "to": ["TAX_DONE"],
         "entity_type": "TaxEvent"},

        {"name": "finish_reward",
         "from": ["REWARD_PENDING"],
         "to": ["REWARD_DONE"],
         "entity_type": "Reward"},
    ],

    "tensions": [
        # -----------------------------------------------------------------
        # TAX COLLECTION
        #
        # When a tax event is pending, collect 10 gold from each player
        # who has at least 10 gold. The guard expression filters out
        # players who can't afford it.
        #
        # Priority 20: taxes before rewards.
        # -----------------------------------------------------------------
        {
            "name": "tax_collection",
            "priority": 20,
            "match": [
                {"container": "TAX_PENDING", "is": "occupied"},
                {"bind": "player", "in": "WORLD", "select": "each",
                 "where": {"op": ">=",
                           "left": {"prop": "gold", "of": "player"},
                           "right": 10}},
            ],
            "emit": [
                {"transfer": "collect_tax",
                 "from": "player", "to": "treasury",
                 "amount": 10},
            ],
        },

        # Consume tax event after collection
        {
            "name": "tax_consume",
            "priority": 15,
            "match": [
                {"bind": "evt", "in": "TAX_PENDING", "select": "first"},
            ],
            "emit": [
                {"move": "finish_tax", "entity": "evt", "to": "TAX_DONE"},
            ],
        },

        # -----------------------------------------------------------------
        # REWARD DISTRIBUTION
        #
        # When a reward is pending, give gold from treasury to the
        # richest player (max_by gold). The amount is the reward's
        # "amount" property.
        # -----------------------------------------------------------------
        {
            "name": "reward_distribution",
            "priority": 10,
            "match": [
                {"bind": "reward", "in": "REWARD_PENDING", "select": "first"},
                {"bind": "player", "in": "WORLD", "select": "max_by",
                 "key": "gold"},
                # Guard: treasury must have enough
                {"guard": {"op": ">=",
                           "left": {"prop": "gold", "of": "treasury"},
                           "right": {"prop": "amount", "of": "reward"}}},
            ],
            "emit": [
                {"transfer": "give_reward",
                 "from": "treasury", "to": "player",
                 "amount": {"prop": "amount", "of": "reward"}},
                {"move": "finish_reward",
                 "entity": "reward", "to": "REWARD_DONE"},
            ],
        },
    ],

    "entities": [
        {"name": "alice",    "type": "Player", "in": "WORLD",
         "properties": {"gold": 500}},
        {"name": "bob",      "type": "Player", "in": "WORLD",
         "properties": {"gold": 300}},
        {"name": "charlie",  "type": "Player", "in": "WORLD",
         "properties": {"gold": 5}},
        {"name": "treasury", "type": "Player", "in": "WORLD",
         "properties": {"gold": 195}},
    ],
}
