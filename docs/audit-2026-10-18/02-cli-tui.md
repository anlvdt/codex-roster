# Audit CLI & TUI — Codex Roster (2026-10-18)

Auditor: `cli-tui-auditor` (task-2). Snapshot: `8f27e8ce8fed3f0a83320623c933e1d87b4d7cdc` (v0.5.0).
Read-only trên source. Chỉ tạo file này. Không chạy lệnh app (save/activate/delete/import/export/login/refresh-usage/…), không network, không Keychain, không ghi `~/.codex`; chỉ `--help`, `--version`, parse-level và đọc source. Không chạy `cargo test` (tránh lock target dir).

## Phạm vi & phương pháp

**Phạm vi:** toàn bộ bề mặt command-line + interactive terminal của crate Rust, và contract mà macOS app tiêu thụ.

| Vùng | File chính | Ghi chú |
|---|---|---|
| Clap surface + dispatch | `src/cli.rs` (1631 LOC) | `run()` từ 369–1149 là một match 33 nhánh; 4 test parse |
| Entry/exit code | `src/main.rs` (11 LOC) | mọi lỗi runtime → exit 1 |
| Output DTO / JSON | `src/model.rs` (729 LOC) | `serde` derive, snake_case |
| TUI | `src/app/tui.rs` (1451 LOC) | menu persistent tự render bằng `console`, dialoguer cho once-mode |
| Latency path | `src/app/service.rs` (`status`, `list`, `refresh_saved_usage_cache`), `src/app/usage_refresh.rs`, `src/app/auto_switch_monitor.rs`, `src/app/auto_start.rs` | worker chạy trong process TUI |
| Formatting | `src/time_display.rs`, `src/process.rs::format_process_table` | `time_display` chỉ TUI dùng |
| Consumer contract | `macos/NextAccount/Sources/NextAccount/AccountStore.swift` | decode JSON với `.convertFromSnakeCase`, timeout 120 s |
| Build/CI | `Cargo.toml`, `scripts/build-macos-app.sh`, `.github/workflows/ci.yml` | feature `external-providers` không được build khi release |
| Tài liệu | `README.md`, `CHANGELOG.md`, `AUDIT-2025-10-02.md`, `docs/full-review-2026-10-06.md` | đối chiếu, không coi là bằng chứng |

**Phương pháp:** (1) đọc toàn bộ `cli.rs`, `tui.rs`, `model.rs` và các điểm vào liên quan; (2) chạy `--help`/`--version` cho toàn bộ lệnh nhóm được (kể cả nested) để lấy help thật; (3) đối chiếu JSON thực tế mà Swift decode (struct + `RustDate`) với DTO Rust; (4) kiểm tra hành vi thư viện khi không có TTY/`NO_COLOR`/`TERM=dumb`/Ctrl-C bằng source `console 0.16.3`, `dialoguer 0.12.0`, `time 0.3.47` trong cargo registry (không phải suy đoán từ tài liệu); (5) suy luận latency từ call-path + timeout/lock hằng số, **không** profile. Mọi kết luận không kiểm chứng trực tiếp đều ghi `[suy luận]`.

**Rubric mức độ (dùng xuyên suốt):**

| Mức | Định nghĩa trong phạm vi CLI/TUI |
|---|---|
| **Critical** | Mất/hỏng credential hoặc dữ liệu; hoặc command trả sai account/sai trạng thái phá promise sản phẩm. |
| **High** | Hành vi hệ thống sai/chặn automation: hang, contract JSON sai, mất JSON output, che giấu lỗi, thao tác phá cam kết (archive). |
| **Medium** | Sai sót UX/latency đáng kể, output khó đọc/không nhất quán, thiếu guard rail phụ. |
| **Low** | Edge case hẹp, thẩm mỹ, maintainability. |

**Kết luận mức cao:** không có **Critical** trong phạm vi này (các safeguard ghi auth nằm ở `codex.rs`/`operation_lock.rs` và audit 03 đã kết luận tương tự). Có **11 High** trên tổng **35 finding**, tập trung ở 3 gốc: *help/discoverability gần như trống*, *JSON contract không có version/timestamp không ISO/không có error envelope*, *TUI không có TTY guard + blocking startup + không search/Ctrl-C*.

---

## Bản đồ lệnh

33 lệnh top-level ở build release (`external-providers` feature **không** được bật — xem `CLI-07`). `--json` có mặt ở 32/33 lệnh top-level; ngoại lệ duy nhất là `vibe-usage` và 4 subcommand của nó.

### Nhóm account / quota (Codex)

| Lệnh | Mục đích | Arg/flags | `--json` | Ràng buộc | Mặc định & hành vi |
|---|---|---|---|---|---|
| `status` | môi trường, account live, số saved, process warning, vibe cache | — | ✅ | — | human in plain lines; JSON = `StatusOutput` + `activity` |
| `list` | danh sách saved + cached usage | — | ✅ | — | **gồm cả archived**, sort `updated_at` desc |
| `save` | lưu session live hiện tại | — | ✅ | AuthLock | `SaveOutput{account,action}` (created/refreshed) |
| `begin-add-account` | bắt đầu flow thêm account: backup live + đánh dấu session đang add | — | ✅ | AuthLock | in "Complete the Codex browser sign-in…"; **không** tự chạy `codex login` |
| `save-added-account` | lưu account vừa login + kết thúc flow | — | ✅ | lỗi nếu auth chưa đổi | JSON `SaveOutput` |
| `cancel-add-account` | khôi phục session trước khi add | — | ✅ | — | JSON `{"status":"cancelled"}` |
| `add-account-status` | trạng thái flow add | — | ✅ | — | JSON `{active, auth_changed}`; human **chỉ in `active`** |
| `usage` | quota live hoặc 1 saved account | `[ACCOUNT_ID]` | ✅ | — | không id ⇒ account live |
| `refresh-usage` | refresh active + saved stale | — | ✅ | — | JSON cố định `{"status":"refreshed"}` (mất count/lỗi) |
| `activate` | đổi session live | `[ACCOUNT_ID] [--force]` | ✅ | `--force` chỉ bỏ qua Desktop | **không id ⇒ mở TUI menu**, `--json` bị bỏ qua |
| `enable-luna-reserve` | set model `gpt-5.6-luna` | `[ACCOUNT_ID]` | ✅ | — | **một chiều**, không có disable/revert |
| `delete` | xoá snapshot | `[ACCOUNT_ID]` | ✅ | — | **không id ⇒ TUI menu**; không confirm khi có id |
| `archive` | archive/unarchive | `<ACCOUNT_ID> [--restore]` | ✅ | **bắt buộc id** | **hai chiều trong một verb**; unarchive = `--restore` |
| `set-label` | đặt/xoá custom label | `<ACCOUNT_ID> <LABEL>` | ✅ | — | label rỗng ⇒ xoá; human in `Updated <uuid> label` |

### Nhóm backup / import / export

| Lệnh | Mục đích | Arg/flags | `--json` | Ràng buộc | Mặc định & hành vi |
|---|---|---|---|---|---|
| `export` | backup mã hoá age | `<OUTPUT> [--password-stdin]` | ✅ | — | không `--password-stdin` ⇒ prompt dialoguer (fail nếu non-TTY) |
| `import` | restore backup mã hoá | `<INPUT> [--password-stdin]` | ✅ | — | cảnh báo stale RT chỉ in stderr ở human mode |
| `import-json` | import auth.json / SnapshotBlob / plaintext bundle | `<INPUT> [--label]` | ✅ | — | tự detect 3 format; `--label` chỉ single-account |
| `restore-account-list-backup` | restore backup gần nhất của account list | — | ✅ | — | không tham số |
| `restore-full-backup` | restore full backup | — | ✅ | — | không tham số |
| `create-automatic-full-backup` | tạo automatic backup | — | ✅ | — | không tham số |

### Nhóm automation / settings

| Lệnh | Mục đích | Arg/flags | `--json` | Ràng buộc | Mặc định & hành vi |
|---|---|---|---|---|---|
| `auto-start-usage-windows` | bật/tắt/ chạy ping usage-window | `--enable` (conflict `disable`) `--disable` `--run` | ✅ | — | **bare = status**; `--disable --run` **âm thầm bỏ `--run`**; `--run` trả schema khác status |
| `auto-resume-session` | bật/tắt resume; discover thread bị ngắt | `--enable`/`--disable`/`--continue-interrupted` | ✅ | 3 mode loại trừ nhau | **bare = status**; `--continue-interrupted` trả schema khác (`SessionResumeHint`) |
| `auto-switch` | policy + decide + apply | `--enable`/`--disable`/`--status`/`--apply`; `--account-id` (requires apply); `--force` (requires apply) | ✅ | enable/disable conflict apply+status | **bare = decide**; `--status` hardcode `banked_reset_count: 0` |
| `recover-legacy-snapshots` | import snapshot từ data dir cũ | — | ✅ | — | 3 counter |
| `token-usage` | token local từ `~/.codex/sessions` | — | ✅ | — | human: today/7d/30d/365d/all-time |
| `quota-history` | ~7 ngày sample rate-limit | `[ACCOUNT_ID]` | ✅ | cần active saved account nếu không id | human in `account {:?}` (debug) |

### Nhóm thông tin ngoài / deprecated / nested

| Lệnh | Mục đích | Arg/flags | `--json` | Ràng buộc | Mặc định & hành vi |
|---|---|---|---|---|---|
| `vibe-usage` | passthrough `npx @vibe-cafe/vibe-usage@0.13.2` | `[init\|sync\|summary[--days]\|status]` | ❌ | cần Node 20+ | **bare = sync (upload network)**; không có output riêng |
| `reset-outlook` | outlook reset toàn cầu | — | ✅ | network | — |
| `reset-events` | reset mới, trả **một lần** | — | ✅ | network + **ghi state notification** | không read-only |
| `reset-timeline` | timeline reset | — | ✅ | network | — |
| `reset-status-history` | **deprecated** | — | ✅ | network | vẫn hiện trong help |
| `reset-juice` | **deprecated** | — | ✅ | network | vẫn hiện trong help |
| `open-ai-status` | trạng thái OpenAI | — | ✅ | network | help trống |
| `providers …` (feature) | 11 subcommand (sync-claude, claude-desktop, status, list, save, activate, delete, set-label, refresh-usage, usage, auto-switch) | — | ✅ | **feature không build** | **không tồn tại trong binary release** |

### `--json` coverage & tính bất đối xứng

| Nhóm | Có `--json` | Thiếu `--json` | Ghi chú |
|---|---|---|---|
| 33 lệnh top-level | 32 | `vibe-usage` | `--json` cũng không có help text (không mô tả) |
| `vibe-usage` subcommand | 0 | init/sync/summary/status | output là stdout của npx, không parse được |
| `providers` subcommand | 11 | 0 | nhưng không tồn tại ở build release |
| Global | — | `--format`, `--quiet`, `--verbose`, `--no-color`, `--dry-run`, `--yes`, `--timeout`, `--non-interactive` | chỉ `-h/--help`, `-V/--version` |

**Không có:** config file (`~/.config/codex-roster/config.toml` không tồn tại; `src/settings.rs` chỉ đọc `settings.json` trong app-data), shell completions (`clap_complete` không có trong `Cargo.toml`), man page, alias/short flag, `schema`/`doctor` command.

---

## Phát hiện

### A. Bề mặt lệnh & naming (CLI)

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| CLI-01 | **High** | `src/cli.rs:40-239`; help thực tế từ `cargo run -- --help`; `src/cli.rs:32` (about), `781` ("Deleted saved snapshot"), `649-651`; README:3,96 | `codex-roster --help`: **22/33 lệnh không có mô tả** (status, list, save, begin-add-account, save-added-account, cancel-add-account, add-account-status, usage, activate, delete, archive, export, import, restore-account-list-backup, restore-full-backup, create-automatic-full-backup, auto-start-usage-windows, auto-switch, recover-legacy-snapshots, token-usage, open-ai-status, set-label). `--json/--force/--restore/--password-stdin/--enable/--disable/--status/--apply` hầu hết không có help; positional `OUTPUT/INPUT/ACCOUNT_ID` không value_name/description; không có `long_about`, `after_help`, example nào. Thuật ngữ trộn: "account" / "saved snapshot" / "session" / "slot" / "roster"; `about` nói "CLI and IDE" trong khi README:96 nói macOS-only. → Người mới không thể biết lệnh nào dùng cho việc gì; `--json` là contract máy nhưng không được mô tả; help của `activate` chỉ có `--json --force` trống nghĩa; output destructive ("Deleted saved snapshot <uuid>") không khớp vocabulary "account". | Viết `///` cho 22 lệnh + `help` cho mọi arg; 1–2 example/lệnh; mô tả `--json` = "machine-readable contract, xem `schema`"; glossary ngắn trong README + `about` ("Codex accounts on macOS"), thống nhất "saved account" cho row và "live session" cho credential. | Cao |
| CLI-02 | Medium | `Cargo.toml:27` (clap derive, không `clap_complete`); `src/cli.rs:27-37` | Không có `completions <shell>`/`man`; binary tên `codex-roster` cài qua ZIP/DMG. → User phải gõ tay tên lệnh dài (`create-automatic-full-backup`, `auto-start-usage-windows`); dễ gõ sai; shell không gợi ý. | Thêm `clap_complete` + `clap_mangen`, command `completions`/`man`, sinh lúc build release. | Cao |
| CLI-03 | Medium | `src/cli.rs:98-109` (`archive`), `75-79/85-91/98-102` (`usage/activate/delete` optional id) | `archive <ID>` **bắt buộc** UUID và `--restore` để unarchive; trong khi `activate`, `delete`, `usage` nhận `[ACCOUNT_ID]` optional và **không id ⇒ mở TUI**. Cùng một dạng positional mang 3 nghĩa khác nhau, một verb mang 2 chiều. → Script khó đoán; `archive` không thể dùng làm "archive mặc định account active"; unarchive bị ẩn sau flag. | Tách `unarchive <ID>` (giữ `--restore` deprecated alias); thống nhất `--interactive`/`--all` thay vì "không id = menu"; `--dry-run`. | Cao |
| CLI-04 | Medium | `src/cli.rs:59-74`; `644-684`; workflow thật ở `src/app/service.rs:611-650` | Add-account flow nằm rải rác 5 lệnh top-level (`begin-add-account`, `save-added-account`, `cancel-add-account`, `add-account-status` + `save`); `begin-add-account --help` không mô tả gì. CLI **không** tự chạy `codex login` (chỉ GUI làm) và không có `--wait`; `begin` chỉ in "Complete the Codex browser sign-in" — người dùng CLI phải tự biết chạy `codex login`, rồi `save-added-account`. README chỉ mô tả flow phía GUI. → Standalone CLI user mắc kẹt giữa chừng; không biết khi nào login xong (`add-account-status` human chỉ in `active`). | Nhóm `account add begin\|save\|cancel\|status`; `begin --wait` poll `auth_changed` (dùng `add_account_session_auth_changed`); in rõ bước kế tiếp + lệnh `codex login`; `add-account-status` in cả `auth_changed`. | Cao |
| CLI-05 | Medium | `src/cli.rs:200-203`, `242-255`, `1033-1041` | `vibe-usage` **không có `--json`** ở bất kỳ subcommand nào (duy nhất trong 33 lệnh); chạy `npx` inherit stdout → không machine-readable, exit code npx bị nuốt (`run_vibe_usage`, `cli.rs:1503-1509`). **`codex-roster vibe-usage` không có subcommand = `sync`** → upload network ngoài ý muốn (README ghi `[init\|sync\|summary\|status]` khiến tưởng bare là vô hại). | Bare = `status` (read-only); thêm `--json` (wrap `summary --json` hoặc trả struct); `sync` phải explicit; map exit code con. | Cao |
| CLI-06 | Medium | `src/cli.rs:27-37`; `369-377` | Không global flag. Script phải đặt `--json` sau từng subcommand; không có `--format`, `--quiet`, `--verbose`, `--no-color`, `--dry-run`, `--yes`, `--timeout`, `--non-interactive`. → Không thể tắt output human khi lẫn; không thể dry-run thao tác phá; không thể giới hạn thời gian chờ lock (mặc định 90 s). | `#[command(flatten)] GlobalArgs { format, quiet, verbose, color, timeout, yes, dry_run }`; giữ `--json` làm alias của `--format=json`. | Cao |
| CLI-07 | Medium | `Cargo.toml:16,21`; `scripts/build-macos-app.sh:13`; `.github/workflows/ci.yml:39`; fingerprint release `features:["default"]` | Feature `external-providers` **không được bật ở release** (`cargo build --release --bin codex-roster`), nên 11 subcommand `providers` + `claude-quota-bridge` không tồn tại trong binary ship; CI `--all-features` chỉ compile-check. Swift có `ProviderStatusOutput` (`AccountStore.swift:3713`) nhưng **không nơi nào gọi** `providers`. → Bề mặt CLI trong source (và DTO Swift) đánh lừa maintainer; người dùng thấy `providers` trong tài liệu nội bộ nhưng chạy thật bị "unrecognized subcommand" (exit 2). | Quyết định: bỏ hẳn group khỏi shipped build + xoá DTO chết, hoặc enable feature và thêm test contract. Ghi rõ trong README/help. | Cao |
| CLI-08 | Medium | `src/cli.rs:92-97`; `src/app/service.rs:71-105` | `enable-luna-reserve` **một chiều**: set model `gpt-5.6-luna` và trả `previous_model`, nhưng không có lệnh disable/revert về model trước (chỉ sửa tay `~/.codex/config.toml`). Chạy lại nhiều lần idempotent nhưng `previous_model` sẽ mất dần. → User kẹt ở model reserve; automation không thể rollback. | Thêm `--model <slug>` (hoặc `disable-luna-reserve`), dùng `previous_model` để revert; coi đây là `set-model` generic. | Cao |
| CLI-09 | Low | `src/cli.rs:220-229` (deprecated), `886-912` (auto-start modes), `953-993` (auto-switch bare) | Tồn tại `reset-status-history`/`reset-juice` đã deprecated (vẫn network) chỉ được đánh dấu trong help; `auto-switch` không flag = **decide** (không phải status); `auto-start-usage-windows --disable --run` âm thầm bỏ `--run` (`cli.rs:899`). → Hành vi bất ngờ, khó dự đoán từ help. | Ẩn deprecated sau `--deprecated`/xoá; bắt buộc đúng 1 mode (`ArgGroup`); conflict `--disable` với `--run`. | Cao |

### B. Help, discoverability & i18n

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| HLP-01 | **High** | `src/cli.rs:377-378`; `1168-1183`; README (không có chữ "TUI"/"interactive") | Interactive TUI **chỉ** vào được bằng cách chạy `codex-roster` **không tham số**. Không có subcommand `tui`, không có `--tui`, không có trong `--help` (`Usage: codex-roster [COMMAND]`), không có trong README. → Toàn bộ tính năng menu (switch nhanh, xem quota, toggle auto-start) gần như vô hình; user chỉ tình cờ phát hiện; không thể mở TUI từ script/launcher một cách tường minh. | Thêm `codex-roster tui [--once]` (alias của no-arg), dòng "Run without a command or `tui` for the interactive picker" trong `about`, mục README + screenshot; giữ no-arg là alias. | Cao |
| HLP-02 | Medium | `src/cli.rs:1151-1166`; `src/secrets.rs:429-454`; `src/main.rs:3-10`; không có `std::io::IsTerminal` trong `src/` (grep rỗng) | Lỗi phổ biến thiếu hint: `activate`/`delete` không id ở non-TTY → `error: not a terminal` (dialoguer); `export` không `--password-stdin` trong pipe → `error: failed to read backup password: not a terminal` (không gợi ý flag); Keychain denied → lỗi thô của `keyring` + context chung "failed to load legacy snapshot from keychain" (không nói "mở Keychain Access / Always Allow", không nhắc item `com.codexroster.app` như README:65); lock timeout có message tốt nhưng không có next step. → User không biết sửa gì; GUI hiển thị nguyên stderr làm message (`AccountStore.swift:3171-3180`). | Bảng hint theo lỗi: TTY→gợi ý `--json`/truyền ID; password→`--password-stdin`; keychain→Always Allow + item name; lock→"thử lại sau/đóng app đang switch"; thêm `doctor`. | Cao |
| HLP-03 | Medium | `src/cli.rs` toàn bộ `println!`; `src/app/tui.rs` toàn bộ label/prompt; `macos/.../AppLanguage.swift:40-95`; `src/usage.rs:203-219,232-252`; `AccountStore.swift:4500-4505`; `OperationsView.swift:307` | CLI + TUI **chỉ tiếng Anh**, trong khi GUI mặc định theo hệ thống và có `vi` (README:3, `AppLanguage.preference` = `.system` → tiếng Việt trên máy Việt). Tệ hơn: chuỗi lỗi tiếng Anh được `usage_error_message` **persist vào metadata** (`usageError`), rồi GUI hiển thị nguyên văn (`usageStatus` trả `usageError`; `OperationsView` in ra) và phân loại bằng **substring tiếng Anh** ở 2 nơi (`src/usage.rs:232-263` ↔ `AccountStore.swift:4983-5012`). → Người dùng Việt thấy menu CLI/TUI tiếng Anh, và câu "Login required [refresh_token_rejected]: …" tiếng Anh lẫn trong UI tiếng Việt; đổi message ở Rust sẽ **vỡ im lặng** logic GUI (double-maintenance). | Catalog i18n cho CLI/TUI theo `LANG`/`--lang`; lưu **reason code** (`refresh_token_rejected`, `local_snapshot_unreadable`) thay vì câu tiếng Anh vào metadata; cả 2 UI dịch từ code; test mapping Rust↔Swift. | Cao |

### C. Output design & JSON contract (O)

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| OUT-01 | **High** | `Cargo.toml:37` (time không bật `serde-human-readable`); `src/model.rs` mọi `OffsetDateTime`; Swift `RustDate` `AccountStore.swift:5141-5166`; CHANGELOG:500 | **Mọi timestamp trong `--json` là mảng 9 số `[year, ordinal, hour, minute, second, nanosecond, offset_h, offset_m, offset_s]`**, không phải ISO-8601 (time 0.3.47 chỉ serialize string khi bật feature; crate không bật). Swift phải viết decoder riêng cho mảng; CHANGELOG từng ghi "accepts Rust `time` array timestamps". → `--json` **không** dùng được như contract công khai: `jq`, script, third-party app, logging đều vỡ; tài liệu không nói định dạng. | Tạo DTO contract riêng cho CLI (`src/cli/contract.rs`) với `#[serde(with = "time::serde::rfc3339")]` → ISO-8601 local/UTC có offset; hoặc bật `serde-human-readable` **kèm migration đọc mảng cũ** cho index (không đổi format on-disk). Swift đã đọc được cả string (`RustDate` thử String trước) nên hướng DTO-layer an toàn. | Cao |
| OUT-02 | **High** | `src/model.rs:247-312`; `src/cli.rs:647,667,674-677,697,792,809,823,856,868,880,1141`; `src/cli.rs:1548-1631`; không có `tests/` | Không có `contract_version`/`schema_version` trong bất kỳ output JSON nào (chỉ có `SNAPSHOT_SCHEMA_VERSION` cho file). 8+ lệnh trả JSON bằng `serde_json::json!` literal inline (begin/cancel/add-status/refresh-usage/archive/export/import/restore-*/set-label) → schema nằm rải trong `run()`, không có DTO, không review được. Không có golden/snapshot test cho JSON hay human output (chỉ 4 test parse ở `cli.rs:1548-1631`); CI không smoke `--json`. Optionality không nhất quán: `AccountView.subject/name/plan_label/usage/usage_error` luôn serialize `null` (`model.rs:233-244`) nhưng `custom_label` bị bỏ khi None (`model.rs:205`), `banked_resets/plan_label/luna_reserve` cũng bỏ. → Breaking change không bị test bắt; consumer phải xử lý 2 kiểu thiếu field; không biết format version. | Thêm `"contract_version": 1` top-level (additive, Swift bỏ qua field lạ); chuyển hết `json!` sang DTO trong `model.rs`; chốt policy "Option ⇒ luôn có key, null" hoặc ngược lại; test snapshot bằng `insta`/fixture + smoke `status --json` qua `jq` trong CI; thêm `codex-roster schema`. | Cao |
| OUT-03 | **High** | `src/main.rs:3-10`; `src/cli.rs:1185-1192`; Swift `AccountStore.swift:3092-3101,3171-3180` | Khi lỗi, `--json` **không** trả JSON: stdout rỗng, stderr = `error: <anyhow chain>` (một dòng, dấu `:`). Không có error code/envelope/hint. GUI coi **toàn bộ stderr** là message hiển thị cho user; mọi script muốn phân loại lỗi phải parse tiếng Anh. → Không thể phân biệt "cần login" vs "lock timeout" vs "no account" ngoài việc match substring; message dài/technical lộ ra UI người dùng. | Khi `--json`: in `{"error":{"code","message","hint","details"}}` ra **stdout** (hoặc stderr nhưng JSON), exit code theo bảng; giữ human error cho non-json. | Cao |
| OUT-04 | **High** | `src/cli.rs:709-744` (activate), `770-777` (delete) | `codex-roster activate --json` **không có ID** → rơi vào `app.interactive(ActivateOnce, …)`, **không in JSON nào** và trả `Ok(())` (exit 0). `delete --json` tương tự. Ở non-TTY thì dialoguer lỗi "not a terminal" (exit 1); ở nơi có TTY (GUI/launcher) thì mở menu thay vì trả dữ liệu. → Vi phạm hợp đồng `--json`; automation nhận exit 0 mà không có output, hoặc treo chờ menu. | Nếu `--json`/`--non-interactive` mà thiếu ID ⇒ `bail!("--json requires ACCOUNT_ID")` hoặc yêu cầu `--interactive`; chỉ mở menu khi có TTY và không có `--json`. | Cao |
| OUT-05 | Medium | `src/main.rs:5-9` (mọi lỗi runtime = 1); clap usage error = 2 (đo thực tế `nosuchcommand` → 2) | Chỉ có 3 exit code: 0, 1, 2. Auth-required, no-active-account, lock-timeout (90 s), network/quota, keychain denied, unsupported platform đều 1. → Script `if codex-roster ...; then` không phân nhánh được; không retry đúng nhóm lỗi; không tự logout/relogin. | Taxonomy: 0 ok, 2 usage, 3 auth/login required, 4 lock timeout, 5 no saved/active account, 6 network/quota, 7 keychain/decrypt, 8 unsupported; document trong `--help` + `doctor`. | Cao |
| OUT-06 | Medium | `src/cli.rs:694-701`; `src/app/service.rs:1099-1105`; `src/cli.rs:962-977`; `src/cli.rs:886-910`, `913-951`; `src/cli.rs:815-831,853-876` | Payload "nói dối"/đa hình: `refresh-usage --json` luôn `{"status":"refreshed"}` dù `refresh_usage_for_display` nuốt lỗi fetch active (`let _ = self.usage(None)`), không trả count/lỗi từng account; `auto-switch --status` hardcode `banked_reset_count: 0`, `active_account_id: null` (GUI decode và dùng, `AccountStore.swift:2499,5213`); `auto-start-usage-windows --run` trả schema khác status (không discriminator); `auto-resume-session --continue-interrupted` trả schema khác status; cảnh báo stale-RT chỉ in stderr ở human mode, **mất hoàn toàn** trong JSON. → Consumer không phân biệt "0" với "không biết"; báo cáo refresh sai; cảnh báo an toàn mất. | `refresh-usage` trả `{refreshed, failed, accounts[]}`; `banked_reset_count` là `Option` (null = chưa tính); thêm `kind` vào payload đa hình; đưa `warnings[]` vào JSON của import/restore. | Cao |
| OUT-07 | Medium | `src/cli.rs:1201-1242`; `src/time_display.rs:3-18`; `tui.rs:354`; `src/cli.rs:1019-1023`, `1076-1082` | Human output lệch và lẫn debug: `list` mỗi account 1 dòng, **UUID đứng trước**, không header/cột, không màu; dùng `reset_at.date()` = **ngày UTC** trong khi TUI dùng `format_local_reset_at` (local, có giờ); `custom_label` (`set-label`) và `archived`/`provider` **không hiển thị**; `quota-history` in `account {:?}` → `Some(<uuid>)/None`; `reset-timeline` cắt summary `.chars().take(60)` không ellipsis. → User không đọc được roster bằng CLI; thấy sai ngày reset (UTC+7 lệch 1 ngày với reset nửa đêm); label đặt qua CLI vô hình; output lẫn debug. | Renderer bảng: `email/label · plan · 5h · weekly · reset local · [active]/[archived]`; dùng `format_local_reset_at`; thêm `--format table` mặc định; bỏ `{:?}` và thêm "…" khi truncate. | Cao |

### D. Safety & automation contract (SAF)

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| SAF-01 | **High** | `src/app/tui.rs:490-568` (đặc biệt `501`, `565`); `src/cli.rs:377-378,1168-1183`; không có TTY check trong `src/` | `codex-roster` **không tham số** trong pipe/CI/cron/launcher không TTY: `console::Term::read_key()` trả `Ok(Key::Unknown)` liên tục khi `!is_tty` (source console 0.16.3 `term.rs:296-302`), loop `match key { … _ => {} }` không match `Unknown` và **không sleep** ⇒ **busy-loop vô hạn 100% CPU**, không exit, không in gì. Cùng lỗi ở `confirm_with_menu` (`tui.rs:925-944`). → Treo CI/script; GUI gọi nhầm no-arg sẽ treo tiến trình con (Swift timeout 120 s mới kill, `AccountStore.swift:3155`). | `if !std::io::stdin().is_terminal() { bail!("no command given and stdin is not a TTY; use `codex-roster status --json` or `tui`"); }` trước `run_interactive_app`; thêm arm `Key::Unknown` → sleep 50 ms hoặc thoát; test non-TTY. | Cao |
| SAF-02 | **High** | `src/repository.rs:285-298` (không filter archived); `src/cli.rs:1201-1242` (không marker); `src/app/tui.rs:407-423` (không filter); `src/app/service.rs:982-1002` (không check) | Archive là "ẩn" theo GUI (`PrismQuickSwitchDeck.swift:103` filter `!account.archived`), nhưng CLI `list` và **TUI menu vẫn liệt kê archived như account bình thường**, và `load_activation_target` không kiểm tra `archived` ⇒ `activate <archived-id>` **thành công**. → Người dùng archive để dọn roster nhưng TUI vẫn hiện, vẫn switch được; không biết account nào archived; promise "archive" bị phá ở surface CLI/TUI. | `list --all/--archived/--active` (mặc định ẩn archived), marker `[archived]`; TUI section riêng hoặc filter; `activate` từ chối archived trừ `--allow-archived`; test. | Cao |
| SAF-03 | Medium | `src/cli.rs:770-784` (delete), `785-800` (archive); `src/app/service.rs:1459-1466`; `src/cli.rs:781,792-797`; `tui.rs:770-800` (TUI có confirm, default No) | CLI `delete <uuid>` **không confirm** (hợp lý với explicit ID) nhưng cũng **không có `--dry-run`**, **không `--yes`**, và output chỉ in UUID, không in email/label ⇒ không xác nhận được đã xoá đúng ai. Archive tương tự ("Archived <uuid>"). TUI có confirm tốt nhưng CLI không có tương đương preview. → Automation không thể preview blast radius; user không verify được kết quả destructive. | `--dry-run` cho mọi lệnh mutate (resolve target, in tóm tắt, không ghi); output echo `email` + label; giữ confirm ở TUI. | Cao |
| SAF-04 | Medium | `src/operation_lock.rs:10-11` (`ACQUIRE_TIMEOUT = 90s`), `55-77`; Swift `AccountStore.swift:3155` (120 s) | Mọi lệnh mutate/usage đều acquire lock; nếu GUI/worker đang switch, CLI **chờ im lặng tới 90 s** (chỉ sleep 50 ms/lần, không in gì), rồi mới lỗi "another Codex Roster … operation is still running". Swift kill tiến trình ở 120 s ⇒ cửa sổ 90 s gần sát timeout GUI. → CLI "treo" không giải thích; GUI có thể kill giữa lúc CLI vừa acquire lock. | In `Waiting for another Roster operation…` ra stderr sau 250 ms chờ; `--timeout <s>`/`--no-wait`; hạ default cho path GUI; message kèm PID? (không cần) và hint đóng app. | Cao |
| SAF-05 | Medium | `src/codex.rs:440-484` (rollback trong process), `451-458` (`.cas-backup-*`/`.cas-restore-*` trong `~/.codex`); không có cleanup/startup recovery (grep `cas-backup` chỉ thấy 2 dòng tạo) | Không có signal handler (`main.rs` không bắt SIGINT/SIGTERM). Ctrl-C/SIGTERM/kill trong lúc `activate` bỏ qua mọi rollback của `restore_snapshot_with_retry`; backup dir `.cas-backup-<uuid>` (chứa credential cũ, 0700) **nằm lại vĩnh viễn** trong `~/.codex`, không có lệnh dọn/phục hồi. → Auth có thể nửa vời sau kill; rác credential tồn đọng; không có `doctor` để chỉ ra. | Signal handler defer interrupt trong critical section (hoặc block SIGINT quanh restore); `doctor --cleanup` / `recover-backups` liệt kê & dọn `.cas-*`; log "recovery files retained" (đã có) + hint lệnh. | TB (source-level chắc; chưa kill thử) |
| SAF-06 | Medium | `src/app/usage_refresh.rs:27-34`; `src/app/auto_start.rs:157`; `src/app/auto_switch_monitor.rs:34,112`; `src/app/service.rs:928-935`; TUI ghi stderr `tui.rs:495,589` | TUI host 5 worker thread trong cùng process (`cli.rs:1172-1177`); worker lỗi → `eprintln!` vào **cùng stderr** mà menu đang vẽ. `CODEX_ROSTER_PROFILE_SWITCH` còn in timing nhiều dòng giữa operation (`service.rs:928-949`). → Bất kỳ lỗi worker/auto-switch/profile nào cũng **chèn text vào giữa menu**, làm lệch viewport/rewrite (cursor-up) và rối màn hình; có thể làm hỏng trạng thái render. | Trong interactive mode: route log qua file/`BufWriter` hoặc ring buffer hiển thị trong feedback; tắt `eprintln` worker khi TUI active; dùng một log facade. | Cao |
| SAF-07 | Medium | `src/cli.rs:708-753`; `src/app/service.rs:844-880`; so sánh `src/cli.rs:497-515` | `activate --force`: `--force` chỉ bỏ qua Desktop, **không** bỏ qua Codex CLI (đúng), nhưng: (a) CLI human output chỉ "Activated …" **không nói cần relaunch Desktop** (GUI tự làm; CLI thì không; `providers activate` có `requires_relaunch` còn top-level `activate` không có field này — `model.rs:666-673`); (b) `--force` không in rõ đã bỏ qua process nào (chỉ in "Desktop leftovers" khi không `--json`); (c) TUI confirm "Yes, force activation" bật force cho mọi warning (`tui.rs:95-102`). → User CLI switch khi Desktop đang chạy `--force` sẽ thấy Desktop vẫn session cũ, dễ tưởng switch thất bại. | Thêm `requires_relaunch: bool` + warning list vào `ActivateOutput`; human in "Relaunch ChatGPT/Codex Desktop"; TUI hiển thị rõ force chỉ áp dụng Desktop; giữ guard CLI. | Cao |

### E. TUI & latency

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| TUI-01 | **High** | `src/app/tui.rs:28-30`; `src/app/service.rs:1012-1041` (`let _ = self.usage(Some(id))` dòng 1037); `src/app/usage_refresh.rs:24-36`; `src/usage.rs:800-805` (timeout 5 s) | Trước **frame menu đầu tiên**, `interactive(Persistent)` gọi `refresh_saved_usage_cache()`: loop **tuần tự mọi account không archived**, mỗi account một `usage()` (network tới 5 s, AuthLock chờ tới 90 s), **không** kiểm tra cache fresh (khác `refresh_stale_saved_usage`). Đồng thời `spawn_usage_refresh_worker` (`cli.rs:1176`) vừa start đã chạy sweep ngay (`usage_refresh.rs:24-36` vòng lặp bắt đầu bằng run, không sleep trước) ⇒ **2 sweep song song** tranh AuthLock, gấp đôi network và token churn. → Terminal **trống hoàn toàn** (không spinner/progress) từ vài giây đến 30 s+ với 5–10 account; user tưởng treo; macOS Keychain prompt có thể hiện trước khi có UI. | Render menu trước (data từ `list()` cache), refresh nền rồi re-render qua channel; dòng "Refreshing quota… (n/N)" ở footer; bỏ sweep foreground hoặc worker (một nguồn); tôn trọng staleness. | Cao |
| TUI-02 | **High** | `src/app/tui.rs:510-565` (arm `Key::Char`), `558-564`, `925-944`; `src/app/tui.rs:497` (`hide_cursor`), không có `show_cursor` trên error path | **Ctrl-C bị bỏ qua**: `console::Term::read_key` đặt terminal raw qua `cfmakeraw` (tắt `ISIG`), byte `0x03` được trả về `Key::Char('\u{3}')` (console `unix_term.rs:345-371,421-423`); match không có arm Ctrl-C ⇒ chỉ `q`/Esc mới thoát. Thêm nữa: `hide_cursor()` ở đầu menu, `show_cursor()` chỉ chạy ở Enter/Esc/quit bình thường; nếu `self.status()?`/`read_key()?` lỗi (keychain, IO) hoặc panic ⇒ **cursor bị ẩn** khi trả về shell, menu cũ còn trên màn hình. → Thao tác ngắt chuẩn của terminal không hoạt động; user phải học `q`; terminal "mất cursor". | Thêm `Key::Char('\u{3}')` (và `Key::CtrlC` nếu dùng `read_key_raw`) → quit; guard `Drop`/panic hook restore cursor + `clear_last_lines`; viết test không cần TTY cho keymap. | Cao |
| TUI-03 | **High** | `src/app/tui.rs:510-565`; `570-578` (chỉ Tab/←→); `756-768` (dialoguer Select); `Cargo.toml:29` (dialoguer default feature, **không** `fuzzy-select`) | Không có **search/filter/fuzzy** (`/`), không Home/End/PageUp/PageDown dù `console` trả các key này (`unix_term.rs:265-280`), không số thứ tự để nhảy nhanh, không multi-select. Roster > ~10 account (hoặc terminal thấp) phải bấm mũi tên từng dòng; once-mode dùng dialoguer `Select` cũng không search. → TUI chậm hơn GUI/`grep` cho đúng use case "đổi account nhanh". | Thêm `/` incremental filter, Home/End/PgUp/PgDn, `1`–`9` jump, `?` help overlay; hoặc bật `dialoguer/fuzzy-select` cho once-mode; tối thiểu thêm j/k đã có + PgUp/PgDn. | Cao |
| TUI-04 | Medium | `src/app/tui.rs:27` (`default_selection`), `68`, `71-140`; `src/repository.rs:296` (sort `updated_at` desc) | Selection lưu theo **index**, không theo `account.id`. Sau khi activate, list re-sort và account vừa active bị loại khỏi menu (`tui.rs:408-413`) ⇒ cursor nhảy sang account khác (hoặc kẹp cuối danh sách). Tương tự sau save/delete. → Người dùng dễ chọn nhầm account ở lần Enter kế tiếp; trải nghiệm "mất chỗ". | Lưu `selected_account_id`; sau re-render tìm lại theo id, fallback index cũ; test reorder. | Cao |
| TUI-05 | Medium | `src/app/tui.rs:442-475`; `304-325`; `src/cli.rs:1201-1242` | Menu persistent chỉ có: `SaveCurrent`, `Delete saved account`, toggle auto-start usage windows, `Show status`, `Quit`. **Không có**: refresh usage (`r`), archive/restore, set-label, auto-switch toggle, auto-resume toggle, luna, provider, export/import, token-usage, quota history. `render_account_label` chỉ dùng `account.email` — **`custom_label` đặt qua CLI/GUI không hiển thị**; `archived` không hiển thị. → TUI không thể thay thế CLI cho công việc thường ngày; label trở nên vô dụng ở mọi surface terminal. | Thêm action + detail pane; label hiển thị `custom_label ?? name ?? email`; filter archived; `r` refresh, `a` archive, `l` label, `?` help. | Cao |
| TUI-06 | Medium | `src/app/tui.rs:32-42` (status/list mỗi iteration); `src/app/usage_refresh.rs:21,126` (listener có nhưng TUI không subscribe); `src/app/auto_switch_monitor.rs:14` (45 s) | Menu **không tự refresh**: dữ liệu snapshot tại thời điểm render; worker refresh usage/auto-switch mỗi 45–120 s cập nhật store nhưng TUI không re-render, không subscribe `subscribe_usage_refresh_checks`. → Quota trên menu có thể cũ suốt session; auto-switch đổi account sau lưng menu (menu vẫn hiện account cũ là active/không active). Mỗi iteration lại gọi `status()`+`list()` (2× repository list + auth read + process scan; `status()` còn đi qua scan nặng đã nêu ở audit 03 P1) → chậm sau mỗi action. | Subscribe listener → re-render khi có dữ liệu mới; `status`/`list` một lần/iteration, cache theo generation; thêm `r` refresh thủ công + timestamp "as of". | Cao |
| TUI-07 | Medium | `src/app/tui.rs:624-628` (`.white()`), `697-699` (`.blue().bold()`), `748-754`/`948-954` (`.cyan()`), `701-705` (`.dim()`) | Màu hardcode theo giả định nền tối: `white()` (SGR 37) cho nội dung chính, xanh/cyan/dim cố định; terminal **light theme** (macOS Terminal/iTerm profile sáng) ⇒ chữ trắng trên nền trắng gần như **vô hình** cho active account row. Không có theme/config; `console` chỉ tôn trọng `NO_COLOR`/`CLICOLOR`/`TERM=dumb` (`utils.rs:15-20`, `unix_term.rs:29-34`) chứ không đổi theo nền. | Dùng style ngữ nghĩa (bold/underline/reverse) thay vì `white`; hoặc theme `auto/dark/light` + `CODEX_ROSTER_THEME`; test snapshot ANSI. | Cao |
| TUI-08 | Medium | `src/app/tui.rs:373-383` (byte len) vs `304-325` (format width); `55-66` + `756-768` + `885-946` (dialoguer/custom trộn); `503-509` (clear_screen); `701-705` (divider cố định 50); `664-691` (rows=1–2) | Renderer thiếu nhất quán: (a) `AccountLabelWidths` đo bằng `str::len()` **byte** trong khi `format!("{:<width$}")` pad theo **char** ⇒ lệch cột với email Unicode/CJK/emoji (console có `measure_text_width` nhưng chỉ dùng trong test); (b) persistent mode tự render bằng `console` còn `ActivateOnce`/`DeleteOnce`/delete-picker dùng `dialoguer::ColorfulTheme` ⇒ 2 style prompt, 2 cách xử lý Esc/q, paging khác nhau; (c) resize gọi `clear_screen()` xoá cả nội dung trước đó; divider luôn 50 ký tự; terminal rows≤2 không có thông báo "quá nhỏ". | Dùng `console::measure_text_width` cho width; thống nhất một framework (dialoguer cho mọi mode, hoặc ratatui); resize chỉ redraw vùng menu; divider theo width; min-size message. | Cao |

### F. Latency path (CLI + TUI)

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| LAT-01 | Medium | `src/app/service.rs:44-68` (`status` → `detect_running_codex_processes` + `codex_activity::summarize`); `src/codex_activity.rs:118-126,135-166`; `src/session_resume.rs:379-413,465-495`; `AccountStore.swift:2496-2501`; `src/cli.rs:371-376`; `src/env.rs:17-30,48-88` | **Scan nặng:** mỗi `status` (và mỗi lần TUI re-render) chạy full process scan **và** activity: `waiting_interrupted` hardcode `enabled=true`, query mọi thread trong `state_5.sqlite` rồi đọc tail 512 KB (fallback đọc **toàn bộ** file) cho từng rollout; `recent_rollout_activity` walk đệ quy `~/.codex/sessions`. Swift bootstrap gọi `status`, `list`, `auto-start-usage-windows`, `auto-switch --status`, `auto-resume-session` **đồng thời** (`async let`) ⇒ 5 process CLI cùng scan. **Startup dư:** `run()` luôn `env::detect()` + tạo `App` trước dispatch (kể cả lệnh chỉ network như `reset-outlook`/`open-ai-status`), và `env::detect()` có thể **rename data dir legacy** (`migrate_legacy_data_dir`) trên bất kỳ invocation nào; không có `--app-data-dir`/`CODEX_ROSTER_DATA_DIR` để cô lập. → Latency GUI/TUI/CLI phụ thuộc số thread; lệnh read-only có thể ghi (migration) ngoài dự kiến; script polling tốn CPU/IO. (Gốc scan đã báo ở audit 03 P1; ở đây là tác động lên contract CLI/TUI.) | Cho `status --no-activity`/`--fast` mặc định nhẹ; cache activity 10–30 s dùng chung `(size,mtime)`; LIMIT SQL; TUI chỉ tính activity khi mở detail; `env::detect()` lazy theo lệnh + thêm `--app-data-dir`/`CODEX_ROSTER_DATA_DIR`; migration chỉ khi cần đọc snapshot. | TB `[suy luận]` (chưa profile) |

---

## Đề xuất nâng cấp

### P1 — Contract v2 (JSON ổn định, có version, có error envelope) — Effort **M** · Impact **Cao** · Risk **Trung bình**

- Tạo layer DTO riêng cho CLI (`src/cli/contract.rs`): map từ `model.rs` sang struct `Serialize` có `#[serde(with = "time::serde::rfc3339")]`, mọi optional có policy thống nhất, top-level `"contract_version": 1`.
- Thêm `codex-roster schema [command] [--json]` in JSON Schema (hoặc ít nhất shape + enum + ví dụ) để consumer/GUI sinh decoder.
- Error envelope khi `--json`: `{"error":{"code","message","hint","details"}}` + exit-code taxonomy (`OUT-03`, `OUT-05`).
- Golden tests `insta` cho toàn bộ `--json` + human output; CI smoke `status --json | jq -e '.environment'`.
- **Không** đổi format on-disk (giữ mảng `time` trong `metadata.json`); chỉ đổi surface JSON. Swift `RustDate` đã đọc được cả string nên additive-safe.

### P2 — Command surface v2 (namespace + alias + global flags) — Effort **M/L** · Impact **Cao** · Risk **Trung bình** (giữ alias cũ cho Swift)

Thiết kế đề xuất (flat legacy names giữ làm alias, deprecate dần):

```text
codex-roster [tui] [--once]                      # no-arg = tui (alias), có tên tường minh
codex-roster roster list [--all|--archived|--active] [--json] [--format table|json|ndjson]
codex-roster roster switch <query> [--dry-run] [--json] [--wait] [--force-desktop] [--relaunch]
codex-roster roster archive|unarchive <id> [--dry-run]
codex-roster roster delete <id> [--yes] [--dry-run]
codex-roster roster label <id> [<label>] [--dry-run]
codex-roster account add begin [--wait] | save | cancel | status   [--json]
codex-roster usage [--active|--all|--id <uuid>] [--refresh] [--json]
codex-roster auto switch enable|disable|status|apply [--json]
codex-roster auto resume enable|disable|continue [--json]
codex-roster auto windows enable|disable|run|status [--json]
codex-roster settings get|set|list [--json]      # thay 4 lệnh toggle rời
codex-roster backup export|import <path> [--password-stdin|--password-env NAME]
codex-roster backup restore full|account-list [--json]
codex-roster diag doctor [--json] [--fix] [--cleanup]
codex-roster diag schema [command] [--json]
codex-roster completions <zsh|bash|fish> ; codex-roster man
```

Ví dụ chạy:

```bash
codex-roster tui --once
codex-roster roster switch work --dry-run
# → would activate: work@acme.com (8f27e8c…), saved 2026-10-17 09:12, quota 5h 62%/W 28%
codex-roster roster switch --label "Công ty" --json --wait
codex-roster usage --all --format=ndjson | jq -c 'select(.five_hour.remaining_percent<20)'
codex-roster account add begin --wait          # poll auth_changed, in bước kế tiếp
codex-roster diag doctor --json | jq .checks
codex-roster backup import backup.age --password-env CODEX_ROSTER_BACKUP_PASSWORD
```

Bảng alias tương thích (Swift đang gọi): `status`, `list`, `save`, `usage`, `activate`, `delete`, `archive <id> --restore`, `begin-add-account`, `save-added-account`, `cancel-add-account`, `add-account-status`, `refresh-usage`, `auto-start-usage-windows`, `auto-resume-session`, `auto-switch`, `set-label`, `import`, `export`, `restore-*`, `create-automatic-full-backup`, `enable-luna-reserve`, `recover-legacy-snapshots`, `reset-*`, `open-ai-status` → map sang surface mới nhưng **giữ nguyên output JSON key** (additive field `deprecated: true` nếu cần).

- `--dry-run` cho: switch/activate, delete, archive/unarchive, label, import (validate + count).
- `--wait` + NDJSON progress cho các operation dài (activate, import, add-account).
- Global: `--format`, `--quiet`, `--verbose`, `--no-color`, `--timeout`, `--non-interactive`, `--yes`.
- Xoá/ẩn `reset-status-history`/`reset-juice`; quyết định dứt điểm feature `external-providers` (`CLI-07`).
- `enable-luna-reserve` → `roster model set gpt-5.6-luna` / `--restore-previous` (`CLI-08`).

### P3 — Automation & safety hardening — Effort **M** · Impact **Cao** · Risk **Thấp/Trung bình**

- Non-TTY guard (`SAF-01`) + `activate/delete --json` thiếu ID trả lỗi có code (`OUT-04`).
- Signal handling: defer SIGINT trong critical section (`SAF-05`), `doctor --cleanup` quét `.cas-backup-*`/`.cas-restore-*`.
- Lock wait có progress + `--timeout` (`SAF-04`); exit code taxonomy.
- `--dry-run` mặc định cho lệnh destructive; echo `email`+`label` trong output.
- Archive guard: CLI/TUI ẩn + `activate` từ chối archived (`SAF-02`).
- Activate output thêm `requires_relaunch`, `skipped_processes[]`, hint relaunch (`SAF-07`).
- Worker logging tách khỏi stderr khi TUI active (`SAF-06`).

### P4 — TUI v2 (full-screen, search, detail pane, action đầy đủ) — Effort **L** · Impact **Cao** · Risk **Trung bình** (surface mới, giữ mode cũ trong 1 release)

Hai hướng:
1. **Giữ renderer tự viết + nâng cấp** (Effort M): thêm `/` filter, `?` help, Home/End/PgUp/PgDn, action `r/a/u/l/s`, label/archived hiển thị, theme auto/dark/light, guard cursor, subscribe refresh, non-TTY guard. Rủi ro thấp, tận dụng 15 test layout sẵn có.
2. **Chuyển `ratatui` + `crossterm`** (Effort L): alt-screen, layout widget, scrollbar, popup help/detail, mouse optional, dễ i18n; đổi dependency + viết lại ~600 LOC renderer/tests. Rủi ro trung bình.

Wireframe v2 (hướng 2, hoặc mô phỏng bằng renderer hiện tại):

```text
┌ Codex Roster 0.5.0 · macOS · 4 saved ──────────────────────────────────────┐
│ ACTIVE  work@acme.com  [Pro]   5h 62% · W 28% · reset 21:30               │
├────────────────────────────────────────────────────────────────────────────┤
│ / wo▏                                                                      │
│  ▸ work@acme.com          Pro    5h  62%   W  28%   (active)               │
│    personal@gmail.com     Plus   5h  91%   W  55%   last used 2h ago       │
│    old@corp.com           Team   5h   0%   W   3%   [login required]       │
│  ── archived (2) ─────────────────────────────────────────────────────────  │
│    trial@x.dev            Free   5h 100%   W 100%   [archived]             │
├────────────────────────────────────────────────────────────────────────────┤
│ DETAIL  personal@gmail.com · id 8f27… · plan Plus · snapshot 2026-10-17    │
│         09:12 · 2 files · decrypt OK · usage fetched 3m ago · 1 banked     │
├────────────────────────────────────────────────────────────────────────────┤
│ [s]witch [r]efresh [l]abel [a]rchive [u]narchive [d]elete [?]help [q]uit   │
│ ↑↓/jk move · Tab section · Enter select · / search · Ctrl-C quit           │
└────────────────────────────────────────────────────────────────────────────┘
```

Kèm: alternate screen + panic hook + `Drop` restore terminal; non-TTY → lỗi có hint; i18n EN/VI theo `LANG`/settings (dùng chung catalog với GUI cho message lỗi, thay vì lưu chuỗi tiếng Anh vào metadata — xem `03`/`OUT-06` liên quan `usageError`).

### P5 — Startup & polling latency — Effort **S/M** · Impact **Cao** · Risk **Thấp**

- Bỏ `refresh_saved_usage_cache()` foreground; render trước, refresh nền, re-render qua `subscribe_usage_refresh_checks` (`TUI-01`, `TUI-06`).
- Chỉ một nguồn sweep (worker hoặc foreground); staleness-aware như `refresh_stale_saved_usage`.
- `status --fast`/`--no-activity`; cache activity + interrupted-session 10–30 s; LIMIT SQL + tail 64–128 KB (phối hợp audit 03 P1).
- TUI iteration dùng 1 snapshot `status`+`list` thay vì 2 lần đọc + 2 scan.

### P6 — Help, docs, completion, i18n — Effort **S/M** · Impact **Trung bình–Cao** · Risk **Thấp**

- `///` cho 22 lệnh + help mọi flag; 1–2 example/lệnh; `long_about` cho nhóm.
- `clap_complete` + `clap_mangen`, đóng gói trong release; README mục "CLI reference" sinh từ help (hoặc ít nhất đồng bộ tay).
- README bổ sung: TUI (có screenshot), 2 mode add-account cho CLI, `--password-stdin`, exit codes, JSON timestamp format; sửa danh sách lệnh đang thiếu 15 lệnh (`README.md:101-123`).
- i18n: CLI/TUI theo `LANG`/`--lang`; **không** persist câu lỗi tiếng Anh vào metadata — persist reason code (`[refresh_token_rejected]` đã có) và để từng UI dịch. Hiện GUI đang hiển thị nguyên câu tiếng Anh (`AccountStore.swift:4500-4505`, `OperationsView.swift:307`) và phân loại bằng substring trùng lặp 2 nơi (`src/usage.rs:232-263` ↔ `AccountStore.swift:4983-5012`) — khi đổi message sẽ vỡ im lặng.

### P7 — `switch <query>` fuzzy resolver — Effort **S/M** · Impact **Cao** · Risk **Thấp**

- Resolve theo thứ tự: UUID (full) → UUID prefix (nếu unique) → `custom_label` (exact, case-insensitive) → `name` → email exact → email substring/domain; nhập nhằng ⇒ in candidate + exit 3 (không tự chọn).
- `--dry-run` in target + quota + cảnh báo process; `--wait` chờ switch ổn định; `--json` trả `ActivateOutput` chuẩn.
- TUI dùng cùng resolver cho `/` filter.

### P8 — `doctor` self-diagnostics — Effort **M** · Impact **Trung bình–Cao** · Risk **Thấp**

Check list (mỗi check có `status`, `detail`, `hint`, `--json`): version/build, app-data path & quyền, `~/.codex/auth.json` hợp lệ, Keychain item `com.codexroster.app` đọc được (không in secret), lock files đang bị giữ (PID nếu đọc được), leftover `.cas-backup-*`/`.cas-restore-*`, port 1455/1457 (chỉ khi add-account pending), CLI version vs app bundle version, network tới usage endpoint (opt-in), archived/add-account pending, số account & trạng thái usage. `--fix` chỉ cho các mục an toàn (dọn rác, clear stale pending marker).

### P9 — Bảng tổng hợp effort/impact

| Đề xuất | Effort | Impact | Risk | Ưu tiên |
|---|---|---|---|---|
| P1 Contract v2 | M | Cao | TB | 1 |
| P3 Automation/safety | M | Cao | TB | 2 |
| P5 Latency startup | S/M | Cao | Thấp | 3 |
| P2 Command surface v2 | M/L | Cao | TB | 4 |
| P4 TUI v2 | L | Cao | TB | 5 |
| P7 `switch` fuzzy | S/M | Cao | Thấp | 6 (làm cùng P2) |
| P6 Help/docs/completions/i18n | S/M | TB–Cao | Thấp | 7 |
| P8 `doctor` | M | TB–Cao | Thấp | 8 |

---

## Quick wins (≤1 ngày)

| # | Việc | File | Fix |
|---|---|---|---|
| 1 | Non-TTY guard: no-arg TUI + `--json` thiếu ID | `src/cli.rs:377-378,740-743,770-776`; `src/app/tui.rs:22-30` | `std::io::IsTerminal` → `bail!` có hint; `--json` + no ID ⇒ lỗi. Chặn hang 100% CPU. |
| 2 | Ctrl-C + cursor restore | `src/app/tui.rs:497,510-565,885-946` | Thêm `Key::Char('\u{3}')` → quit; guard `Drop`/panic hook `show_cursor()`. |
| 3 | Doc comment cho 22 lệnh trống + help `--json/--force/--restore` | `src/cli.rs:40-239` | `///` + `#[arg(help=...)]`; mô tả `--json` trỏ `schema`. |
| 4 | `list` human: label + archived + local reset | `src/cli.rs:1201-1242` | Dùng `custom_label.unwrap_or(email)`, marker `[archived]`, `format_local_reset_at`. |
| 5 | Output destructive echo email thay UUID | `src/cli.rs:781,794-797` | Lấy email từ `DeleteOutput`/`AccountView` (thêm field vào output). |
| 6 | `add-account-status` human in cả `auth_changed` + next step | `src/cli.rs:673-683` | 2 dòng + hint `codex login` / `save-added-account`. |
| 7 | `refresh-usage --json` trả count/lỗi thật | `src/cli.rs:694-701`; `src/app/service.rs:1099-1105` | Struct `{refreshed, failed, accounts[]}`; không nuốt lỗi. |
| 8 | `auto-switch --status` dùng `Option` cho `banked_reset_count` | `src/cli.rs:966-977` | `None` thay `0`. |
| 9 | `providers auto-switch --status` đang bị bỏ qua | `src/cli.rs:586` (`status: _`) | Implement hoặc xoá flag (tránh flag no-op). |
| 10 | `auto-start-usage-windows --disable --run` → conflict | `src/cli.rs:146-154,899` | `conflicts_with`/`requires`; hoặc lỗi rõ. |
| 11 | `quota-history` bỏ `{:?}` | `src/cli.rs:1019-1023` | In email hoặc "active". |
| 12 | Xoá/ẩn 2 lệnh deprecated + đồng bộ README CLI | `src/cli.rs:220-229`; `README.md:101-123` | Xoá hoặc `hide=true`; thêm 15 lệnh thiếu. |
| 13 | TUI chỉ một sweep usage khi start | `src/app/tui.rs:28-30`; `src/cli.rs:1176` | Bỏ foreground hoặc worker; render trước. |
| 14 | Footer "Refreshing quota…" trước khi block | `src/app/tui.rs:28-30` | In 1 dòng trước `refresh_saved_usage_cache`. |
| 15 | `errors`: bỏ cảnh báo stale-RT khỏi stderr-only trong JSON | `src/cli.rs:815-831,853-876` | Thêm `warnings[]` vào JSON. |

---

## Điểm đang tốt — giữ nguyên

1. **Renderer TUI đã được harden đúng hướng**: clip theo width bằng `console::truncate_str` + `measure_text_width`, xử lý resize, viewport theo height giữ selection, chống wrap ở cột cuối (`src/app/tui.rs:594-745`); 15 test layout/unicode/short-terminal (`tui.rs:956-1450`, đặc biệt `persistent_menu_fits_terminal_height_and_keeps_every_selection_visible`). Đây là fix đúng cho full-review R4 — đừng regress khi chuyển framework.
2. **Confirmation mặc định an toàn**: `confirm_delete`/`confirm_activation` default **No**, body giải thích force chỉ áp dụng Desktop, live CLI vẫn block (`tui.rs:770-800,885-946`); TUI hiển thị `Snapshot id` trong confirm.
3. **Error feedback trong TUI có ngữ cảnh**: `error_feedback_rendered` giữ multi-line + gợi ý riêng khi phát hiện lỗi "managed auth files no longer match"/"changed again after activation" (`tui.rs:864-883`) — nên nhân rộng.
4. **JSON chủ yếu là DTO typed trong `model.rs`** với enum `snake_case` (`AiProvider`, `SaveAction`, `ProviderUsageStatus`, `UsageFidelity`) và `skip_serializing_if` cho optional mới; Swift decode `decodeIfPresent` nên **thêm field là an toàn** (`AccountStore.swift:3092-3101`, `RustDate` đọc được cả string/mảng). Nền tốt để làm contract v2 additive.
5. **`--password-stdin`** cho export/import tránh lộ password qua argv (`cli.rs:1151-1166`); Swift dùng đúng (`AccountStore.swift:2251,2261`). Giữ và mở rộng `--password-env`.
6. **Kỷ luật stream**: human success → stdout, cảnh báo → stderr, lỗi → stderr `error:` (main.rs), TUI → stderr; `activate --json` chủ động suppress process table (`cli.rs:715-717`). Giữ nguyên khi thêm `--format`.
7. **Guard rail process đúng**: `--force` **không** vượt live Codex CLI (`cli.rs:718-729`; `service.rs:1469-1477`); phân biệt message CLI vs Desktop; `activate_with_expected_active` chống lost-update cho auto-switch (`service.rs:844-880`) — không nới guard này.
8. **Lock có timeout + message hành động được** (`operation_lock.rs:55-77`) và `AutoSwitchLock` serialize decide/apply giữa GUI/TUI/worker. Chỉ cần thêm progress/timeout flag, không đổi cơ chế.
9. **Rollback có đường lui**: `restore_snapshot_with_retry` backup + verify stable + context "recovery files retained at …" (`codex.rs:440-510`); đây là lý do không có Critical trong phạm vi này.
10. **Thời gian local trong TUI đúng DST** nhờ `format_local_reset_at` (`time_display.rs:3-9`) — chỉ cần dùng nó ở CLI human `list`/`usage` thay vì `.date()` UTC.
11. **`--json` coverage gần đầy đủ** (32/33 top-level) và Swift tự thêm `--json` phòng thủ khi decode (`AccountStore.swift:3090-3093`). Giữ thói quen này khi thêm lệnh.
12. **Test TUI đặt tên theo invariant** (`persistent_menu_keeps_unicode_rows_and_selection_aligned_across_width_changes`, `..._fits_terminal_height...`, `jump_section_switches_between_accounts_and_actions`) — tài sản để refactor an toàn.

---

## Giả định & giới hạn kiểm chứng

1. **Không chạy lệnh app nào** (kể cả `status`/`list`) vì `env::detect()` có thể migrate/rename app-data legacy (`src/env.rs:48-88`) và `status` đọc `~/.codex`. Chỉ chạy `--help`, `--version`, lệnh sai để đo exit code 2. Do đó **không có mẫu JSON thực tế**; kết luận timestamp dạng mảng dựa trên: `Cargo.toml:37` không bật `serde-human-readable`, source `time 0.3.47` (`serde/mod.rs:309-360`), decoder Swift `RustDate` xử lý mảng 9 phần tử (`AccountStore.swift:5141-5166`), và CHANGELOG:500 xác nhận "Rust `time` array timestamps". Confidence Cao nhưng nên verify bằng 1 fixture JSON khi làm P1.
2. **Không chạy `cargo test`** (theo yêu cầu tránh target lock); số test lấy từ `grep -c "#\[test\]"`: `cli.rs` 4, `tui.rs` 15, `model.rs` 3. Không đánh giá coverage thực thi.
3. **Hành vi TUI trong terminal thật chưa quan sát** (không có PTY trong phiên audit): kết luận Ctrl-C/non-TTY/color dựa trên source `console 0.16.3` (`term.rs:296-302`, `unix_term.rs:29-34,214-228,345-371,403-423`) + code path; nên chạy thử 1 lần trong Terminal/iTerm trước khi fix.
4. **Latency là suy luận từ call-path/hằng số**, không profile: timeout network 5 s (`usage.rs:800-805`), lock 90 s (`operation_lock.rs:13-15`), N account sweep tuần tự (`service.rs:1018-1041`), scan activity có thể đọc toàn rollout (`session_resume.rs:465-495`). Số liệu "vài giây–30 s+" là ước lượng worst-case, cần đo bằng `CODEX_ROSTER_PROFILE_SWITCH`/timing.
5. **Contract Swift đọc tĩnh**, không chạy GUI: dựa trên `AccountStore.swift` (decode, timeout 120 s, error hiển thị) và `OperationsView.swift:307`. Chưa kiểm chứng version skew thực tế khi CLI ngoài bundle mới hơn app.
6. **Feature `external-providers`**: kết luận "không có trong release" dựa trên `scripts/build-macos-app.sh:13` (không `--features`), fingerprint `build/cargo-target/release/.fingerprint/...` (`features:["default"]`), và không có script/CI release nào bật. Nếu quy trình release khác trong CI không đọc được, kết luận này có thể sai — cần xác nhận với người vận hành build.
7. **Phạm vi trùng lặp có chủ ý**: audit 03 đã báo gốc chi phí `status()`/`discover_interrupted_sessions` (P1) và lệch hiển thị 1% vs 0% (Q7). Report này **không lặp lại phân tích** mà chỉ nêu tác động lên CLI/TUI contract (LAT-01) và bỏ Q7 khỏi bảng để tránh trùng.
8. **Ngoài phạm vi**: security/Keychain threat model, logic auto-switch/thuật toán quota, Swift UI/notch, performance tuyệt đối — thuộc các audit khác trong cùng đợt. Không đánh giá code Windows/Linux legacy còn sót trong `model.rs`/test dù README:96 nói macOS-only.
