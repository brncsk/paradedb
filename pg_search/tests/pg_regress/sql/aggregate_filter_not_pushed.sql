-- =====================================================================
-- An aggregate whose FILTER the aggregate scan cannot evaluate is left
-- to Postgres
-- =====================================================================
-- The aggregate scan used to drop a FILTER it could not turn into a
-- search query or a heap filter (here, a comparison of two columns) and
-- aggregate every row, so `count(*) FILTER (WHERE a > b)` counted the
-- rows the FILTER excludes too.

CREATE EXTENSION IF NOT EXISTS pg_search;
DROP TABLE IF EXISTS agg_filter_not_pushed;

CREATE TABLE agg_filter_not_pushed (
    id SERIAL PRIMARY KEY,
    description TEXT,
    a INT,
    b INT
);

INSERT INTO agg_filter_not_pushed (description, a, b)
SELECT 'item ' || i, i % 10, 5 FROM generate_series(1, 100) i;

CREATE INDEX idx_agg_filter_not_pushed ON agg_filter_not_pushed
USING paradedb (id, description, a, b);

-- Test 1: a FILTER comparing two columns: 40 rows have a > b
EXPLAIN (COSTS OFF) SELECT count(*) FILTER (WHERE a > b) FROM agg_filter_not_pushed WHERE description @@@ 'item';
SELECT count(*) FILTER (WHERE a > b) FROM agg_filter_not_pushed WHERE description @@@ 'item';

-- Test 2: beside an aggregate without a FILTER
SELECT count(*), count(*) FILTER (WHERE a > b) FROM agg_filter_not_pushed WHERE description @@@ 'item';

-- Test 3: a FILTER the scan can evaluate is still pushed down
EXPLAIN (COSTS OFF) SELECT count(*) FILTER (WHERE a = 3) FROM agg_filter_not_pushed WHERE description @@@ 'item';
SELECT count(*) FILTER (WHERE a = 3) FROM agg_filter_not_pushed WHERE description @@@ 'item';

DROP TABLE agg_filter_not_pushed;
