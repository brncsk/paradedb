-- =====================================================================
-- An aggregate's FILTER reads the heap for the scan's matches only
-- =====================================================================
-- A `FILTER` clause the index cannot answer becomes a heap filter. Its
-- own query was `all`, so the filter read the heap for every document of
-- the index, although the aggregation only visits the documents the scan
-- matches. The scan's query now takes the place of that `all`.

CREATE EXTENSION IF NOT EXISTS pg_search;
DROP TABLE IF EXISTS agg_filter_heap_matches;

CREATE TABLE agg_filter_heap_matches (
    id SERIAL PRIMARY KEY,
    description TEXT,
    payload TEXT,
    bucket INT
);

INSERT INTO agg_filter_heap_matches (description, payload, bucket)
SELECT CASE WHEN i % 2 = 0 THEN 'keeper' ELSE 'other' END,
       'row ' || i,
       i % 3
FROM generate_series(1, 20) i;

-- `payload` is not indexed, so a predicate on it is a heap filter.
CREATE INDEX idx_agg_filter_heap_matches ON agg_filter_heap_matches
USING paradedb (id, description, bucket);

-- Test 1: the FILTER's heap filter runs over the scan's query, not over `all`
EXPLAIN (COSTS OFF) SELECT count(*) FILTER (WHERE payload LIKE 'row 1%')
FROM agg_filter_heap_matches WHERE description @@@ 'keeper';
SELECT count(*) FILTER (WHERE payload LIKE 'row 1%')
FROM agg_filter_heap_matches WHERE description @@@ 'keeper';

-- Test 2: the same count with the aggregate scan off
SET paradedb.enable_aggregate_custom_scan = off;
SELECT count(*) FILTER (WHERE payload LIKE 'row 1%')
FROM agg_filter_heap_matches WHERE description @@@ 'keeper';
RESET paradedb.enable_aggregate_custom_scan;

-- Test 3: grouped, where the FILTER sits under the groups
EXPLAIN (COSTS OFF) SELECT bucket, count(*) FILTER (WHERE payload LIKE 'row 1%')
FROM agg_filter_heap_matches WHERE description @@@ 'keeper' GROUP BY 1 ORDER BY 1;
SELECT bucket, count(*) FILTER (WHERE payload LIKE 'row 1%')
FROM agg_filter_heap_matches WHERE description @@@ 'keeper' GROUP BY 1 ORDER BY 1;
SET paradedb.enable_aggregate_custom_scan = off;
SELECT bucket, count(*) FILTER (WHERE payload LIKE 'row 1%')
FROM agg_filter_heap_matches WHERE description @@@ 'keeper' GROUP BY 1 ORDER BY 1;
RESET paradedb.enable_aggregate_custom_scan;

DROP TABLE agg_filter_heap_matches;
