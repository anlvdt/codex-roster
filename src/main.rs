use std::process::ExitCode;

fn main() -> ExitCode {
    match codex_roster::cli::run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error:#}");
            ExitCode::FAILURE
        }
    }
}
