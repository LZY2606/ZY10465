//! Real-usage fixture for the core (no-default-features) combination.
//!
//! Exercises the public entry points that must keep compiling without any
//! optional feature: the free-standing validation traits, a manual
//! `Validate` implementation and `ValidationErrors` aggregation.
//!
//! The runtime guard below is the tripwire the feature-matrix gate relies
//! on to detect feature pollution leaking in from a previously built
//! combination sharing the same target directory. It is only armed when the
//! gate declares this build to be the feature-free combination (via the
//! `VALIDATOR_MATRIX_CORE_COMBO` env var), so the example stays harmless when
//! compiled as part of `cargo test --workspace --all-features`.

use validator::{
    Validate, ValidateEmail, ValidateLength, ValidateRange, ValidationError, ValidationErrors,
};

struct Signup {
    email: String,
    age: u32,
}

impl Validate for Signup {
    fn validate(&self) -> Result<(), ValidationErrors> {
        let mut errors = ValidationErrors::new();
        if !self.email.validate_email() {
            let mut err = ValidationError::new("email");
            err.add_param(std::borrow::Cow::from("value"), &self.email);
            errors.add("email", err);
        }
        if !self.age.validate_range(Some(18u32), None, None, None) {
            errors.add("age", ValidationError::new("range"));
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors)
        }
    }
}

fn main() {
    if option_env!("VALIDATOR_MATRIX_CORE_COMBO").is_some() {
        for leaked in ["derive", "card", "indexmap"] {
            let leaked_active = match leaked {
                "derive" => cfg!(feature = "derive"),
                "card" => cfg!(feature = "card"),
                _ => cfg!(feature = "indexmap"),
            };
            if leaked_active {
                eprintln!("feature pollution: `{leaked}` leaked into the core-only combination");
                std::process::exit(1);
            }
        }
    }

    let signup = Signup { email: "not-an-email".to_string(), age: 12 };
    let errors = signup.validate().expect_err("fixture data must be invalid");
    let kinds = errors.errors();
    assert!(kinds.contains_key("email"));
    assert!(kinds.contains_key("age"));

    assert!("hello".validate_length(Some(2u64), Some(10u64), None));
    assert!("user@example.com".validate_email());

    println!("core_fixture: ok");
}
