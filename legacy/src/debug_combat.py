"""Debug: Why isn't combat happening?"""

from herb_lang import load_herb_file, compile_program
from herb_core import var

program = load_herb_file("common_herb_combat_simple.herb")
world = compile_program(program)

X = var('x')
Y = var('y')

print("Before advance:")
print("\nAll is_alive facts:")
for f in world.all_facts():
    if f.relation == "is_alive":
        print(f"  {f}")

print("\nAll is_a facts:")
for f in world.all_facts():
    if f.relation == "is_a":
        print(f"  {f}")

world.advance()

print("\nAfter advance:")
print("\nAll is_alive facts:")
alive_facts = [f for f in world.all_facts() if f.relation == "is_alive"]
for f in alive_facts:
    print(f"  {f}")

if not alive_facts:
    print("  NONE - mark_alive didn't fire!")

print("\nAll can_attack facts:")
attack_facts = [f for f in world.all_facts() if f.relation == "can_attack"]
for f in attack_facts:
    print(f"  {f}")

if not attack_facts:
    print("  NONE - targeting didn't fire!")

print("\nAll HP facts:")
for f in world.all_facts():
    if f.relation == "hp" and f.is_alive(world.tick):
        print(f"  {f}")

# Try querying with different 'true' formats
print("\nDebug: trying different query formats for is_alive...")
q1 = world.query((X, "is_alive", True))
print(f"  (X, is_alive, True): {len(q1)} results")

q2 = world.query((X, "is_alive", "true"))
print(f"  (X, is_alive, 'true'): {len(q2)} results")
for q in q2:
    print(f"    {q}")
