//! Real-usage fixture for the `indexmap` feature combination.
//!
//! Exercises the `ValidateLength` implementations that only exist when the
//! `indexmap` feature extends the core length validator to `IndexMap` and
//! `IndexSet`.

use indexmap::{IndexMap, IndexSet};
use validator::ValidateLength;

fn main() {
    let mut map: IndexMap<String, u32> = IndexMap::new();
    map.insert("a".to_string(), 1);
    map.insert("b".to_string(), 2);
    assert!(map.validate_length(Some(1u64), Some(3u64), None));
    assert!(!map.validate_length(Some(3u64), None, None));

    let mut set: IndexSet<String> = IndexSet::new();
    set.insert("only".to_string());
    assert!(set.validate_length(None, None, Some(1u64)));

    println!("indexmap_fixture: ok");
}
