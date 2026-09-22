-- A reader over a mutable segment (rows the transaction wrote that no persisted
-- segment holds yet) fetches those rows from the heap and evaluates the index
-- expressions on them. The expression state that takes used to live in
-- TopTransactionContext for the rest of the transaction, one per reader, so a
-- nested-loop rescan that opened a reader per outer row ran the backend out of
-- memory. The state now goes with the reader.

CREATE EXTENSION IF NOT EXISTS pg_search;

CREATE TABLE mutable_segment_expression_state (
    id bigint PRIMARY KEY,
    category text,
    body text
);
CREATE INDEX mutable_segment_expression_state_idx
ON mutable_segment_expression_state USING paradedb (id, ((category)::pdb.literal), body);

BEGIN;
-- Fewer rows than a mutable segment holds, so every one of them stays pending in memory.
INSERT INTO mutable_segment_expression_state
SELECT g, 'c' || (g % 10), 'body ' || g FROM generate_series(1, 500) g;

SELECT count(*) AS contexts_before
FROM pg_backend_memory_contexts WHERE name = 'ExprContext' \gset

-- A correlated scalar subquery runs once per outer row: two hundred readers, each over
-- the pending rows.
SELECT sum((SELECT count(*)
              FROM mutable_segment_expression_state
             WHERE id @@@ paradedb.term('category', 'c' || (g % 10)::text))) AS matches
FROM generate_series(1, 200) AS g;

SELECT count(*) - :contexts_before < 20 AS expression_contexts_freed
FROM pg_backend_memory_contexts WHERE name = 'ExprContext';
ROLLBACK;

DROP TABLE mutable_segment_expression_state;
