-- =====================================================================
-- A pushdown whose value comes from a column is left to Postgres
-- =====================================================================
-- The value of a pushed-down comparison is solved once, before the scan
-- reads its first row. A value that a row supplies has no row to come
-- from, and solving it read a column of a tuple slot that holds no
-- tuple, which terminated the backend. A cast of a JSON value takes this
-- path: the left side resolves to the indexed field `data.a`, and the
-- right side reads the same column.

CREATE EXTENSION IF NOT EXISTS pg_search;
DROP TABLE IF EXISTS pushdown_value_from_column;

CREATE TABLE pushdown_value_from_column (
    id SERIAL PRIMARY KEY,
    description TEXT,
    data JSONB
);

INSERT INTO pushdown_value_from_column (description, data)
SELECT 'item', jsonb_build_object('a', i, 'b', 5) FROM generate_series(1, 10) i;

CREATE INDEX idx_pushdown_value_from_column ON pushdown_value_from_column
USING paradedb (id, description, (data::pdb.literal));

-- Test 1: a comparison of two JSON values of the same row: 5 rows have a > b
EXPLAIN (COSTS OFF) SELECT count(*) FROM pushdown_value_from_column
WHERE description @@@ 'item' AND (data->>'a')::float > (data->>'b')::float;
SELECT count(*) FROM pushdown_value_from_column
WHERE description @@@ 'item' AND (data->>'a')::float > (data->>'b')::float;

-- Test 2: the same comparison as an aggregate's FILTER
SELECT count(*) FILTER (WHERE (data->>'a')::float > (data->>'b')::float)
FROM pushdown_value_from_column WHERE description @@@ 'item';

-- Test 3: a comparison with a constant is still pushed down
EXPLAIN (COSTS OFF) SELECT count(*) FROM pushdown_value_from_column
WHERE description @@@ 'item' AND (data->>'a')::float > 5;
SELECT count(*) FROM pushdown_value_from_column
WHERE description @@@ 'item' AND (data->>'a')::float > 5;

DROP TABLE pushdown_value_from_column;
