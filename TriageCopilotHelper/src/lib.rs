//! The deliberately narrow process boundary between Triage and Copilot.
//!
//! This crate neither discovers nor starts a Copilot CLI.  A future signed
//! bundle may provide that runtime through [`engine::CopilotEngine`].

pub mod cache;
pub mod engine;
pub mod environment;
pub mod protocol;
pub mod schema;
