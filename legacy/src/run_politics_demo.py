"""
Common Herb Politics Demo

Demonstrates the political simulation:
- Citizens with ideology axes
- Ambition-based candidacy
- Ideology-based voting
- Vote counting via aggregation
- Reputation bonuses
"""

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
    print("Common Herb Politics Demo")
    print("=" * 70)

    # Load and compile the politics program
    program = load_herb_file("common_herb_politics.herb")
    world = compile_program(program)

    # Show functional relations
    print("\n--- FUNCTIONAL RELATIONS ---")
    print(f"  Functional: {list(world._functional_relations)}")

    # Show initial state
    print("\n--- INITIAL STATE ---")

    # Citizens
    X = var('x')
    citizens = world.query((X, "is_a", "citizen"))
    print("\nCitizens:")
    for c in citizens:
        name = c['x']
        job = world.query((name, "job", X))[0]['x']
        home = world.query((name, "home", X))[0]['x']
        tax = world.query((name, "ideology_tax", X))[0]['x']
        war = world.query((name, "ideology_war", X))[0]['x']
        order = world.query((name, "ideology_order", X))[0]['x']
        amb = world.query((name, "ambition", X))[0]['x']
        rep = world.query((name, "reputation", X))[0]['x']
        print(f"  {name}: {job} in {home}")
        print(f"    ideology: tax={tax:+.1f}, war={war:+.1f}, order={order:+.1f}")
        print(f"    ambition={amb:.1f}, reputation={rep}")

    # Election
    print("\nElection:")
    elections = world.query((X, "is_a", "election"))
    for e in elections:
        eid = e['x']
        office = world.query((eid, "for_office", X))[0]['x']
        status = world.query((eid, "status", X))[0]['x']
        print(f"  {eid}: for {office}, status={status}")

    # Advance (rules fire)
    print("\n--- ADVANCING (rules fire) ---")
    world.advance()

    # Show stratification
    print("\n--- RULE STRATIFICATION ---")
    world.print_stratification()

    # Show candidates
    print("\n--- CANDIDATES ---")
    candidates = world.query((X, "candidate_for", var('e')))
    for c in candidates:
        name = c['x']
        election = c['e']
        print(f"  {name} is running in {election}")

    # Show votes
    print("\n--- VOTES CAST ---")
    Y = var('y')
    votes = world.query((X, "votes_for", Y))
    for v in votes:
        print(f"  {v['x']} votes for {v['y']}")

    # Show vote counts
    print("\n--- VOTE COUNTS ---")
    V = var('v')
    vote_counts = world.query((X, "vote_count", V))
    for vc in vote_counts:
        print(f"  {vc['x']}: {vc['v']} votes")

    # Show reputation bonuses
    print("\n--- REPUTATION BONUSES ---")
    B = var('b')
    rep_bonuses = world.query((X, "rep_bonus", B))
    for rb in rep_bonuses:
        print(f"  {rb['x']}: +{rb['b']:.1f} from reputation")

    # Show total scores
    print("\n--- TOTAL SCORES (votes + reputation) ---")
    T = var('t')
    total_scores = world.query((X, "total_score", T))
    for ts in sorted(total_scores, key=lambda x: -x['t']):
        print(f"  {ts['x']}: {ts['t']:.1f} total")

    # Show max scores per election
    print("\n--- MAX SCORES PER ELECTION ---")
    M = var('m')
    max_scores = world.query((X, "max_score", M))
    for ms in max_scores:
        print(f"  {ms['x']}: max score = {ms['m']:.1f}")

    # Show winners
    print("\n--- ELECTION WINNERS ---")
    W = var('w')
    winners = world.query((X, "winner", W))
    for w in winners:
        print(f"  {w['x']}: winner = {w['w']}")

    # Show office assignments
    print("\n--- OFFICE HOLDERS ---")
    O = var('o')
    holders = world.query((X, "office_holder", O))
    for h in holders:
        office_title = world.query((h['x'], "title", T))
        title = office_title[0]['t'] if office_title else h['x']
        office_jur = world.query((h['x'], "jurisdiction", var('j')))
        jur = office_jur[0]['j'] if office_jur else "unknown"
        print(f"  {title} of {jur}: {h['o']}")

    # Show election status
    print("\n--- ELECTION STATUS ---")
    S = var('s')
    status_results = world.query((X, "status", S))
    for sr in status_results:
        if 'election' in str(sr['x']):
            print(f"  {sr['x']}: {sr['s']}")

    # Provenance: why did the winner win?
    if winners:
        winner_name = winners[0]['w']
        election_id = winners[0]['x']
        print(f"\n--- PROVENANCE: Why did {winner_name} win {election_id}? ---")
        explanation = world.explain(election_id, "winner", winner_name)
        if explanation:
            _print_explanation(explanation)

    print("\n" + "=" * 70)
    print("POLITICS DEMO COMPLETE")
    print("=" * 70)


if __name__ == "__main__":
    main()
