//! Real-usage fixture for the `card` feature combination.
//!
//! Exercises `ValidateCreditCard`, which is only exported when the `card`
//! feature pulls in the `card-validate` dependency.

use validator::ValidateCreditCard;

fn main() {
    assert!("4539571147647251".validate_credit_card());
    assert!(!"5236313877109141".validate_credit_card());
    println!("card_fixture: ok");
}
