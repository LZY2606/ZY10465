//! Real-usage fixture for the `derive` feature combination.
//!
//! Exercises the derive macro's generated call graph for the `nested`,
//! `schema`, `range`, `length`, `email` and `custom` rules and asserts that
//! field paths and rule parameters are aggregated into `ValidationErrors`.

use validator::{Validate, ValidationError, ValidationErrorsKind};

#[derive(Debug, Validate)]
struct Address {
    #[validate(length(min = 2, max = 32))]
    street: String,
}

fn validate_username(username: &str) -> Result<(), ValidationError> {
    if username.chars().any(char::is_whitespace) {
        return Err(ValidationError::new("username_whitespace"));
    }
    Ok(())
}

#[derive(Debug, Validate)]
#[validate(schema(function = "validate_signup_schema"))]
struct Signup {
    #[validate(email)]
    email: String,
    #[validate(length(min = 3, max = 16))]
    name: String,
    #[validate(range(min = 18, max = 120))]
    age: u32,
    #[validate(custom(function = "validate_username"))]
    username: String,
    #[validate(nested)]
    address: Address,
}

fn validate_signup_schema(signup: &Signup) -> Result<(), ValidationError> {
    if signup.username == "admin" && signup.age < 120 {
        return Err(ValidationError::new("reserved_username"));
    }
    Ok(())
}

fn field_errors<'a>(
    kinds: &'a std::collections::HashMap<std::borrow::Cow<'static, str>, ValidationErrorsKind>,
    field: &str,
) -> &'a [ValidationError] {
    match kinds.get(field) {
        Some(ValidationErrorsKind::Field(errors)) => errors,
        other => panic!("`{field}` must aggregate field errors got: {other:?}"),
    }
}

fn main() {
    let signup = Signup {
        email: "not-an-email".to_string(),
        name: "x".to_string(),
        age: 12,
        username: "bad name".to_string(),
        address: Address { street: "s".to_string() },
    };

    let errors = signup.validate().expect_err("fixture data must be invalid");
    let kinds = errors.errors();

    // Field paths produced by the derive-generated call graph.
    for field in ["email", "name", "age", "username", "address"] {
        assert!(kinds.contains_key(field), "missing field path `{field}` in {kinds:?}");
    }

    // `email` carries the offending value as a parameter.
    let email_errors = field_errors(kinds, "email");
    assert_eq!(email_errors[0].code, "email");
    assert!(email_errors[0].params.contains_key("value"));

    // `length` aggregates the violated boundaries as parameters.
    let name_errors = field_errors(kinds, "name");
    assert!(name_errors[0].params.contains_key("min"));
    assert!(name_errors[0].params.contains_key("max"));

    // `range` aggregates its boundaries as parameters.
    let age_errors = field_errors(kinds, "age");
    assert!(age_errors[0].params.contains_key("min"));
    assert!(age_errors[0].params.contains_key("max"));

    // `custom` surfaces the custom error code.
    let username_errors = field_errors(kinds, "username");
    assert_eq!(username_errors[0].code, "username_whitespace");

    // `nested` recurses into the nested struct's own call graph.
    match &kinds["address"] {
        ValidationErrorsKind::Struct(address_errors) => {
            assert!(address_errors.errors().contains_key("street"));
        }
        other => panic!("`address` must aggregate nested errors, got: {other:?}"),
    }

    // `schema` errors are aggregated at the struct level under `__all__`
    // once every field-level rule has passed.
    let schema_only = Signup {
        email: "user@example.com".to_string(),
        name: "validname".to_string(),
        age: 30,
        username: "admin".to_string(),
        address: Address { street: "main street".to_string() },
    };
    let schema_errors = schema_only.validate().expect_err("schema rule must fire");
    let all_errors = field_errors(schema_errors.errors(), "__all__");
    assert_eq!(all_errors[0].code, "reserved_username");

    println!("derive_fixture: ok");
}
