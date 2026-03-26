#!/usr/bin/env python3
"""Generate pgdb-seed.sql for the /pgdb async database endpoint.

Produces the same 100K rows as generate-db.py (same Random(42) seed)
but with Postgres-native types (BOOLEAN, JSONB). The output SQL file
can be mounted into a Postgres container at /docker-entrypoint-initdb.d/
for automatic initialization.
"""
import json, sys, os, random

script_dir = os.path.dirname(os.path.abspath(__file__))
root_dir = os.path.dirname(script_dir)

data_file = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root_dir, "data/dataset.json")
sql_file = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root_dir, "data/pgdb-seed.sql")

seed_data = json.load(open(data_file))
TARGET_ROWS = 100_000

rng = random.Random(42)  # same seed as generate-db.py
categories = [d["category"] for d in seed_data]
names = [d["name"] for d in seed_data]
all_tags = []
for d in seed_data:
    all_tags.extend(d["tags"])
all_tags = sorted(set(all_tags))

with open(sql_file, 'w') as f:
    f.write("""CREATE TABLE items (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    price DOUBLE PRECISION NOT NULL,
    quantity INTEGER NOT NULL,
    active BOOLEAN NOT NULL,
    tags JSONB NOT NULL,
    rating_score DOUBLE PRECISION NOT NULL,
    rating_count INTEGER NOT NULL
);
-- NO index on price — forces sequential scan

COPY items (id, name, category, price, quantity, active, tags, rating_score, rating_count) FROM STDIN;
""")

    for i in range(1, TARGET_ROWS + 1):
        base = seed_data[(i - 1) % len(seed_data)]
        price = round(rng.uniform(1.0, 500.0), 2)
        quantity = rng.randint(1, 1000)
        active = rng.choice([0, 1])
        ntags = rng.randint(1, 4)
        tags = json.dumps(rng.sample(all_tags, min(ntags, len(all_tags))))
        name = f"{rng.choice(names)} {i}"
        category = rng.choice(categories)
        rating_score = round(rng.uniform(1.0, 5.0), 1)
        rating_count = rng.randint(1, 500)

        active_str = 't' if active else 'f'
        # Escape backslashes and tabs in text fields for COPY format
        name_esc = name.replace('\\', '\\\\').replace('\t', '\\t')
        category_esc = category.replace('\\', '\\\\').replace('\t', '\\t')

        f.write(f"{i}\t{name_esc}\t{category_esc}\t{price}\t{quantity}\t{active_str}\t{tags}\t{rating_score}\t{rating_count}\n")

    f.write("\\.\n")
    f.write(f"\n-- Verify: SELECT COUNT(*) FROM items; -- should return {TARGET_ROWS}\n")

size = os.path.getsize(sql_file)
print(f"Created {sql_file}: {TARGET_ROWS} rows, {size / 1024 / 1024:.1f} MB")
