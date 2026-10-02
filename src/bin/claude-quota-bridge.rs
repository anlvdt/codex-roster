fn main() {
    if let Err(error) = codex_roster::claude_quota_bridge::run() {
        eprintln!("Claude quota bridge: {error:#}");
        std::process::exit(1);
    }
}
