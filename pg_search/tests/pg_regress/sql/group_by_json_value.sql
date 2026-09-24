-- =====================================================================
-- Grouping by a JSON value is left to Postgres
-- =====================================================================
-- `data->>'n'` is the text Postgres renders for the JSON value: `1.50`
-- for the number 1.50, `true` for the boolean. The index's fast field
-- holds the float 1.5 and the boolean as a number, so the aggregate scan
-- grouped under keys Postgres never produces (`1.5`, `1`), and with an
-- ORDER BY on an aggregate and a LIMIT the DataFusion backend failed on a
-- numeric value ("is not a Text column"). `data->'n'` could not be turned
-- into a jsonb datum at all. Both are grouped by Postgres now.

CREATE EXTENSION IF NOT EXISTS pg_search;
DROP TABLE IF EXISTS group_by_json_value;

CREATE TABLE group_by_json_value (
    id SERIAL PRIMARY KEY,
    description TEXT,
    data JSONB
);

INSERT INTO group_by_json_value (description, data) VALUES
    ('item', '{"n": 1.50}'),
    ('item', '{"n": 1.50}'),
    ('item', '{"n": 2}'),
    ('item', '{"n": "x"}'),
    ('item', '{"n": true}');

CREATE INDEX idx_group_by_json_value ON group_by_json_value USING paradedb (id, description, (data::pdb.literal));

-- Test 1: the text of a JSON value, in the keys Postgres renders
EXPLAIN (COSTS OFF) SELECT data->>'n' AS n, count(*) FROM group_by_json_value WHERE description @@@ 'item' GROUP BY 1 ORDER BY 1;
SELECT data->>'n' AS n, count(*) FROM group_by_json_value WHERE description @@@ 'item' GROUP BY 1 ORDER BY 1;

-- Test 2: ordered by the aggregate, with a LIMIT
SELECT data->>'n' AS n, count(*) FROM group_by_json_value WHERE description @@@ 'item' GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT 2;

-- Test 3: ordered by the aggregate alone, which the DataFusion backend answers
EXPLAIN (COSTS OFF) SELECT data->>'n' AS n, count(*) FROM group_by_json_value WHERE description @@@ 'item' GROUP BY 1 ORDER BY 2 DESC LIMIT 1;
SELECT data->>'n' AS n, count(*) FROM group_by_json_value WHERE description @@@ 'item' GROUP BY 1 ORDER BY 2 DESC LIMIT 1;

-- Test 4: the JSON value itself
SELECT data->'n' AS n, count(*) FROM group_by_json_value WHERE description @@@ 'item' GROUP BY 1 ORDER BY 1;

-- Test 5: a filter on a JSON value is still pushed down
EXPLAIN (COSTS OFF) SELECT count(*) FROM group_by_json_value WHERE description @@@ 'item' AND data->>'n' = 'x';
SELECT count(*) FROM group_by_json_value WHERE description @@@ 'item' AND data->>'n' = 'x';

DROP TABLE group_by_json_value;
