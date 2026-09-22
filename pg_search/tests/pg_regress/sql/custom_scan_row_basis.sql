-- A table that got its rows after its index was created keeps reltuples at
-- zero until it is analyzed. The custom scan then costed every query over it
-- as one row at a fixed cost, which put it on the inner side of nested loops
-- that rescanned it once per outer row. The row basis now falls back to the
-- index's own document count when the heap has no statistics.

CREATE EXTENSION IF NOT EXISTS pg_search;

CREATE TABLE custom_scan_row_basis (
    id bigint PRIMARY KEY,
    category text,
    body text
);
CREATE INDEX custom_scan_row_basis_idx
ON custom_scan_row_basis USING paradedb (id, ((category)::pdb.literal), body);
INSERT INTO custom_scan_row_basis
SELECT g, 'c' || (g % 10), 'body ' || g FROM generate_series(1, 10000) g;

-- No ANALYZE has run: the heap carries no statistics.
SELECT reltuples FROM pg_class WHERE oid = 'custom_scan_row_basis'::regclass;

-- The estimated rows of the custom scan in the plan of `q`.
CREATE FUNCTION custom_scan_row_basis_plan_rows(q text) RETURNS numeric AS $$
DECLARE plan jsonb;
BEGIN
  EXECUTE 'EXPLAIN (FORMAT JSON) ' || q INTO plan;
  RETURN (jsonb_path_query_first(plan, 'strict $.** ? (@."Node Type" == "Custom Scan")."Plan Rows"'))::numeric;
END $$ LANGUAGE plpgsql;

-- A constant query is estimated by the index: a tenth of the rows match.
SELECT custom_scan_row_basis_plan_rows(
  $$SELECT * FROM custom_scan_row_basis WHERE id @@@ paradedb.term('category', 'c1')$$
) BETWEEN 500 AND 2000 AS constant_query_rows_from_the_index;

-- With statistics the estimate is the same.
ANALYZE custom_scan_row_basis;
SELECT custom_scan_row_basis_plan_rows(
  $$SELECT * FROM custom_scan_row_basis WHERE id @@@ paradedb.term('category', 'c1')$$
) BETWEEN 500 AND 2000 AS constant_query_rows_with_statistics;

DROP FUNCTION custom_scan_row_basis_plan_rows(text);
DROP TABLE custom_scan_row_basis;
