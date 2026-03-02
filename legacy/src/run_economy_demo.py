"""
Common Herb Economy Demo

Tests the economy system:
1. Tax calculation with exemptions
2. Purchase execution
3. Gold transfers
"""

from herb_lang import load_herb_file, compile_program
from herb_core import var


def main():
    print("=" * 70)
    print("Common Herb Economy Demo")
    print("=" * 70)

    program = load_herb_file("common_herb_economy.herb")
    world = compile_program(program)

    X = var('x')
    Y = var('y')
    Z = var('z')

    print("\n--- FUNCTIONAL RELATIONS ---")
    print(f"  Functional: {list(world._functional_relations)}")

    print("\n--- RULE STRATIFICATION ---")
    world.print_stratification()

    # Initial state
    print("\n--- INITIAL STATE ---")

    print("\nJurisdictions:")
    for j in ['gulpin', 'northvale', 'freeport']:
        rate = world.query((j, "tax_rate", X))
        treasury = world.query((j, "treasury", X))
        rate_val = rate[0]['x'] if rate else "?"
        treasury_val = treasury[0]['x'] if treasury else "?"
        print(f"  {j}: tax={rate_val}%, treasury={treasury_val}")

    print("\nPlayers:")
    for p in ['alice', 'bob']:
        gold = world.query((p, "gold", X))
        loc = world.query((p, "location", X))
        exempt = world.query((p, "exemption", X))
        gold_val = gold[0]['x'] if gold else "?"
        loc_val = loc[0]['x'] if loc else "?"
        exempt_list = [e['x'] for e in exempt] if exempt else []
        print(f"  {p}: gold={gold_val}, location={loc_val}, exemptions={exempt_list}")

    print("\nPurchase requests:")
    requests = world.query((X, "is_a", "purchase_request"))
    for r in requests:
        req = r['x']
        buyer = world.query((req, "buyer", Y))
        item = world.query((req, "item", Y))
        shop = world.query((req, "shop", Y))
        buyer_val = buyer[0]['y'] if buyer else "?"
        item_val = item[0]['y'] if item else "?"
        shop_val = shop[0]['y'] if shop else "?"
        print(f"  {req}: {buyer_val} wants {item_val} from {shop_val}")

    # Run economy
    print("\n--- ADVANCING (rules fire) ---")
    world.advance()

    print("\n--- RULE STRATIFICATION (after advance) ---")
    world.print_stratification()

    # Debug: show all gold-related facts
    print("\n--- DEBUG: All gold facts ---")
    for f in world.all_facts():
        if f.relation == "gold":
            status = "ALIVE" if f.is_alive(world.tick) else "DEAD"
            print(f"  {f.subject} gold {f.object} [{status}, from tick {f.from_tick}]")

    # Results
    print("\n--- AFTER ADVANCE ---")

    print("\nEffective prices calculated:")
    prices = world.query((X, "effective_price", Y))
    for p in prices:
        req = p['x']
        buyer = world.query((req, "buyer", Z))
        item = world.query((req, "item", Z))
        buyer_val = buyer[0]['z'] if buyer else "?"
        item_val = item[0]['z'] if item else "?"
        print(f"  {req}: {buyer_val}'s price for {item_val} = {p['y']}")

    print("\nPurchases made:")
    purchases = world.query((X, "purchased", Y))
    for p in purchases:
        print(f"  {p['x']} purchased {p['y']}")

    print("\nGold after transactions:")
    for p in ['alice', 'bob']:
        gold = world.query((p, "gold", X))
        gold_val = gold[0]['x'] if gold else "?"
        print(f"  {p}: {gold_val} gold")

    print("\nTax paid:")
    taxes = world.query((X, "tax_paid", Y))
    for t in taxes:
        req = t['x']
        buyer = world.query((req, "buyer", Z))
        item = world.query((req, "item", Z))
        jur = world.query((req, "tax_to", Z))
        buyer_val = buyer[0]['z'] if buyer else "?"
        item_val = item[0]['z'] if item else "?"
        jur_val = jur[0]['z'] if jur else "?"
        print(f"  {buyer_val} paid {t['y']} tax on {item_val} -> {jur_val}")

    print("\nTick revenue per jurisdiction:")
    for j in ['gulpin', 'northvale', 'freeport']:
        revenue = world.query((j, "tick_revenue", X))
        rev_val = revenue[0]['x'] if revenue else 0
        print(f"  {j}: {rev_val} gold")

    print("\nTreasuries after tax collection:")
    for j in ['gulpin', 'northvale', 'freeport']:
        treasury = world.query((j, "treasury", X))
        treasury_val = treasury[0]['x'] if treasury else "?"
        print(f"  {j}: {treasury_val} gold")

    # Remaining requests (couldn't afford?)
    remaining = world.query((X, "is_a", "purchase_request"))
    if remaining:
        print("\nRemaining requests (not processed):")
        for r in remaining:
            req = r['x']
            buyer = world.query((req, "buyer", Y))
            item = world.query((req, "item", Y))
            buyer_val = buyer[0]['y'] if buyer else "?"
            item_val = item[0]['y'] if item else "?"
            print(f"  {buyer_val} still wants {item_val}")

    # Provenance
    print("\n--- PROVENANCE ---")
    purchases = world.query((X, "purchased", Y))
    if purchases:
        p = purchases[0]
        print(f"\nWhy did {p['x']} purchase {p['y']}?")
        explanation = world.explain(p['x'], "purchased", p['y'])
        if explanation:
            def print_exp(exp, indent=0):
                prefix = "  " * indent
                print(f"{prefix}{exp['fact']}")
                print(f"{prefix}  caused by: {exp['cause']}")
                for dep in exp.get('depends_on', []):
                    print_exp(dep, indent + 1)
            print_exp(explanation)

    print("\n" + "=" * 70)
    print("ECONOMY DEMO COMPLETE")
    print("=" * 70)


if __name__ == "__main__":
    main()
