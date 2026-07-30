pub const PRODUCT_NAME: &str = "Codex Roster";
pub const CLI_NAME: &str = "codex-roster";

pub mod app;
pub mod backup;
pub mod cli;
pub mod codex;
pub mod env;
pub mod file_store;
pub mod identity;
pub mod model;
pub mod openai_status;
pub mod process;
pub mod repository;
pub mod reset_tracker;
pub mod secrets;
pub mod settings;
mod time_display;
pub mod token_usage;
#[cfg(windows)]
pub mod tray;
pub mod usage;
