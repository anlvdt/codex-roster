use std::process::ExitCode;

fn main() -> ExitCode {
    // `--json` callers get a machine-readable error object on stdout; humans
    // keep the `error:` line on stderr (audit OUT-03).
    let json_requested = std::env::args().any(|argument| argument == "--json");
    match codex_roster::cli::run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            let (code, kind, hint) = codex_roster::cli::classify_error(&error);
            if json_requested {
                let payload = serde_json::json!({
                    "contract_version": codex_roster::cli::CONTRACT_VERSION,
                    "error": {
                        "code": kind,
                        "message": format!("{error:#}"),
                        "hint": hint,
                    }
                });
                println!("{payload}");
            }
            eprintln!("error: {error:#}");
            ExitCode::from(code)
        }
    }
}
