use std::io::Write;
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

pub(crate) const SERVICE: &str = "Claude Code-credentials";

const SECURITY: &str = "/usr/bin/security";
const NOT_FOUND_RC: i32 = 44;
const TIMEOUT: Duration = Duration::from_secs(5);
const STDIN_LINE_LIMIT: usize = 4096 - 64;

pub(crate) fn account_name() -> String {
    std::env::var("USER")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| {
            std::env::var("USERNAME")
                .ok()
                .filter(|value| !value.is_empty())
        })
        .unwrap_or_else(|| "claude-code-user".to_owned())
}

fn quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

fn hex_encode(value: &str) -> String {
    value.bytes().map(|byte| format!("{byte:02x}")).collect()
}

fn use_stdin(command_line: &str) -> bool {
    command_line.len() <= STDIN_LINE_LIMIT
}

fn drain_pipe(pipe: impl std::io::Read + Send + 'static) -> thread::JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let mut pipe = pipe;
        let mut buf = Vec::new();
        let _ = pipe.read_to_end(&mut buf);
        buf
    })
}

fn wait_with_timeout(mut child: Child) -> Result<Output> {
    let stdout = child.stdout.take().map(drain_pipe);
    let stderr = child.stderr.take().map(drain_pipe);
    let deadline = Instant::now() + TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                let stdout = stdout
                    .map(|t| t.join().unwrap_or_default())
                    .unwrap_or_default();
                let stderr = stderr
                    .map(|t| t.join().unwrap_or_default())
                    .unwrap_or_default();
                let status: ExitStatus = child.wait().context("security wait failed")?;
                return Ok(Output {
                    status,
                    stdout,
                    stderr,
                });
            }
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    bail!("security invocation timed out after {}s", TIMEOUT.as_secs());
                }
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => return Err(error).context("security wait failed"),
        }
    }
}

pub(crate) fn get_password(service: &str, account: &str) -> Result<Option<String>> {
    let child = Command::new(SECURITY)
        .args(["find-generic-password", "-a", account, "-w", "-s", service])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to spawn /usr/bin/security")?;
    let output = wait_with_timeout(child)?;
    match output.status.code() {
        Some(0) => {
            let mut text =
                String::from_utf8(output.stdout).context("security output is not UTF-8")?;
            if text.ends_with('\n') {
                text.pop();
            }
            Ok(Some(text))
        }
        Some(NOT_FOUND_RC) => Ok(None),
        code => bail!(
            "security find-generic-password failed (rc={:?}): {}",
            code,
            String::from_utf8_lossy(&output.stderr).trim()
        ),
    }
}

pub(crate) fn set_password(service: &str, account: &str, value: &str) -> Result<()> {
    let hex = hex_encode(value);
    let line = format!(
        "add-generic-password -U -a {} -s {} -X {hex}\n",
        quote(account),
        quote(service)
    );
    let output = if use_stdin(&line) {
        let mut child = Command::new(SECURITY)
            .arg("-i")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("failed to spawn /usr/bin/security -i")?;
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(line.as_bytes());
        }
        wait_with_timeout(child)?
    } else {
        let child = Command::new(SECURITY)
            .args([
                "add-generic-password",
                "-U",
                "-a",
                account,
                "-s",
                service,
                "-X",
                &hex,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("failed to spawn /usr/bin/security")?;
        wait_with_timeout(child)?
    };
    if !output.status.success() {
        bail!(
            "security add-generic-password failed (rc={:?}): {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(())
}

#[allow(dead_code)]
pub(crate) fn delete_password(service: &str, account: &str) -> Result<()> {
    let child = Command::new(SECURITY)
        .args(["delete-generic-password", "-a", account, "-s", service])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("failed to spawn /usr/bin/security")?;
    let output = wait_with_timeout(child)?;
    match output.status.code() {
        Some(0) | Some(NOT_FOUND_RC) => Ok(()),
        code => bail!(
            "security delete-generic-password failed (rc={:?}): {}",
            code,
            String::from_utf8_lossy(&output.stderr).trim()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_escapes_backslash_and_quote() {
        assert_eq!(quote("a\"b\\c"), "\"a\\\"b\\\\c\"");
        assert_eq!(quote("plain"), "\"plain\"");
    }

    #[test]
    fn hex_encoding_round_trips_ascii() {
        assert_eq!(hex_encode("ab"), "6162");
        assert_eq!(hex_encode(""), "");
    }

    #[test]
    fn stdin_threshold_decision() {
        let short = "x".repeat(STDIN_LINE_LIMIT);
        assert!(use_stdin(&short));
        assert!(!use_stdin(&format!("{short}x")));
    }

    #[test]
    #[ignore]
    fn keychain_round_trip() {
        let service = "codex-roster-test";
        let account = "codex-roster-test-account";
        set_password(service, account, "hello-secret").expect("set");
        assert_eq!(
            get_password(service, account).expect("get"),
            Some("hello-secret".to_owned())
        );
        delete_password(service, account).expect("delete");
        assert_eq!(get_password(service, account).expect("get"), None);
    }
}
