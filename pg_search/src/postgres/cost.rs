// Copyright (c) 2023-2026 ParadeDB, Inc.
//
// This file is part of ParadeDB - Postgres for Search and Analytics
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.

use crate::index::mvcc::MvccSatisfies;
use crate::postgres::rel::PgSearchRelation;
use crate::{DEFAULT_STARTUP_COST, MUTABLE_ROW_COST_FACTOR, UNKNOWN_SELECTIVITY};
use pgrx::*;
use std::sync::atomic::Ordering;
use tantivy::Index;

/// What a scan of the index costs before its first row: [`DEFAULT_STARTUP_COST`] for the query,
/// one random page per segment (a reader opens every segment's components through the buffer
/// cache), and the rows of a mutable segment, which a reader fetches from the heap, evaluates
/// the index expressions on and indexes in memory before it can search them. A path pays this on
/// every rescan, so a nested loop with a search on its inner side is costed as the repeated
/// opens it is.
pub(crate) fn scan_startup_cost(segment_count: usize, mutable_docs: u64) -> f64 {
    let random_page_cost = unsafe { *std::ptr::addr_of!(pg_sys::random_page_cost) };
    let cpu_tuple_cost = unsafe { *std::ptr::addr_of!(pg_sys::cpu_tuple_cost) };
    DEFAULT_STARTUP_COST
        + segment_count as f64 * random_page_cost
        + mutable_docs as f64 * MUTABLE_ROW_COST_FACTOR * cpu_tuple_cost
}

/// The segment count and the mutable segments' document count of the index, as
/// [`scan_startup_cost`] wants them. Opens the index once.
pub(crate) fn scan_startup_counts(indexrel: &PgSearchRelation) -> (usize, u64) {
    let directory = MvccSatisfies::LargestSegment.directory(indexrel);
    // The counts are only valid after the index has been opened.
    let segment_count = directory.total_segment_count();
    let mutable_docs = directory.total_mutable_docs();
    Index::open(directory).expect("scan_startup_counts: should be able to open index");
    (
        segment_count.load(Ordering::Relaxed),
        mutable_docs.load(Ordering::Relaxed) as u64,
    )
}

#[allow(clippy::too_many_arguments)]
#[pg_guard(immutable, parallel_safe)]
pub unsafe extern "C-unwind" fn amcostestimate(
    _root: *mut pg_sys::PlannerInfo,
    path: *mut pg_sys::IndexPath,
    _loop_count: f64,
    index_startup_cost: *mut pg_sys::Cost,
    index_total_cost: *mut pg_sys::Cost,
    index_selectivity: *mut pg_sys::Selectivity,
    index_correlation: *mut f64,
    index_pages: *mut f64,
) {
    assert!(!path.is_null());
    assert!(!(*path).indexinfo.is_null());

    let indexrel = unsafe {
        PgRelation::with_lock(
            (*(*path).indexinfo).indexoid,
            pg_sys::AccessShareLock as pg_sys::LOCKMODE,
        )
    };
    let index_clauses = PgList::<pg_sys::IndexClause>::from_pg((*path).indexclauses);
    // TODO: Convert to use RowEstimate.
    let reltuples = indexrel
        .heap_relation()
        .expect("index relation must have a valid corresponding heap relation")
        .reltuples()
        .unwrap_or(1.0) as f64;
    let page_estimate = pg_sys::RelationGetNumberOfBlocksInFork(
        indexrel.as_ptr(),
        pg_sys::ForkNumber::MAIN_FORKNUM,
    );
    drop(indexrel);

    // start these at zero
    *index_selectivity = 0.0;
    *index_pages = 0.0;
    *index_total_cost = 0.0;

    // we output rows in random order relative to the heap's ctid ordering
    *index_correlation = 0.0;

    // it does cost to start up: the tantivy query, and the open of every segment and of the
    // rows a mutable segment holds, as for the custom scan
    *index_startup_cost = {
        let indexrel = PgSearchRelation::with_lock(
            (*(*path).indexinfo).indexoid,
            pg_sys::AccessShareLock as pg_sys::LOCKMODE,
        );
        let (segment_count, mutable_docs) = scan_startup_counts(&indexrel);
        scan_startup_cost(segment_count, mutable_docs)
    };

    // choose the smallest selectivity from the RestrictInfo clauses that have already done their estimations
    *index_selectivity = if index_clauses.is_empty() {
        1.0
    } else {
        index_clauses
            .iter_ptr()
            .map(|clause| (*(*clause).rinfo).norm_selec)
            .filter(|norm| *norm > 0.0)
            .min_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Greater))
            .unwrap_or(UNKNOWN_SELECTIVITY)
    };

    // use the selectivity to further estimate how many postgres pages we'd read,
    // if in fact we were based on Postgres' block storage
    *index_pages = *index_selectivity * page_estimate as f64;

    // total cost is just a hardcoded value of the cost to read a tuple from an index times the
    // estimated number of rows we expect to return
    *index_total_cost =
        *index_startup_cost + *index_selectivity * reltuples * pg_sys::cpu_index_tuple_cost;
}
