#!/usr/bin/env python3
"""
Legislation Demo - Common Herb Tax Bill System

Demonstrates:
1. Bill proposal by office holder with can_propose_bills
2. Council members voting based on ideology alignment
3. Vote counting via aggregation
4. Bill passage/failure by majority
5. Tax rate update on passed bill (FUNCTIONAL auto-retract)

Expected flow:
- Bob (Mayor, ideology_tax +0.7) proposes raising Gulpin tax from 10% to 15%
- Council votes:
  - Alice (ideology_tax -0.5): opposes increase (votes against)
  - Carol (ideology_tax +0.3): supports increase (votes for)
  - Dan (ideology_tax -0.2): opposes increase (votes against)
- Result: 1 for, 2 against -> bill FAILS
"""

import sys
sys.path.insert(0, 'src')

from herb_lang import load_herb_file, compile_program
from herb_core import var


def _print_explanation(exp: dict, indent: int = 0):
    """Pretty-print a provenance explanation."""
    prefix = "  " * indent
    print(f"{prefix}{exp['fact']}")
    if exp['cause'] != 'asserted':
        print(f"{prefix}  caused by: {exp['cause']}")
    for dep in exp.get('depends_on', []):
        _print_explanation(dep, indent + 1)


def main():
    print("=" * 70)
    print("LEGISLATION DEMO - TAX BILL SYSTEM")
    print("=" * 70)

    # Load the legislation system
    program = load_herb_file("src/common_herb_legislation.herb")
    world = compile_program(program)

    X = var('x')
    Y = var('y')
    V = var('v')

    print("\n--- INITIAL STATE ---")

    # Show current tax rate
    tax_facts = world.query(("gulpin", "tax_rate", X))
    for b in tax_facts:
        print(f"Gulpin tax rate: {b['x']}%")

    # Show office holders
    print("\nOffice holders:")
    holders = world.query((X, "office_holder", Y))
    for b in holders:
        print(f"  {b['x']}: {b['y']}")

    # Show the proposed bill
    print("\nProposed bill (bill_1):")
    bills = world.query(("bill_1", X, Y))
    for b in bills:
        print(f"  {b['x']}: {b['y']}")

    # Show ideology of council members
    print("\nCouncil member ideology (tax axis):")
    for citizen in ['alice', 'carol', 'dan']:
        ideo = world.query((citizen, "ideology_tax", X))
        for b in ideo:
            print(f"  {citizen}: {b['x']:+.1f}")

    print("\n--- ADVANCING (rules fire) ---")

    # Run derivation
    world.advance(max_iterations=20)

    # Show stratification
    print("\n--- RULE STRATIFICATION ---")
    world.print_stratification()

    # Show results for all bills
    bills = world.query((X, "is_a", "tax_bill"))
    for bill_binding in bills:
        bill_id = bill_binding['x']

        print(f"\n--- {bill_id.upper()} ---")

        # Get bill details
        proposed = world.query((bill_id, "proposed_rate", X))
        for b in proposed:
            print(f"Proposed rate: {b['x']}%")

        # Check bill status
        status = world.query((bill_id, "status", X))
        for b in status:
            print(f"Status: {b['x']}")

        # Show who voted how
        print("Votes:")
        votes_for = world.query((X, "votes_for", bill_id))
        for b in votes_for:
            print(f"  {b['x']} votes FOR")

        votes_against = world.query((X, "votes_against", bill_id))
        for b in votes_against:
            print(f"  {b['x']} votes AGAINST")

        # Show vote tallies
        tally_for = world.query((bill_id, "total_for", X))
        tally_against = world.query((bill_id, "total_against", X))
        for_count = tally_for[0]['x'] if tally_for else 0
        against_count = tally_against[0]['x'] if tally_against else 0
        print(f"Tally: {for_count} for, {against_count} against")

        # Show outcome
        outcome = world.query((bill_id, "outcome", X))
        for b in outcome:
            print(f"Outcome: {b['x'].upper()}")

    # Show final tax rate
    print("\n--- FINAL TAX RATE ---")
    final_rate = world.query(("gulpin", "tax_rate", X))
    for b in final_rate:
        print(f"Gulpin tax rate: {b['x']}%")

    # Show which bills were applied
    print("\n--- APPLIED BILLS ---")
    applied = world.query((X, "applied", True))
    if applied:
        for b in applied:
            print(f"  {b['x']} was applied")
    else:
        print("  No bills were applied")

    # Provenance trace for the tax rate change
    print("\n--- PROVENANCE: Why is tax_rate 5%? ---")
    explanation = world.explain("gulpin", "tax_rate", 5)
    if explanation:
        _print_explanation(explanation)
    else:
        print("  (No derived explanation - base fact)")

    print("\n" + "=" * 70)
    print("DEMO COMPLETE")
    print("=" * 70)


if __name__ == "__main__":
    main()
