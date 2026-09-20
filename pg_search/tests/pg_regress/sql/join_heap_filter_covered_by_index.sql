-- A DataFusion scan (the join scan, and the aggregate scan over a join)
-- evaluates a heap filter once per document the search matches, against
-- the heap, and has no bitmap to intersect. When another index of the
-- table covers such a clause, the relation is left to Postgres, whose base
-- scan intersects that index's bitmap with the search and never fetches
-- the rows the clause rejects.

CREATE EXTENSION IF NOT EXISTS pg_search;
SET max_parallel_workers_per_gather = 0;
SET paradedb.enable_aggregate_custom_scan TO on;
SET paradedb.enable_join_custom_scan TO on;

CREATE TABLE covered_places (
    id BIGINT PRIMARY KEY,
    name TEXT,
    location POINT
);

CREATE TABLE covered_shapes (
    id BIGINT PRIMARY KEY,
    place_id BIGINT,
    kind TEXT
);

-- 10k places on a 100x100 grid, one shape each.
INSERT INTO covered_places (id, name, location)
SELECT i, 'place ' || i, point(i % 100, i / 100)
FROM generate_series(0, 9999) i;

INSERT INTO covered_shapes (id, place_id, kind)
SELECT i, i, CASE WHEN i % 2 = 0 THEN 'footprint' ELSE 'body' END
FROM generate_series(0, 9999) i;

CREATE INDEX covered_places_idx ON covered_places USING paradedb (id, name);
CREATE INDEX covered_places_location ON covered_places USING gist (location);
CREATE INDEX covered_shapes_idx ON covered_shapes USING paradedb (id, place_id, kind);
VACUUM ANALYZE covered_places, covered_shapes;

-- A count over the join, whose location test the GiST index covers: the
-- aggregate scan declines, and the places' base scan intersects the
-- GiST bitmap with the search.
EXPLAIN (FORMAT TEXT, COSTS OFF, TIMING OFF)
SELECT count(*)
FROM covered_places p
JOIN covered_shapes s ON s.place_id = p.id
WHERE p.name ||| 'place'
  AND p.location <@ box '((10,10),(12,12))'
  AND s.kind ||| 'footprint';

SELECT count(*)
FROM covered_places p
JOIN covered_shapes s ON s.place_id = p.id
WHERE p.name ||| 'place'
  AND p.location <@ box '((10,10),(12,12))'
  AND s.kind ||| 'footprint';

-- The join scan declines the same relation for a Top-K over the join.
EXPLAIN (FORMAT TEXT, COSTS OFF, TIMING OFF)
SELECT p.id, s.id
FROM covered_places p
JOIN covered_shapes s ON s.place_id = p.id
WHERE p.name ||| 'place'
  AND p.location <@ box '((10,10),(12,12))'
  AND s.kind ||| 'footprint'
ORDER BY p.id
LIMIT 5;

SELECT p.id, s.id
FROM covered_places p
JOIN covered_shapes s ON s.place_id = p.id
WHERE p.name ||| 'place'
  AND p.location <@ box '((10,10),(12,12))'
  AND s.kind ||| 'footprint'
ORDER BY p.id
LIMIT 5;

-- Without the bitmap intersection no index covers the clause for the
-- search, and the DataFusion scans take the join, with the same answers.
SET paradedb.enable_bitmap_intersection = off;

EXPLAIN (FORMAT TEXT, COSTS OFF, TIMING OFF)
SELECT count(*)
FROM covered_places p
JOIN covered_shapes s ON s.place_id = p.id
WHERE p.name ||| 'place'
  AND p.location <@ box '((10,10),(12,12))'
  AND s.kind ||| 'footprint';

SELECT count(*)
FROM covered_places p
JOIN covered_shapes s ON s.place_id = p.id
WHERE p.name ||| 'place'
  AND p.location <@ box '((10,10),(12,12))'
  AND s.kind ||| 'footprint';

RESET paradedb.enable_bitmap_intersection;

DROP TABLE covered_shapes;
DROP TABLE covered_places;
