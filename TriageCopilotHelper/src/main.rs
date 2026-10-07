use std::{io, sync::Arc};

use triage_copilot_helper::{
    engine::{FailClosedCopilotEngine, TrustedRuntimeConfiguration},
    protocol::{read_trusted_runtime_bootstrap, serve_stdio},
};

fn main() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("Tokio runtime initialization failed");

    // The verified XPC launcher sends one bounded bootstrap frame before every
    // request. No command-line argument or inherited environment can select a
    // runtime, profile, or working directory. Invalid bootstrap input leaves
    // the engine fail-closed without writing paths to stderr.
    let engine = trusted_engine_from_pipe().unwrap_or_default();

    if runtime
        .block_on(async {
            let mut termination =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    .expect("Termination signal initialization failed");
            tokio::select! {
                result = serve_stdio(Arc::new(engine)) => result,
                // Dropping the in-flight login future kills its owned CLI.
                // XPC sends TERM before its bounded SIGKILL fallback.
                _ = termination.recv() => Ok(()),
            }
        })
        .map_err(|error| eprintln!("TriageCopilotHelper protocol error: {error}"))
        .is_err()
    {
        std::process::exit(1);
    }
}

fn trusted_engine_from_pipe() -> Option<FailClosedCopilotEngine> {
    // Reject every invocation argument. The input pipe is still consumed first
    // so this failure cannot be transformed into a later request parse error.
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    let bootstrap = read_trusted_runtime_bootstrap(&mut reader).ok()?;
    if std::env::args_os().len() != 1 {
        return None;
    }
    let configuration = TrustedRuntimeConfiguration::from_bootstrap(bootstrap).ok()?;
    Some(FailClosedCopilotEngine::from_trusted_runtime(configuration))
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;
    use triage_copilot_helper::protocol::read_trusted_runtime_bootstrap;

    #[test]
    fn malformed_bootstrap_is_rejected_before_requests() {
        let mut input = Cursor::new([0, 0, 0, 2, b'{', b'}']);
        assert!(read_trusted_runtime_bootstrap(&mut input).is_err());
    }
}
