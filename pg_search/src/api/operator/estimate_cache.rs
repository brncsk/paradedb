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

//! A backend-local cache of the row estimates that planning asks the index for.
//!
//! To estimate a search, the planner opens a reader on the largest segment of the index and
//! runs the query on it ([`open_and_estimate_docs`](super::open_and_estimate_docs)). A query
//! that the statistics cannot estimate, such as a large term set, then builds its whole docset
//! at plan time. An application that runs the same search again and again (a row-level
//! security policy, a role's compiled query) paid for that on every plan.
//!
//! The cache keeps each estimate under the index, the query and the state of the index that the
//! estimate read: the largest segment's id, its document and deletion counts, and the live
//! documents of the whole index. A write, a merge or a vacuum that changes one of them gives a
//! new key, so a stale estimate is never read; it waits in the cache until the cache is full,
//! and then the cache starts again empty. Reading that state walks the segment meta list only:
//! no segment is opened.

use std::cell::RefCell;

use pgrx::pg_sys;
use tantivy::index::SegmentId;

use crate::api::HashMap;
use crate::index::reader::index::DocsEstimate;
use crate::postgres::rel::PgSearchRelation;
use crate::postgres::storage::block::{MVCCEntry, SegmentMetaEntry};
use crate::postgres::storage::metadata::MetaPage;
use crate::query::SearchQueryInput;

/// The most estimates that one backend keeps. Past it, the cache starts again empty.
const MAX_ENTRIES: usize = 512;

/// The state of an index that an estimate depends on, as the segment meta list records it.
///
/// It follows the segments that a reader with [`MvccSatisfies::LargestSegment`]
/// (crate::index::mvcc::MvccSatisfies) opens: the visible ones, without the empty mutable
/// segments. The estimate reads the largest of them and scales its count by the live documents
/// of all of them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(super) struct IndexFingerprint {
    largest_segment: Option<SegmentId>,
    largest_max_doc: u32,
    largest_deleted_docs: usize,
    live_docs: usize,
    segments: usize,
}

impl IndexFingerprint {
    /// Reads the fingerprint of `indexrel` from its segment meta list.
    pub(super) fn read(indexrel: &PgSearchRelation) -> Self {
        let mut fingerprint = IndexFingerprint {
            largest_segment: None,
            largest_max_doc: 0,
            largest_deleted_docs: 0,
            live_docs: 0,
            segments: 0,
        };
        let mut largest_docs = 0;

        let metapage = MetaPage::open(indexrel);
        let mut segment_metas = metapage.segment_metas();

        unsafe {
            segment_metas.for_each(|_, entry: SegmentMetaEntry| {
                if !entry.visible() || (entry.is_mutable() && entry.num_docs() == 0) {
                    return;
                }

                fingerprint.segments += 1;
                fingerprint.live_docs += entry.num_docs();

                // The first of the largest wins, as in `load_metas`.
                if entry.num_docs() > largest_docs {
                    largest_docs = entry.num_docs();
                    fingerprint.largest_segment = Some(entry.segment_id());
                    fingerprint.largest_max_doc = entry.max_doc();
                    fingerprint.largest_deleted_docs = entry.num_deleted_docs();
                }
            });
        }

        fingerprint
    }
}

/// What an estimate is kept under.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct EstimateKey {
    index: pg_sys::Oid,
    fingerprint: IndexFingerprint,
    /// The bits of the heap's `reltuples`, which the estimate scales to; `None` when unknown.
    reltuples: Option<u64>,
    /// The query, serialized: two queries with the same bytes run the same search.
    query: Vec<u8>,
}

thread_local! {
    static ESTIMATES: RefCell<HashMap<EstimateKey, DocsEstimate>> = RefCell::new(HashMap::default());
}

/// Returns the cached estimate of `query` on `indexrel`, or computes it with `estimate` and
/// keeps it.
///
/// `estimate` takes the query and runs only when the cache holds no estimate for the index in
/// the state that `fingerprint` describes. An estimate that `estimate` cannot give (`None`) is
/// not kept.
pub(super) fn cached_estimate(
    indexrel: &PgSearchRelation,
    fingerprint: IndexFingerprint,
    reltuples: Option<f64>,
    query: SearchQueryInput,
    estimate: impl FnOnce(SearchQueryInput) -> Option<DocsEstimate>,
) -> Option<DocsEstimate> {
    let Ok(query_bytes) = serde_json::to_vec(&query) else {
        return estimate(query);
    };
    let key = EstimateKey {
        index: indexrel.oid(),
        fingerprint,
        reltuples: reltuples.map(f64::to_bits),
        query: query_bytes,
    };

    if let Some(found) = ESTIMATES.with(|cache| cache.borrow().get(&key).copied()) {
        return Some(found);
    }

    let computed = estimate(query)?;

    ESTIMATES.with(|cache| {
        let mut cache = cache.borrow_mut();

        if cache.len() >= MAX_ENTRIES {
            cache.clear();
        }

        cache.insert(key, computed);
    });

    Some(computed)
}
