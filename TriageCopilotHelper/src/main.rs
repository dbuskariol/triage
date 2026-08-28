use std::sync::Arc;

use triage_copilot_helper::{engine::UnavailableCopilotEngine, protocol::serve_stdio};

fn main() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("Tokio runtime initialization failed");

    if runtime
        .block_on(serve_stdio(Arc::new(UnavailableCopilotEngine)))
        .map_err(|error| eprintln!("TriageCopilotHelper protocol error: {error}"))
        .is_err()
    {
        std::process::exit(1);
    }
}
