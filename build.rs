#[cfg(target_os = "windows")]
fn main() {
    println!("cargo:rerun-if-changed=assets/codex-roster.ico");
    winresource::WindowsResource::new()
        .set_icon("assets/codex-roster.ico")
        .compile()
        .expect("failed to embed Windows icon resource");
}

#[cfg(not(target_os = "windows"))]
fn main() {}
