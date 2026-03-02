"""Debug loot issue"""

from herb_lang import load_herb_file, compile_program
from herb_core import var

program = load_herb_file("common_herb_combat_simple.herb")
world = compile_program(program)
world.advance()

X = var('x')

print("After combat:")
print("\nis_dead facts:")
for f in world.all_facts():
    if f.relation == "is_dead" and f.is_alive(world.tick):
        print(f"  {f}")

print("\nloot_gold facts:")
for f in world.all_facts():
    if f.relation == "loot_gold" and f.is_alive(world.tick):
        print(f"  {f}")

print("\ngold facts:")
for f in world.all_facts():
    if f.relation == "gold" and f.is_alive(world.tick):
        print(f"  {f}")

# Check wolf's death status
wolf_dead = world.query(("wolf", "is_dead", True))
print(f"\nwolf is_dead: {wolf_dead}")

wolf_loot = world.query(("wolf", "loot_gold", X))
print(f"wolf loot_gold: {wolf_loot}")
