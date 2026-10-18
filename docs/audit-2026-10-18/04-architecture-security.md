# Audit kiến trúc, bảo mật & độ tin cậy — Codex Roster (2026-10-18)

- **Đối tượng:** commit `8f27e8c` (`chore(release) — sync Cargo.lock package version to 0.5.0`), phiên bản 0.5.0, 128 file tracked (~9,3 MB).
- **Phạm vi:** toàn bộ Rust core `src/` (~32,8k LOC trên đĩa, 412 test), Swift app `macos/NextAccount/` (15,3k LOC / 40 file, 69 `@Test`), build/release (`scripts/`, `dist-workspace.toml`, `.github/workflows/ci.yml`), docs và các audit trước.
- **Phương pháp:** đọc source tĩnh, `git log/ls-files/status/config/check-ignore`, `grep`, `awk`, `wc`, `du`, `stat`. **Không** chạy `cargo build/test/clippy`, **không** đọc/ghi Keychain thật, **không** chạm `~/.codex`, **không** gọi mạng, **không** sửa source. Chỉ ghi duy nhất file báo cáo này.
- **Ý nghĩa “vị trí”:** `file:line` là line hiện tại của commit trên; dòng có thể lệch nếu working tree thay đổi.

## Phạm vi & phương pháp

### Threat model thực tế (recap)

Sản phẩm đổi credential **cho cùng một local user**; không có multi-user/remote privilege boundary. Vì vậy mọi thứ dưới đây phải đọc theo 4 boundary đã nêu:

| Thành phần (asset) | Vị trí | Giá trị với attacker |
|---|---|---|
| Live Codex credential | `~/.codex/auth.json`, `~/.codex/cap_sid` | Refresh token (single-use) → chiếm account, xoay session |
| Snapshot đã lưu của mọi account | `<app_data>/snapshots/*.snapshot` (age/scrypt, key file) | Toàn bộ account đã lưu |
| Automatic full backup | `<app_data>/automatic-backups/*.codexroster` ×5 | Như trên, một file duy nhất |
| Master key | `<app_data>/keys/*.key` + Keychain `com.codexroster.app` | Giải mã toàn bộ snapshot/backup |
| Provider credential (Claude/Cursor/Grok, feature-gated) | snapshot + Keychain phụ | Account ngoài OpenAI |
| Metadata roster | `metadata.json`, `account-list-backups/` | Email/sub/plan, danh sách account |
| App bundle + updater | `/Applications/Codex Roster.app`, `GitHubUpdater` | Code execution khi thay bundle |

**Boundary & khả năng attacker:**

1. **Other process cùng UID** — đọc mọi file user đọc được, `flock` cùng file, `pgrep/kill` process cùng UID, `launchctl setenv`/shell profile để đổi env của app khởi động từ GUI, đọc Keychain item nếu ACL cho phép hoặc nếu key có trên đĩa. **Không** root, **không** làm giả code signature Developer ID, **không** MITM TLS (trừ khi cài CA riêng — ngoài model).
2. **Supply chain** — npm registry/npx, GitHub API + release asset, crates.io/Cargo.lock, GitHub Actions tags. Attacker giả định có thể chiếm một trong các kênh ở mức “đăng được artifact mới” (compromised maintainer/release), **không** cần private key ký macOS.
3. **Untrusted input** — file `.codexroster` do người khác gửi, file rollout/session do Codex sinh (`~/.codex/sessions/**`, `state_5.sqlite`), JSON từ `status.openai.com` / `codex-resets.com` / GitHub API / VibeCafe.
4. **Concurrency/crash** — GUI (Swift subprocess CLI), TUI, background workers, `codex`/Desktop cùng đọc-ghi `~/.codex`; crash/power loss giữa transaction; lock chỉ giữa các process Roster.

### Thang mức & confidence

| Mức | Ý nghĩa trong báo cáo này |
|---|---|
| **Critical** | Compromise tức thời, không cần same-UID và không cần điều kiện phụ. **Không có finding nào ở mức này.** |
| **High** | Vượt một control bảo mật rõ ràng với trigger thực tế trong 1 trong 4 boundary; blast radius lớn (toàn bộ credential, code execution khi update, mất khả năng recovery). |
| **Medium** | Vi phạm boundary thật nhưng cần điều kiện (same-UID, third-party feed bị chiếm, disk full), hoặc ảnh hưởng availability/recovery. |
| **Low** | Defense-in-depth, hardening, docs, hygiene; tác động tối thiểu hoặc cần precondition khó. |

Confidence: **Cao** = đọc được trực tiếp trong source + test/CI; **TB** = suy ra từ code + hành vi nền tảng (APFS, Gatekeeper, Keychain) nhưng chưa chạy thực; **Thấp** = cần runtime để xác nhận.

## Bản đồ kiến trúc & nợ kỹ thuật

### Module map (LOC trên đĩa; prod = trước `#[cfg(test)]` đầu tiên)

| Tầng | Module | LOC | Vai trò | Ghi chú nợ |
|---|---|---:|---|---|
| Entry/CLI | `src/main.rs`, `src/cli.rs` | 12 + 1631 | Clap 30+ subcommand, output `--json` cho Swift | Không có lớp “command” riêng; CLI vừa parse vừa orchestrate |
| App service | `src/app/service.rs` | 4134 (prod ~1486, 57 fn) | Toàn bộ use-case account: save/activate/delete/usage/backup/auto-switch | God service; `App<S>` trộn env, repository, policy, process guard |
| App khác | `src/app/providers.rs` 2216, `provider_auto_switch.rs` 866, `claude_desktop.rs` 584, `usage_refresh.rs`, `auto_switch_monitor.rs`, `tui.rs` 1451 | ~5,4k | Provider/auto-switch/TUI/worker | Worker sống bằng `static` + `eprintln!` |
| Domain | `src/codex.rs` 1526, `src/usage.rs` 2003, `src/session_resume.rs` 1261, `src/token_usage.rs` 1014, `src/reset_tracker.rs` 1057, `src/codex_activity.rs`, `src/quota_history.rs` | ~8k | Đọc/ghi auth, quota, resume, reset | Gọi HTTP/fs/process trực tiếp, không port |
| Storage | `src/repository.rs` 3248 (prod ~1282), `repository/index_store.rs` 691, `provider_store.rs` 994, `secrets.rs` 933, `file_store.rs` 311, `backup.rs` 476, `settings.rs` 213 | ~5,8k | Snapshot/secret/metadata/backup atomicity | `file_store` không fsync; `index_store` backup list ghi thẳng |
| Providers | `provider/{claude 1886,cursor 562,grok 445,openai,pace,mod 432,claude_keychain 252,claude_locks}` | ~4,2k | Adapter external provider | Biên dịch **luôn**, dù default build không expose |
| Infra | `env.rs` 216, `process.rs` 1005, `operation_lock.rs` 252, `identity.rs`, `vibe_usage.rs` 230, `claude_quota_bridge.rs` 520 | ~2,6k | Env, process scan/lsof, flock, JWT | Env/HTTP/clock/process đều là global function |
| Swift app | `AccountStore.swift` **5247** (204 func), `NextAccountApp.swift` **2432** (46 func), `PrismQuickSwitchDeck` 1460, `NotchWindow` 643, `GitHubUpdater` 513 + 35 file | 15,3k | UI + orchestrator gọi CLI + auto-switch/resume/update | God class `AccountStore`; một chiều Rust→JSON→Swift là contract duy nhất |

### Hướng phụ thuộc — điểm gãy

- `lib.rs:1-28` export **mọi** module public, kể cả `claude_quota_bridge` (`lib.rs:6`) và `provider` (`lib.rs:17`) không theo feature; do đó `src/app/providers.rs`, `provider/claude.rs`, `provider/cursor.rs`, `provider/grok.rs`, `claude_quota_bridge.rs` (~5,6k LOC) luôn được biên dịch dù default features = `[]` (`Cargo.toml:14-22`). Chỉ **CLI surface** và binary `claude-quota-bridge` bị gate (`cli.rs:16,257,1253-1366`), nên code Claude trong default build là dead-from-CLI nhưng vẫn reachable qua đường import backup/provider store.
- `app` phụ thuộc trực tiếp `repository` cụ thể (`app.rs:24`), `repository` phụ thuộc `secrets` trait (tốt, `secrets.rs:33-37`) nhưng `app`/`domain` gọi HTTP (`ureq::get`) và `Command::new` trực tiếp — không có port cho clock/HTTP/process. Hệ quả: unit test phải dùng đồng hồ thật/`std::process` thật; chỉ filesystem + secret store được fake.
- Swift không dùng FFI; mọi tương tác qua `codex-roster … --json` (`AccountStore.swift:3110-3160`). Contract schema nằm ở `model.rs` và struct `Codable` Swift, không versioned, không có test “real binary ↔ Swift decode”.

### God object (số liệu)

| Object | LOC | fn | Trách nhiệm đang trộn | Đánh giá |
|---|---:|---:|---|---|
| `AccountStore.swift` | 5247 | 204 | CLI transport, login watchdog, kill/relaunch Desktop, session-resume deep-link, quota/auto-switch, settings/UserDefaults, notch state, error mapping, backup trigger, update-adjacent marker | **Nặng nhất**; mọi thay đổi credential đi qua đây |
| `NextAccountApp.swift` | 2432 | 46 | App lifecycle, single-instance lock, menu/notch, nhiều View + route | Tách được phần lớn là View |
| `app/service.rs` | 4134 (prod 1486) | 57 | Use-case + policy + orchestration + file/process | Có thể tách theo use-case |
| `repository.rs` | 3248 (prod 1282) | 46 | Snapshot CRUD + import transaction + backup + recovery + validation | Có thể tách transaction engine |
| `app/providers.rs` | 2216 (prod 1114) | 26 | Provider lifecycle + quota + desktop + auto-switch policy | Có thể tách policy/IO |

### Refactor đích đề xuất (kèm thứ tự strangler)

Mục tiêu: giữ behavior, giảm bán kính thay đổi cho đường credential. Đề xuất module map:

```
src/
  domain/            // pure, no fs/net/proc: model, identity parse, quota policy, switch policy, error enum
  ports/             // Clock, HttpClient, ProcessProbe, CommandRunner, SecretStore, SnapshotRepo, SettingsRepo
  platform/          // ureq Http, sysinfo/lsof, Command, keyring, macOS paths (adapters)
  storage/           // atomic file engine (fsync!), snapshot/metadata/backup/index, recovery
  usecase/           // activate, save, import_backup, auto_switch, usage_refresh (chỉ gọi ports)
  app/               // CLI/TUI/GUI bridge, JSON DTO (versioned), workers
```

| Bước | Việc | Effort | Impact | Risk | Phụ thuộc |
|---|---|---|---|---|---|
| X1 | Bọc `Clock`/`HttpClient`/`CommandRunner`/`ProcessProbe` thành trait + adapter thật; inject vào `App`/`Usage` | M | Test được time/network/process, hết flaky | Thấp | — |
| X2 | Tạo `storage::atomic` chuẩn (temp+fsync+rename+dir-fsync, 0600) rồi thay `file_store`, `index_store`, `codex`, `secrets`, `session_resume` | S–M | Đóng R1/R2/R3 | Thấp | X1 |
| X3 | Tách `repository` thành `snapshot_store` + `backup_tx` + `metadata_store`; giữ API import transaction | M | Giảm ~1,3k prod LOC/file, test tách được | TB | X2 |
| X4 | Tách `service.rs` theo use-case (`activation.rs`, `roster_ops.rs`, `usage_ops.rs`, `backup_ops.rs`), policy ra `domain/` | M | Review an toàn dễ hơn, lock order rõ | TB | X3 |
| X5 | Định nghĩa JSON contract có `schema_version` + error code cho CLI; Swift decode theo contract; thêm test chạy binary thật | M | Bỏ string-matching, bỏ drift Rust↔Swift | TB | X4 |
| X6 | Tách `AccountStore` thành `CLIClient`, `ActivationCoordinator`, `QuotaStore`, `DesktopController`, `SessionResumeController`, `RosterStore` (ObservableObject mỏng) | L | Giảm god object; test Swift không cần UI | TB–Cao | X5 |
| X7 | Xoá/đóng băng `external-providers` (xem A3): chọn “archive vào branch” hoặc “feature thật sự gate toàn bộ module+data” | S | Compile/audit surface sạch | Thấp | — |

## Phát hiện

> Không có **Critical**. Các finding High đều nằm trong boundary “same-UID” hoặc “supply chain/release”; không có lỗi cho phép remote unauthenticated compromise. Bảng A là nợ kiến trúc (severity theo mức độ cản trở bảo trì/an toàn), không phải lỗ hổng trực tiếp.

### A. Kiến trúc & bảo trì

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| A1 | **High (bảo trì)** | `macos/.../AccountStore.swift:1-5247` (204 fn); `NextAccountApp.swift:1-2432`; `src/app/service.rs:1-4134` (57 fn); `src/repository.rs:1-3248`; `src/app/providers.rs:1-2216` | Mọi thay đổi credential/auto-switch phải sửa file 5k dòng, khó review, dễ regression ở đường auth; `check-auth-switch-safety.sh` phải bám text vào chính các file này | Strangler X2–X6 ở trên; đặt “module budget” (≤800 LOC/file cho domain, ≤1200 cho adapter) | Cao |
| A2 | **Medium** | `src/usage.rs:805,838,871,955`; `src/openai_status.rs:45-58`; `src/reset_tracker.rs:255`; `src/process.rs:31`; `src/codex.rs` (fs trực tiếp); `src/env.rs:14-30` | Không inject được clock/HTTP/process/Command → test phải dùng đồng hồ thật, network thật hoặc bỏ qua; không test được “feed trả body khổng lồ”, “lsof fail”, “clock nhảy” | Ports/adapters (X1); `Clock::now_utc()` thay `OffsetDateTime::now_utc()` (146 lần xuất hiện toàn repo, phần lớn trong test) | Cao |
| A3 | **Medium** | `Cargo.toml:14-22`; `src/lib.rs:5-6,17-18`; `src/cli.rs:16,257,1253-1366,1548`; `src/provider/claude.rs` 1886 LOC; `src/app/providers.rs` 2216 LOC | `external-providers=[]` chỉ gate CLI + bin; ~5,6k LOC provider luôn compile, luôn phải review CVE/behavior, dù README không còn nhắc Claude; ngược lại, import backup có `provider_accounts` vẫn đi vào code provider khi feature off (`repository.rs:705-724,800-819`) | Hoặc (a) gate toàn bộ module + variant data bằng feature, hoặc (b) archive hẳn code+docs (branch riêng), không để nửa vời; ghi rõ trong README/AGENTS | Cao |
| A4 | **Medium** | Rust: `src/process.rs:31-166`, `src/app/service.rs:1469-1519`; Swift: `AccountStore.swift:206-240,3580-3615,1613-1725,4968-4995`; ràng buộc chéo: `scripts/check-auth-switch-safety.sh:5-60` | Cùng một policy (process nào block switch, “force” được phép khi nào, thread nào resume, lỗi nào block activate) được cài **hai lần** ở 2 ngôn ngữ; script grep text để ép invariant → refactor đổi tên hàm là fail CI, còn logic lệch thì không ai bắt | Đưa policy về Rust (một nguồn), Swift chỉ hiển thị; hoặc tách `policy.json`/contract test; thay script grep bằng test hành vi | Cao |
| A5 | **Medium** | `src/provider_store.rs:20,516`; `src/usage.rs` (`usage_error_*`); `macos/.../AccountStore.swift:4985-4995,4968` | Contract Rust↔Swift là **free text** (`error.contains("login required")`, `starts_with("login_required")`); đổi câu chữ tiếng Anh → GUI mất phân loại “cần login”, có thể chặn/không chặn activate sai | Error code enum + JSON envelope (`{code,message,retryable}`), migration tương thích; test golden cho mọi code | Cao |
| A6 | **Low** | `src/backup.rs:185-199` (`static CACHE`); `src/usage.rs:34` (`TOKEN_REFRESH_LOCK`); `src/app/usage_refresh.rs:22-24` (2 static), `:92-120` (`STARTED`, `STOP`); `src/app/auto_start.rs` | Global state sống theo process: không tạo được 2 `App` độc lập trong 1 process (ngoài test), thứ tự test có thể ảnh hưởng; worker `OnceLock` không restart được | Chuyển cache/lock vào instance (`AppContext`), worker nhận handle + `JoinHandle`/CancelToken | TB |

### B. Bảo mật

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Exploitability | Blast radius | Đề xuất | Confidence |
|---|---|---|---|---|---|---|---|
| S1 | **High** | `src/backup.rs:204-232` (file-first), `243-275` (`read_key_file` đọc plaintext), `278-330` (`write_key_file_at`, 0600), `332-364` (xattr exclude best-effort); service `AUTOMATIC_BACKUP_KEY_SERVICE="com.codexroster.app"` `backup.rs:10`; README Keychain prompt | Key giải mã **nằm plaintext** ở `<app_data>/keys/automatic-backup-key-v1.key` + `local-snapshot-key-v1.key` (0600). Bất kỳ process cùng UID, tool backup/sync không tôn trọng xattr (`rsync`, `iCloud`, clone volume, `tar`, forensic image), hay malware đọc được file → giải mã **toàn bộ snapshot + 5 automatic backup** → refresh/access token của mọi account đã lưu. Đây chính là boundary #1 trong threat model | Rất thấp với same-UID: `cat` file; không cần Keychain prompt | **Toàn bộ account đã lưu** (không chỉ account đang live) | Dùng Keychain item (Data Protection, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) làm **KEK** để wrap DEK; file chỉ chứa ciphertext của DEK. Nếu vẫn giữ tradeoff “file là source of truth” (lý do ad-hoc signature ở `backup.rs:204-208`), thì (a) ghi rõ trong README rằng mã hoá **không** bảo vệ trước same-UID, (b) dùng `wrap` bằng Secure Enclave/Keychain là hướng đúng, (c) chặn backup bằng `NSURLIsExcludedFromBackupKey` + kiểm tra lỗi thay vì `let _` | Cao |
| S2 | **High** | `scripts/build-macos-app.sh:41-58` (ad-hoc nếu không có `CODE_SIGN_IDENTITY`, `--deep`), `:61-66` notarization **chỉ khi** có `NOTARYTOOL_PROFILE`; `.github/workflows/ci.yml:54-55` build không set 2 biến này; `CHANGELOG.md:601,692` xác nhận “ad-hoc by default, notarization manual”; `GitHubUpdater.swift:354-371` (`verifyCodeSignature`), `373-384` (`installedDesignatedRequirement` trả `nil` với ad-hoc → chỉ check validity); `UpdaterSignatureTests.swift:5-30,50-56` (cả 2 phía đều ad-hoc) | Release build mặc định ad-hoc → updater không pin được identity; kẻ chiếm được GitHub release/digest (hoặc asset) có thể đưa bundle ad-hoc hợp lệ, vượt `SecStaticCodeCheckValidity` vì requirement = `nil`; user nhận code exec trong `/Applications`, không có cảnh báo Gatekeeper nếu máy đã tải trước đó | Cần compromise GitHub release (không MITM TLS) **hoặc** maintainer build local quên env; không khai thác từ máy local thường | Code execution as user + persistence thay app; đọc mọi credential app quản lý | (1) Ký Developer ID + hardened runtime **bắt buộc** trong release CI, fail nếu thiếu; (2) notarize + `stapler validate` trong CI, fail nếu thiếu; (3) updater **từ chối** update nếu installed app ad-hoc/không có Team ID (fail closed) trừ khi dev mode; (4) thêm test “ad-hoc candidate bị từ chối khi installed có Developer ID” | TB |
| S3 | **Medium** | `src/app/usage_refresh.rs:100-115` (`Command::new("npx")` mỗi 30 phút), `src/cli.rs:1498-1509`, `src/vibe_usage.rs:8-10` (`@vibe-cafe/vibe-usage@0.13.2`) | Đã pin version (fix H1 cũ) nhưng vẫn chạy `npx --yes` → npm vẫn tải/execute package + **postinstall scripts**, transitive deps không pin theo lockfile, `npx` resolve qua `PATH` kế thừa từ process cha. Compromise package/registry/`npx` shim → code exec user, lặp lại mỗi 30 phút | Trung bình (cần compromise npm hoặc package pinned bị chiếm; PATH hijack cần env) | Code exec user; đọc được mọi credential app | Ship collector trong process (chỉ là HTTPS GET), hoặc vendor binary + SHA-256 tự verify, hoặc `npm ci` trong thư mục cố định với lockfile và gọi `node_modules/.bin` tuyệt đối; kiểm tra `npx` là `/usr/local/bin/npx`… | Cao |
| S4 | **Medium** | `GitHubUpdater.swift:236-251` (digest bắt buộc từ GitHub API), `:253-298` (size ≤128MB **sau khi** `URLSession.download` hoàn tất), `:288` `ditto -x` không giới hạn kích thước giải nén, `:250` `browserDownloadURL` không allowlist host | Asset URL do GitHub API trả về (kẻ chiếm release có thể trỏ host ngoài); ZIP ≤128MB có thể giải nén thành hàng GB vào `~/Library/Application Support/.../updates` trước khi signature/digest bị kiểm → đầy disk, update fail, ảnh hưởng cả app khác | Cần quyền đăng release; cùng UID không làm được (URL/SHA do GitHub trả) | Availability/disk; tiềm năng che dấu payload lớn | Giới hạn host asset (`github.com`/`objects.githubusercontent.com`), cap số entry + tổng uncompressed size trước khi move, dùng `URLSession` với `expectedContentLength`/streaming cap, verify signature **trước** khi extract nếu có thể (kiểm outer bundle sau extract vẫn ok) | TB |
| S5 | **Medium** | `src/usage.rs:805-825,838-853,871-881,955-966`; `src/reset_tracker.rs:255-270`; `src/openai_status.rs:45-70`; `src/vibe_usage.rs:79-100` | Toàn bộ dùng `read_json` không cap body. Feed thứ ba (`codex-resets.com` — **không phải OpenAI**, `reset_tracker.rs`/README) hoặc status endpoint bị chiếm/ lỗi trả body rất lớn trong 5–8s timeout → memory spike/OOM ở process CLI đang chạy (GUI poll 45s → crash loop) | Cần chiếm/hỏng feed thứ ba; hoặc server lỗi trả HTML lớn | Availability; process crash, không lộ secret | Cap `Content-Length` + `.take(MAX_BODY)` khi đọc body (VD 2MB), reject non-JSON content-type; áp dụng cả `ureq` response và `vibe_usage` cache | Cao |
| S6 | **Low** | `Cargo.toml:43-44` (`keyring 3.6.3`, `apple-native`), `src/backup.rs:204-232` | `keyring` macOS dùng **file-based keychain** (`SecKeychain*`), không set `kSecAttrAccessible`, không `kSecUseDataProtectionKeychain`/`ThisDeviceOnly`. Item không được bảo vệ bởi Secure Enclave/device-bound; ACL gắn code signature → ad-hoc build đổi hash gây prompt lặp; item có thể bị copy theo login keychain. Trên thực tế S1 làm Keychain thành bản sao dự phòng, không phải control chính | Thấp (cần đọc được keychain item; S1 dễ hơn) | Toàn bộ credential đã lưu nếu đọc được | Chuyển sang Data Protection Keychain (`kSecUseDataProtectionKeychain`), `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, tạo item bằng `SecItemAdd` với access control; hoặc dùng Secure Enclave key wrap (S1) | TB |
| S7 | **Low** | `src/backup.rs:113-160` (`read_encrypted`, caps 64/96MB), `:62-75` (`write_encrypted`); age 0.11.5 `scrypt` max work factor = target+4 | `.codexroster` không tin cậy: attacker chọn `log_n` tối đa ~16× target (~16s CPU) và 96MB plaintext JSON → import/prompt treo lâu (CLI GUI gọi với timeout 120s), memory tăng; không RCE | Thấp: chỉ DoS khi user tự import file | Availability UI, có thể timeout giữa chừng (không hỏng dữ liệu vì import có staging/undo) | Đặt `set_max_work_factor` thấp hơn (VD target+1) và cap memory parse; chạy import ở worker có progress/cancel | TB |
| S8 | **Low** | `src/cli.rs:1151-1166` (`read_to_string` stdin không cap, prompt **không** confirm), `:800-825`; `src/backup.rs:62-75,113-160` | `--password-stdin` đọc vô hạn vào `String`; mật khẩu export không nhập lại để xác nhận (gõ sai → file không mở được, mất dữ liệu chuyển máy); `String` không zeroize (age tạo `SecretString` nhưng bản gốc còn trong heap/argv cũ không có) | Thấp | Mất khả năng phục hồi backup (availability), rò rỉ heap cục bộ | `Zeroizing<String>`, cap stdin (VD 4KB), prompt 2 lần cho export, `--password-file`/env tránh pipe; ghi rõ trong help | Cao |
| S9 | **Low** | `src/cli.rs:133-143` (`RestoreAccountListBackup`, `RestoreFullBackup`), `src/app/service.rs:1159-1173` | CLI thay toàn bộ roster/provider store (restore full) mà không confirm/`--yes`/dry-run; gõ nhầm hoặc script lỗi → mất roster hiện tại. Có automatic backup sau restore nhưng bản thân lệnh không hỏi | Thấp (thao tác chủ động) | Mất roster/thứ tự account, phải recovery thủ công | Thêm `--yes` bắt buộc cho non-TTY, in diff số account trước khi thay; giữ auto-backup pre-restore | Cao |
| S10 | **Low** | `AccountStore.swift:3251-3262` (`CODEX_ROSTER_CODEX_PATH`/`CODEX_BINARY_PATH`), `:1669-1680` (`codexCLIBinaries`), `:3066-3083` (`CODEX_ROSTER_CLI_PATH` chỉ khi unbundled); Rust `provider/claude.rs:1191-1206` (PATH scan `claude`), `provider/claude_keychain.rs:96-160` | Binary chạy credential/login (`codex login`, `codex queue`, `claude --version`, `/usr/bin/security`) lấy từ env/PATH không verify signature. Ai set được env của GUI (`launchctl setenv`, LaunchAgent — cùng UID) hoặc PATH của shell → thay binary → code exec trong ngữ cảnh app | Thấp: cần same-UID set env (đã trong boundary, nhưng biến control thành code exec) | Code exec user; lộ credential khi login | Resolve binary theo path tuyệt đối từ bundle/homebrew cố định + verify `SecStaticCodeCheckValidity` (codex/claude) trước khi exec; chỉ cho env override sau flag dev | TB |
| S11 | **Low** | `AccountStore.swift:3580-3614` (`killOrphanDesktopCodexServers`: `pgrep -f <marker>` rồi `kill` mọi PID) | Process cùng UID đặt argv chứa marker `~/.codex/plugins/.plugin-appserver/codex` → bị SIGTERM/SIGKILL; PID reuse giữa pgrep và kill → kill nhầm process user. Trigger: local DoS/self-DoS, không leo quyền | Thấp (same-UID; không đọc/ghi secret) | Availability process user | Dùng `NSRunningApplication`/proc_pidpath verify executable + UID trước khi kill; `kill` theo handle giữ được; bỏ SIGKILL nếu không phải process desktop | TB |
| S12 | **Low** | `src/vibe_usage.rs:61-76` (chmod 0600 best-effort), `:79-96` (`api_url` từ config người dùng, gửi `Authorization: Bearer api_key` tới URL đó) | Config 0644 nếu chmod fail → lộ bearer key cho user khác; `api_url` attacker-controlled (ghi được config) chuyển key sang host attacker — nhưng attacker đã đọc được config nếu write được | Thấp | Lộ key VibeCafe (không phải OpenAI) | Fail-closed nếu file quá permissive (chỉ chấp nhận 0600/0400, else báo lỗi), allowlist `api_url` scheme https + host mặc định, hoặc bỏ `api_url` override | TB |

### C. Độ tin cậy, đồng thời & crash safety

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| R1 | **Medium** | `src/codex.rs:573-616` (`stage_and_restore` rename), `:624-655` (`copy_atomic`), `:657-676` (`write_private_staged_file` **không có `sync_all`**); `src/file_store.rs:99-190` (không fsync, kể cả `pending`); `src/repository/index_store.rs:55-74` (`fs::write` temp, không fsync); `src/secrets.rs:338-356`; `src/session_resume.rs:351`; ngược lại `backup.rs:88-93` **có** `sync_all` | Rename là atomic về **visibility**, nhưng không durable nếu thiếu fsync/fsync-dir: power loss/kernel panic ngay sau rename có thể mất data block → `metadata.json`/snapshot/`auth.json` rỗng hoặc cũ, hoặc index trỏ snapshot chưa persist. Recovery hiện xử lý “missing/corrupt”, không xử lý “truncated nhưng hợp lệ một phần”. `fs::write(pending)` còn tạo file 0644 (xem R3) | Chuẩn hoá 1 helper `atomic_write(path, bytes, mode)` = `create_new` → `write_all` → `sync_all` → `rename` → `fsync(parent)`; dùng cho metadata/snapshot/auth/settings/session index; test failure-injection cho fsync fail | TB–Cao |
| R2 | **Medium** | `src/repository.rs:1132-1137` (`maybe_write_automatic_full_backup` → `let _ = self.write_automatic_full_backup`), `src/repository/index_store.rs:72` và `:162` (`let _ = write_automatic_backup`) | Disk full/quyền sai/Keychain deny → automatic backup fail **không được report**; UI vẫn báo “đã giữ 5 backup”; khi cần restore mới phát hiện không có bản mới. Đúng lúc sự cố (hết disk) lại mất khả năng recovery | Trả `Result` lên use-case, gắn `warnings`/`backup_status` trong output (đã có field ở Swift `backupStatusMessage`), log qua kênh chuẩn; retry có backoff | Cao |
| R3 | **Medium** | `src/repository/index_store.rs:182-190` (`fs::write` thẳng vào `metadata-<gen>.json`, không temp+rename, không 0600), `:189-192` (`let _ = remove_file`); `:132-162` `restore_index` copy **mọi** file recovery thành `preserved-metadata-<uuid>.json` không cap; `src/file_store.rs:122` pending 0644; `src/repository/index_store.rs:70` | Crash giữa `fs::write` backup list → file JSON dở (recovery skip được nhưng mất bản mới nhất); mỗi lần restore tích luỹ file `preserved-metadata-*` vô hạn (disk growth); pending/metadata chứa email/plan ghi 0644, chỉ được che bởi `~/Library` 0700 — không phải control tường minh | Backup list cũng dùng atomic helper (0600); cap/rotate `preserved-metadata-*` (VD 20, hoặc gộp 1 file); tạo app data dir với 0700 tường minh; pending 0600 | Cao |
| R4 | **Medium** | `src/process.rs:121-140` (`pids_holding_auth_files`: lsof lỗi/timeout → `HashSet::new()`), `:143-166` (`filter_blocking`: skippable mà không có trong set → **cho qua**), `:89-120` (`--force` path); `codex.rs:449-520` verify 1s | Fail-open: nếu `lsof` không có/quyền bị chặn/timeout khi `--force`/auto-switch sau khi đóng Desktop, process `app-server` đang mở `auth.json` bị coi là skippable → ghi đè credential dưới open handle → Codex/Desktop dùng token cũ, refresh-token single-use bị invalidate, user bị logout/không switch được. Prior audit M6 đã fix phần chính nhưng fallback mới là fail-open | Khi lsof fail, **fail closed** (coi mọi skippable là blocking) trừ khi có cờ `--unsafe-force`; hoặc dùng `proc_pidinfo`/`lsof` với timeout + log lý do | Cao |
| R5 | **Low** | `src/app.rs:111-118` (`should_verify_activation_stability` luôn `true`), `src/codex.rs:440-520` (verify 4×250ms), `src/app/service.rs:844-970` | Cửa sổ 1s sau rename không bắt được writer đến muộn (Codex refresh token ghi lại sau khi đọc auth cũ); không có lock với Codex (chỉ `flock` nội bộ Roster). Đây là residual đã biết, không phải regression | Ghi rõ giới hạn trong docs; tăng verify khi có process desktop vừa quit; theo dõi mtime/content sau 2–3s; không tuyên bố “an toàn tuyệt đối” | TB |
| R6 | **Low** | `src/operation_lock.rs:10-92` (90s timeout, 50ms poll); `AccountStore.swift:3119-3180` (CLI timeout 120s, `:3155`) | TUI/worker giữ lock lâu (batch usage, import, backup ~1s scrypt) → GUI action chờ tới 90s với spinner; timeout trả lỗi chung “another operation” không nói ai giữ; UX tệ, dễ bấm lại | Giảm timeout theo operation (activate 10s, import 120s), trả lock owner (pid/op) trong lỗi, expose progress | TB |
| R7 | **Low** | `AccountStore.swift:1880-1915` (`runProcessCapturingOutput` đọc pipe **sau** `waitForExit`), dùng ở `:1644` (`codex queue`); `GitHubUpdater.swift:51-70` health marker; `:193-215` helper rollback loop | API đọc stdout/stderr sau khi process exit: nếu output > pipe buffer (~64KB) process block ở write → không exit → timeout 20s rồi terminate; hiện caller chỉ dùng cho output nhỏ nên chưa xảy ra, nhưng là trap cho lần mở rộng. Health marker write fail (App Support readonly) → helper rollback sau 5 phút, app cũ mở lại, update được offer lại → vòng lặp update | Dùng `PipeCapture` (đã có, `:3139`) cho mọi capture; marker trong `$TMPDIR`/fallback + log; nếu rollback lặp 2 lần thì disable auto-update và báo user | TB |

### D. Hiệu năng & tài nguyên

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| P1 | **Medium** | `AccountStore.swift:2016-2035` (`startCoreMonitoring` → `refresh`, `refreshResetOutlook/Timeline/Juice`, `ensureAutomaticFullBackup`), `:2294-2299` (backup = CLI process + keychain + age scrypt ~1s), `:535-545` (`refresh`), `:2453-2500` (reset refresh) | Cold start bắn ≥6 subprocess CLI **tuần tự**, mỗi process load 8,2MB binary, đọc/decrypt snapshot, có thể prompt Keychain; kèm 4 network call (reset/status) → notch/menu chậm vài giây, CPU burst; `create-automatic-full-backup` chạy ngay khi launch dù cooldown 30 phút | Gộp 1 subprocess `status --json --include=…` cho burst đầu; chạy backup sau 30–60s idle; cache kết quả status vào memory; show skeleton thay vì block | Cao |
| P2 | **Medium** | `src/app/service.rs:52` (`status` luôn `detect_running_codex_processes`), `:1005` (`activation_preflight_warnings`), `src/process.rs:31-47` (sysinfo refresh **toàn bộ process** + cmd/exe), `src/app/service.rs:844-970` (activate scan 2 lần + lsof), `AccountStore.swift:206-240` (`latestSessionWrite` duyệt 2 ngày session dirs, gọi ở `:2606`) | Mỗi `status` (GUI poll 45s, menu mở) spawn process + full process table scan; mỗi lần switch scan 2 lần + lsof; `latestSessionWrite` duyệt `~/.codex/sessions/YYYY/MM/DD` (có thể hàng nghìn file) trong poll quota | Cache process scan TTL 1–2s trong cùng invocation; chỉ scan khi cần; đọc sessions theo mtime/inode thay vì list toàn bộ; chuyển `isTurnActive` sang background + cache 5s | Cao |
| P3 | **Medium** | `Cargo.toml:49-52` (`[profile.dist]` chỉ `lto="thin"`, không `strip`, không `codegen-units=1`), `scripts/build-macos-app.sh:13` (`cargo build --release` dùng profile release mặc định), `:14`; artifact đo được: `build/CodexRoster.app/Contents/MacOS/codex-roster` 8,2MB, `CodexRoster` 6,6MB, **arm64-only**; `README.md:99` nói “build và ship cho Apple Silicon và Intel” | Release build không strip → bundle phình (ước 2–4MB); không universal binary nên Intel không chạy được artifact build từ script/CI (CI chỉ host arch), trái README | Thêm `[profile.release] lto="thin", strip="symbols", codegen-units=1`; build universal (`lipo`/`--target aarch64 + x86_64` rồi `lipo -create`) trong release; ghi rõ arch trong tên zip/README | Cao |
| P4 | **Low** | `AccountStore.swift:461-481` (quota 45s/15s/5s), `:2380-2390` (quota loop), `:2301-2330` (auto-switch loop 10–45s), `:2038-2062` (vibe 1800s); Rust `src/app/usage_refresh.rs:17-18` (usage 120s, vibe 1800s), `src/cli.rs:1177` + `AccountStore.swift:2038` (hai scheduler vibe độc lập) | Khi quota ≤5% → poll 5s = tối đa 12 subprocess CLI/phút + network; GUI và TUI cùng chạy → `npx sync` 2 lần/30 phút; poll cadence nhân với process spawn cost | Tăng interval khi user idle, backoff khi lỗi; dedupe vibe scheduler (chỉ Swift **hoặc** Rust); gộp quota+status vào 1 call | TB |
| P5 | **Low** | `Cargo.toml:41` (`rusqlite` bundled), `src/session_resume.rs:382` (`state_5.sqlite` hardcode), `src/app/claude_desktop.rs:115,225` (Cookies), `src/provider/cursor.rs:53` | `rusqlite bundled` tăng compile time/binary cho mục đích đọc DB; schema `state_5.sqlite` là contract ngoài, Codex đổi schema → im lặng fallback directory scan (session resume mất chức năng, không cảnh báo); module Claude vẫn compile dù feature off | Giữ bundled (hợp lý cho read-only) nhưng: dò `state_*.sqlite` + verify bảng/cột, fail loudly + log version; gate module Claude bằng feature (A3) | TB |

### E. Kiểm thử, CI & release

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| C1 | **Medium** | `.github/workflows/ci.yml:17,18,30,31,32` (`actions/checkout@v6`, `taiki-e/install-action@v2`, `actions-rust-lang/setup-rust-toolchain@v1`, `Swatinem/rust-cache@v2`) | Action tag mutable → compromised action/repo có thể chạy code trong CI có quyền đọc secrets/token, sửa artifact release; không có allowlist/SHA pin. Đây là supply-chain boundary #2 | Pin full commit SHA + comment version; bật Dependabot cho Actions; hạn chế `permissions:` (mặc định hiện là broad) | Cao |
| C2 | **Medium** | `ci.yml:39` (`clippy --all-features` — luôn kéo Claude vào), `:41` (`cargo test --all`, **không `--locked`**), `:13-23` (chỉ `cargo-audit`, không `cargo deny`/`cargo vet`, không license, không coverage) | Lockfile có thể bị update ngầm nếu resolve khác khi thiếu `--locked`; không chặn crate license/yanked/duplicate; không có coverage nên không biết đường credential có test. Job `audit` có chạy PR/push/cron nhưng chỉ dựa `cargo-audit` + DB fetch, không gate license/policy | `--locked` mọi lệnh cargo; thêm `cargo deny check` (advisories/bans/licenses/sources); coverage (tarpaulin/llvm-cov) với ngưỡng cho `secrets/repository/codex`; `cargo-vet` hoặc cargo-deny policy | Cao |
| C3 | **Medium** | Chỉ có `.github/workflows/ci.yml`; không có release workflow; `dist-workspace.toml:7-19` khai báo cargo-dist 0.31 + shell installer + `x86_64-apple-darwin` nhưng **không workflow nào dùng**; `ci.yml:54-55` build ad-hoc, không notarize/verify; không secret scan, không artifact scan, không E2E GUI↔CLI | Release hoàn toàn thủ công; không gate ký/notarize; không phát hiện secret commit; không test contract Swift↔Rust với binary thật → drift chỉ phát hiện khi user gặp | Thêm `release.yml` (tag) chạy package + codesign Developer ID + notarize + staple + verify + publish SHA256SUMS; thêm gitleaks/trufflehog; job E2E chạy `codex-roster --json` thật và decode bằng Swift test fixture; hoặc xoá `dist-workspace.toml` nếu không dùng | Cao |
| C4 | **Low** | `ci.yml:42-53`: `swift test list` rồi **mỗi test id một invocation** `swift test --filter`, `:25-55` không `timeout-minutes` | 69 test × process startup (mỗi lần launch test runner) làm CI chậm vài phút; job treo (network/Keychain) có thể chạy tới default 6h; filter cắt `id(parameter)` có thể che parameterized case | Chạy `swift test` một lần; thêm `timeout-minutes: 20`; cache `.build`; thêm `-Xswiftc -enable-testing` không cần | TB |
| C5 | **Medium** | Rust 412 test/`#[ignore]` 1 (`provider/claude_keychain.rs:240`); Swift 69 `@Test`/13 file; `UpdaterPreparationTests`/`UpdaterSignatureTests` chỉ test prepare/signature, **không** test `install-update.sh` end-to-end/rollback/health marker; `operation_lock.rs:113-160` chỉ test thread trong process, không test 2 process thật; không có failure-injection mất điện/fsync; không fuzz/property test cho `.codexroster`/snapshot import | Các đường rủi ro nhất (swap+rollback, updater install/rollback, lock xuyên process, import untrusted) không có test đúng mức; test hiện tại rất tốt cho logic policy nhưng không chứng minh crash-safety | Thêm integration test 2 process (spawn CLI thật với temp HOME, `flock`), test shell helper trong sandbox temp dir (đã có fixture `ditto` — mở rộng cho helper), fuzz `read_encrypted`/`serde` bằng `cargo-fuzz`/proptest (không cần network), test fsync failure qua wrapper file ops | Cao |
| C6 | **Low** | 146 lần `OffsetDateTime::now_utc()` toàn repo; ví dụ `src/repository.rs` backup cooldown `SystemTime::now` (`:1149`), `src/quota_history.rs` `minute_of(now)`; chỉ một số API nhận `now` (provider/claude tests); Swift dùng `Date()`/`Calendar.current` (`AccountStore.swift:202-240,4968`) | Test gần nửa đêm/đổi timezone, mtime granularity, “fresh ~10 phút” có thể flaky/muộn; Swift `latestSessionWrite` phụ thuộc calendar local | Inject clock (X1) cho mọi policy; test với `OffsetDateTime` cố định; thêm `TZ=UTC` cho test CI | TB |
| C7 | **Low** | `scripts/check-auth-switch-safety.sh:5-12` (`--force` count == 2), `:14-60` (sed range theo tên enum/fn), chạy ở `ci.yml:33-35` | Invariant được ép bằng grep/sed text: refactor hợp lệ (thêm force site thứ 3 có guard đúng) fail CI; ngược lại logic guard lệch nhưng text còn → pass. Không kiểm tra hành vi Swift↔Rust | Thay bằng behavioural test (spawn CLI, assert từ chối/cho phép) hoặc ít nhất AST-based check; nếu giữ, thêm comment “đây là guard thô, không phải proof” | Cao |

### F. Observability & supportability

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| O1 | **Medium** | Rust: 21 `eprintln!` ngoài test (vd `src/app/providers.rs:851`, `provider_auto_switch.rs:458`, `usage_refresh.rs:31,130`, `repository/index_store.rs:31,92,237`); Swift: 1 logger duy nhất `AccountStore.swift:13-18`, chỉ log error, không log state/quota/switch; CLI child stderr bị `PipeCapture` đọc rồi bỏ (`AccountStore.swift:3139-3181`) | Khi user báo “switch sai account/quota sai”, không có trace có cấu trúc (level, account id, generation, lock, process list); stderr của worker trong GUI không đến được unified log; không có signpost/interval | Dùng `tracing`/`os_log` thống nhất: JSON line (0600, rotate) + `os_log` category; log state transition + generation + elapsed; redact token/email mặc định; thêm `--verbose`/`RUST_LOG` | Cao |
| O2 | **Medium** | Không có subcommand `doctor`/`diagnostics` (CLI list `src/cli.rs:39-237` không có); env debug không tài liệu: `CODEX_ROSTER_AUTH_DEBUG` (`src/codex.rs:78`), `CODEX_ROSTER_PROFILE_SWITCH` (`src/app/service.rs:928`); log files `auth-debug.log` (`codex.rs:96-125`), `session-resume.log` (`AccountStore.swift:1788-1815`), `updater.log` (`GitHubUpdater.swift:164`) | Support phải hướng dẫn user tự tìm file/biến không có trong README; không có bundle để đính kèm issue (version, paths, lock state, key source, permissions, last errors) | `codex-roster doctor [--json]` + `doctor --bundle` (redact) gồm: version/SHA, paths, perms, key source (file/keychain, không value), lock holders, last 200 log lines, updater marker; document env debug | Cao |
| O3 | **Low** | `src/app/service.rs:783-789,913,1269,1318` (`auth-debug` log **email**), `src/app/providers.rs:851`/`provider_auto_switch.rs:458` (email ra stderr); `macos/.../GitHubUpdater.swift:156-170` (`updater.log`, path ở `:164`) | Email/PII nằm trong log file/thông báo; rotation có (1MB) và 0600, nhưng privacy policy không nêu; user gửi log cho support là lộ email + account list | Redact email (`a***@domain`) trừ khi `--verbose`; ghi rõ trong README “log có thể chứa email”; thêm cơ chế xoá log từ UI | Cao |

### G. Docs drift & repo/release hygiene

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| D1 | **Medium** | `README.md:99` (“builds and ships for macOS (Apple Silicon and Intel)”), `:13` (“macOS only, Windows/Linux removed”); thực tế `scripts/build-macos-app.sh:13-14` build host arch, CI `macos-latest` (arm64), artifact `file` = **arm64 only**; `dist-workspace.toml:13` khai báo x86_64 nhưng không workflow | User Intel tải ZIP arm64 → không chạy; tài liệu hứa nhiều hơn release thực tế | Universal build + CI matrix, hoặc sửa README theo artifact thật; ghi rõ arch trên release asset | Cao |
| D2 | **Low** | `build.rs:3-9` (`winresource::WindowsResource`), `Cargo.toml:23-47` **không có** `winresource`; `src/env.rs:107-125` nhánh Windows/WSL; `Cargo.toml:43-44` target macOS keyring; `README.md:13,224` nói đã bỏ Windows/Linux | Windows branch trong build.rs tham chiếu crate không tồn tại → build Windows fail; ~hundreds dòng cfg(not(unix))/WSL là dead-code không được CI chạm, dễ mục | Xoá toàn bộ nhánh Windows/Linux (hoặc thêm lại dependency + CI matrix nếu còn hỗ trợ); sửa build.rs | Cao |
| D3 | **Medium** | `CHANGELOG.md:5-11` (v0.5.0 “remove Claude UI/enrollment/continuity”); `docs/claude-quota-and-continuity.md:67-86` (mô tả AgentDock Claude surfaces), `docs/claude-quota-audit-2026-10-08.md`; code còn `src/provider/claude.rs` 1886, `src/app/claude_desktop.rs` 584, `src/claude_quota_bridge.rs` 520, `src/app/providers.rs` 2216; `provider_store`/`backup` vẫn xử lý provider (A3) | Docs và code nói hai câu chuyện: user/dev đọc docs tưởng có Claude, trong khi UI/CLI default không có; gây review sai surface, tăng nợ | Archive docs Claude vào `docs/archive/`, ghi banner “removed in 0.5.0”; quyết định dứt điểm feature (A3) và đồng bộ README/AGENTS | Cao |
| D4 | **Low** | `AUDIT-2025-10-02.md:33,53,98…` (line refs cũ, vd `usage_refresh.rs:53` nay là `:106`); audit cũ ở root (`AUDIT-2025-10-02.md`, `PR_DESCRIPTION.md`) trong khi audit mới ở `docs/audit-2026-10-18/`; `AGENTS.md`/`CLAUDE.md` yêu cầu GitNexus `impact` bắt buộc nhưng `.gitnexus/` nằm trong `.git/info/exclude` (không track) | Người mới/CI không tái lập được chỉ dẫn GitNexus; đọc audit cũ theo line number dễ kết luận sai “đã fix/ chưa fix” | Chuyển audit cũ vào `docs/audit-history/`, thêm banner “historical, line refs stale”; chuyển hướng dẫn GitNexus thành optional, commit config tối thiểu hoặc bỏ `MUST` | TB |
| D5 | **Low** | `contrib/macos-menubar/.venv` (43MB, có `.gitignore` nội bộ chứa `*` nên `git status` sạch, nhưng repo `.gitignore` không chứa `.venv`); `build/` 4,6GB (`build/cargo-target` 3,0GB, `AgentDock.app`, `Codex Roster.backup-*`, `AgentDock-0.4.9-macos.zip`), `target/` 39GB, `dist/` 8,1MB (`Codex-Roster-v0.2.1/2.2-macos.zip`) | Không tracked (tốt: `git ls-files build dist contrib` = 0), nhưng workspace dev phình 40GB+; `contrib/.venv` chỉ được ignore nhờ config global/nội bộ → máy khác sẽ thấy untracked 43MB; artifact cũ (`AgentDock.app`) dễ gây nhầm “bản đang chạy” | Thêm `.venv/`, `**/__pycache__/` vào `.gitignore` repo; script `scripts/clean-local-artifacts.sh` xoá build cũ (giữ 1 backup); đổi `target-dir` ra ngoài repo hoặc dùng `CARGO_TARGET_DIR`; xoá `dist/*zip` cũ | Cao |

### Đã kiểm tra — các lỗi prior audit đã hết (không còn lỗi)

| Prior ID (AUDIT-2025-10-02) | Trạng thái | Bằng chứng hiện tại |
|---|---|---|
| H1 `npx --yes` không pin | **Đã fix một phần** | `src/vibe_usage.rs:10` pin `@vibe-cafe/vibe-usage@0.13.2`; residual S3 (vẫn exec registry/postinstall + PATH) |
| H2 `fs::copy` follow symlink + non-atomic | **Đã fix** | `src/codex.rs:607-611` comment + `fs::rename` thay copy; test `:1247` “replaces symlink instead of writing through” |
| H3 script update ở `$TMPDIR`, không verify signature | **Đã fix** | `GitHubUpdater.swift:276,304,325-352` (SHA-256 + `SecStaticCodeCheckValidity` + designated requirement, staging 0700, rollback health marker); residual S2 (ad-hoc) |
| M1 `security -i` command injection | **Đã fix** | `src/provider/claude_keychain.rs:16-28,116-125` allowlist charset trước khi vào `security -i` |
| M2 `CODEX_ROSTER_CLI_PATH` hijack | **Đã fix (phần lớn)** | `CLILocator` ưu tiên bundled (`AccountStore.swift:3066-3084`), test `CLILocatorTests.swift:5-13`; env chỉ khi unbundled (nhánh dev, residual S10) |
| M3 plaintext snapshot key | **Giảm nhẹ, còn** | `src/backup.rs:332-364` 0600 + xattr `com_apple_backup_excludeItem` vẫn best-effort; vẫn plaintext → **S1 vẫn High** |
| M4 legacy migration symlink | **Đã fix** | `src/env.rs:98-120` `symlink_metadata`+uid+mode, test `does_not_adopt_a_symlinked_legacy_dir` |
| M5 third-party reset URL injection | **Đã fix** | `src/reset_tracker.rs:194-230` allowlist host/path/charset + `is_status_id` |
| M6 TOCTOU lock gap | **Đã fix (phần lớn)** | atomic rename (`codex.rs:607-611`) + `lsof` holder check (`process.rs:121-166`); residual fail-open R4 |
| L1 `auth-debug.log` no rotation/perms | **Đã fix** | `src/codex.rs:96-125` create 0600, rotate 1MB, refuse symlink |
| L2 `session-resume.log` perms | **Đã fix** | `AccountStore.swift:1797-1815`, rotate 1MB, 0600, regular-file check |
| L3 vibe config 0644 | **Fix một phần** | `src/vibe_usage.rs:61-76` chmod 0600 best-effort; residual S12 |
| L4 TLS/timeouts | **Chấp nhận** | system TLS; timeout 5–8s (`usage.rs:805`, `reset_tracker.rs:260`, `openai_status.rs:45-58`); residual S5 (body cap) |
| L5 unwrap density | **Đã hết (claim cũ sai/sửa rồi)** | Production còn **1** `.expect()`: `repository.rs:201` (`path.parent().expect("provider index parent")`, thực tế không thể None); hai `.unwrap()/.expect()` còn lại trong phép đếm thô (`cli.rs:1583`, `usage_refresh.rs:161`) nằm trong module test được gate bằng `cfg(all(test,…))` nên phép đếm theo `#[cfg(test)]` bỏ sót. Không có `unsafe` trong `src/` |
| L6 `ureq`/audit | **Đã fix** | `ci.yml:13-23` `cargo audit` định kỳ; `Cargo.lock` khóa `age 0.11.5`, `ureq 3.1.2`; residual C2 (deny/vet/`--locked`) |
| Q1 worker loop không dừng | **Fix một phần** | vibe worker có `StopSignal`/Condvar (`usage_refresh.rs:41-120`); usage-refresh worker vẫn `loop` không stop (`:22-40`) — chỉ ảnh hưởng TUI exit |
| Q2 `cancel_add_account_session` non-atomic | **Đã fix** | dùng `restore_from_backup`→`copy_atomic` (`codex.rs:624-655`) |
| Q3 legacy recovery index/snapshot ordering | **Đã fix** | secrets trước index + undo log (`repository.rs:300-355`, comment 311-315) |
| Q4 `let _ = mode_0600` | **Còn (vô hại)** | `provider/claude.rs:316` vẫn `let _ = mode_0600;` trên unix — dead pattern, xoá khi chạm file |
| Q5 lockfile fsync | **Đã fix bằng thiết kế/comment** | `operation_lock.rs:36-44` giải thích lock file rỗng, kernel flock, không cần fsync |
| Q6 Swift `try?` swallowing | **Giảm nhẹ** | còn 71 `try?` (`AccountStore.swift`); đa số file op chấp nhận được, nhưng `try?` trên write/delete quan trọng vẫn không log |
| Q7 version compare prerelease | **Đã fix** | `GitHubUpdater.swift:416-513` `SemanticVersion` đầy đủ (prerelease, build metadata), test `UpdaterVersionTests` |
| Q8 busy-wait `Thread.sleep(0.05)` | **Đã fix** | `AccountStore.swift:1820-1845` `terminationHandler` + `DispatchSemaphore`; `runProcessCapturingOutput` còn trap R7 |

Các điểm **đã kiểm tra và không thấy lỗi** (để tránh audit lại): không có `unsafe` Rust; snapshot decode có magic + cap 4MB (`repository/codec.rs:29-45`), gzip bomb bị chặn bởi `take(MAX+1)`; import kiểm tra schema, duplicate identity, identity↔snapshot binding (`repository.rs:912-1030`); refactor recovery có generation monotonic (`index_store.rs:77-90,375-530`); mọi mutation roster đều lấy `OperationLock` (liệt kê đầy đủ ở `service.rs:1133-1170`, `providers.rs`); `restore_latest_full_backup` kiểm `write_generation` trước khi thay (`index_store.rs:78-90`); không tìm thấy credential bị log dạng raw (chỉ fingerprint SHA-256 + `exp`/`last_refresh`, `codex.rs:131-175`); updater kiểm bundle id + version + digest trước khi chạy helper (`GitHubUpdater.swift:290-305`); `total file tracked` không có build artifact.

## Đề xuất nâng cấp

### (a) Kiến trúc / refactor roadmap

| # | Việc | Effort | Impact | Risk | Thứ tự |
|---|---|---|---|---|---|
| 1 | Ports/adapters cho Clock/HTTP/Process/Command + JSON contract versioned | M | Test được toàn bộ policy, bỏ flaky; nền cho mọi bước sau | Thấp | 1 |
| 2 | Atomic write engine chuẩn (fsync + 0600) thay 5 nơi tự viết | S–M | Đóng R1/R2/R3, giảm bug crash | Thấp | 2 (sau 1) |
| 3 | Tách `repository` (snapshot/backup/metadata) và `service` (activate/roster/usage/backup) | M | Giảm god object, review đường auth dễ | TB | 3 |
| 4 | Tách `AccountStore` thành `CLIClient`/`ActivationCoordinator`/`QuotaStore`/`DesktopController`/`SessionResumeController` | L | Giảm 5k-dòng class, test Swift không cần UI | TB–Cao | 4 |
| 5 | Quyết định `external-providers`: feature thật (gate module+data) hoặc archive code/docs | S | Giảm 5,6k LOC compile/audit, hết docs drift | Thấp | song song 1 |
| 6 | Xoá nhánh Windows/Linux + sửa build.rs/README arch | S | Hết dead code/broken build | Thấp | song song 1 |

### (b) Security hardening checklist (control cụ thể)

| Control | Effort | Impact | Risk | Phụ thuộc |
|---|---|---|---|---|
| Wrap DEK bằng Keychain Data Protection (`ThisDeviceOnly`) hoặc Secure Enclave; file chỉ chứa ciphertext DEK | M | Đóng S1/S6 — key không còn plaintext | TB (migration key cũ + prompt) | X2 |
| Developer ID + hardened runtime + notarize bắt buộc ở release CI; updater fail-closed nếu installed ad-hoc | M | Đóng S2, bảo vệ update chain | TB (cần certificate/CI secret) | — |
| Cap body HTTP (2MB) + content-type; allowlist host asset updater; cap giải nén ZIP | S | Đóng S4/S5 | Thấp | X1 |
| Bỏ `npx` runtime: collector in-process hoặc vendor + SHA-256 verify; nếu giữ, dùng path tuyệt đối + lockfile | M | Đóng S3 | Thấp | — |
| Zeroize passphrase, cap stdin, confirm khi export, `--yes` cho restore CLI | S | Đóng S8/S9 | Thấp | — |
| Verify signature binary `codex`/`claude` trước exec; bỏ env override ngoài dev build | M | Đóng S10 | TB (false negative trên bản dev) | — |
| Import chạy worker + max scrypt work factor thấp hơn + progress/cancel | S | Đóng S7 | Thấp | — |
| Secret scanning (gitleaks) + `cargo deny` + SHA-pin Actions | S | Đóng C1/C2, giảm supply chain | Thấp | — |

### (c) Reliability / atomicity

| Việc | Effort | Impact | Risk | Phụ thuộc |
|---|---|---|---|---|
| Atomic helper + fsync + fsync-dir; test inject lỗi fsync/rename | M | R1, bền vững sau crash | Thấp | (a)#2 |
| Trả lỗi backup lên UI + retry/backoff + surface trong `doctor` | S | R2, user biết mất backup | Thấp | observability |
| Backup list atomic + cap `preserved-metadata-*` + 0600 | S | R3 | Thấp | (a)#2 |
| `lsof` fail-closed + log lý do; thêm cờ `--unsafe-force` explicit | S | R4 | Thấp | — |
| Tăng verification sau switch (2–3s, theo dõi mtime) + ghi rõ residual Codex write-back | S | R5 | Thấp | — |
| Chuẩn hoá error code + timeout theo operation + owner trong lock error | M | R6, A5 | Thấp | (a)#1 |
| Integration test 2 process cho lock/activate; test helper update trong sandbox | M | R1/R4/C5 | Thấp | (a)#1 |

### (d) Hiệu năng

| Việc | Effort | Impact | Risk | Phụ thuộc |
|---|---|---|---|---|
| Release profile `lto="thin"`, `strip="symbols"`; universal binary | S | P3 (size/Intel) | Thấp | — |
| Gộp cold-start call thành 1 subprocess `status`; backup sau idle; cache status | M | P1 (startup ~vài giây) | TB | X5 |
| Cache process scan/session dir; chỉ scan khi cần | S–M | P2 | Thấp | X1 |
| Backoff/adaptive poll; dedupe vibe scheduler GUI↔TUI | S | P4 | Thấp | — |
| Dò `state_*.sqlite` + validate schema, log rõ | S | P5 | Thấp | — |

### (e) CI / test strategy

| Việc | Effort | Impact | Risk | Phụ thuộc |
|---|---|---|---|---|
| SHA-pin Actions + `permissions:` tối thiểu + `--locked` mọi lệnh | S | C1/C2 | Thấp | — |
| Thêm `cargo deny` (advisories/bans/licenses/sources) + secret scan + job timeout | S | C2/C3 | Thấp | — |
| Release workflow: build universal → sign → notarize → staple → verify → publish SHA256SUMS | M | C3, S2 | TB | cert |
| Coverage cho `secrets/repository/codex/process` + E2E Swift↔CLI thật | M | C5, drift | Thấp | X5 |
| Thay `check-auth-switch-safety.sh` bằng behavioural tests; giữ script như smoke | M | C7, A4 | TB | (a)#3 |
| Inject clock + `TZ=UTC` + test policy thay vì đồng hồ thật | S | C6 | Thấp | (a)#1 |

## Quick wins (≤1 ngày)

1. `scripts/build-macos-app.sh`: thêm `[profile.release] strip/lto` hoặc `strip` binary trước khi copy; sửa README arch (D1/P3).
2. `repository.rs:1136` + `index_store.rs:72,162`: thay `let _ =` bằng warn/evaluate và trả warning trong output (R2).
3. `process.rs:121-140`: `lsof` fail → trả “unknown” và fail-closed thay vì empty set (R4).
4. `index_store.rs:187`: ghi backup list qua temp+rename+0600 (R3) — 10 dòng.
5. `usage.rs`/`reset_tracker.rs`/`openai_status.rs`/`vibe_usage.rs`: `.take(2MB)` + content-type check (S5).
6. `cli.rs`: cap `--password-stdin` 4KB, `Zeroizing`, prompt export 2 lần (S8); thêm `--yes` cho restore (S9).
7. `GitHubUpdater.prepareArchive`: cap số entry + tổng size sau `ditto`; allowlist host `browser_download_url` (S4).
8. CI: `--locked`, `timeout-minutes`, SHA-pin 4 actions (C1/C2/C4).
9. `.gitignore`: thêm `.venv/` (repo hiện không có); script dọn `build/AgentDock*`/`build/*.backup-*.app` và `dist/*.zip` cũ (D5).
10. Xoá/đánh dấu archive `docs/claude-*` + banner “removed in v0.5.0” (D3).

## Điểm đang tốt — giữ nguyên

- **Không có `unsafe` Rust**, gần như không có panic path trong production: chỉ 1 `.expect()` (`repository.rs:201`) với bất biến không thể None.
- **Atomic rename + rollback guards** cho thao tác auth (`codex.rs:573-655`), stage/restore provider (`repository.rs:46-110`), import transaction có undo (`repository.rs:1032-1120`), `FileRestoreGuard`/`KeychainRestoreGuard` — đúng hướng.
- **Recovery engineering tốt**: magic versioning, size caps, `.bak-.tmp-` recovery, generation monotonic, refuse-empty-list-over-≥2-accounts (`index_store.rs:56-63`), preserved-metadata để không mất bằng chứng.
- **Lock discipline**: `flock` xuyên process cho state/auth/auto-switch (`operation_lock.rs`), order Auth→Operation nhất quán ở các path đã đọc, lock file không cần fsync (thiết kế đúng).
- **Credit cho prior audit**: H2/H3/M1/M2(nửa)/M4/M5/L1/L2/Q3/Q7/Q8 đã fix đúng và có test hồi quy; mật độ `unwrap` production thực tế rất thấp.
- **Swift updater** giờ khá chuẩn: SHA-256 + `SecStaticCodeCheckValidity` + designated requirement + staging 0700 + rollback health marker + semantic version; test signature/prepare có fixture thật (`UpdaterPreparationTests`, `UpdaterSignatureTests`).
- **Privacy mặc định tốt**: log error dùng `privacy: .private` (`AccountStore.swift:17`), không log raw token, fingerprint một chiều; `SecretStore` trait tách bạch, test dùng `MemorySecretStore`; không direct Keychain API trong Swift.
- **Bảo vệ untrusted input cơ bản tốt**: reset feed URL allowlist, snapshot size/decode caps, backup size/account caps, provider identity binding, JWT parse thuần.
- **Tài liệu vận hành/CREDITS/AGENTS/CLAUDE đầy đủ**, version Cargo/CHANGELOG/Info.plist khớp 0.5.0; CI có fmt/clippy -D warnings/test/Swift test/safety script (dù còn thiếu gate).

## Giả định & giới hạn kiểm chứng

- **Không chạy runtime**: không thực thi `cargo build/test/clippy`, không mở app, không đọc/ghi Keychain thật, không chạm `~/.codex`, không gọi mạng. Các kết luận về crash-durability (R1) và Keychain ACL (S6) dựa trên source + hành vi nền tảng, chưa thực nghiệm crash/power-loss.
- **S2 cần xác nhận artifact thật**: `codesign -dv --verbose=4 "/Applications/Codex Roster.app"` trên bản release thực tế để biết Developer ID/notarization có được dùng ngoài CI hay không. Nếu maintainer luôn build local với `CODE_SIGN_IDENTITY`, severity giảm còn Medium; nếu release lấy từ CI (ad-hoc), giữ High.
- **S1 severity phụ thuộc cách đọc threat model**: nếu chấp nhận “same-UID = đã compromise, không cần bảo vệ snapshot khỏi cùng UID”, S1 là **Medium (accepted risk)**; nhưng boundary #1 được nêu tường minh trong yêu cầu audit, nên báo cáo giữ **High** và yêu cầu ít nhất sửa tuyên bố trong README.
- Không đọc toàn bộ 5247 dòng `AccountStore.swift`/4134 dòng `service.rs` từng dòng; đọc theo luồng credential/updater/lock/notify và grep toàn cục. Các finding ngoài luồng (UI layout, animation) không nằm trong phạm vi.
- Số LOC/line number lấy tại commit `8f27e8c`; audit trước (`docs/full-review-2026-10-06.md`) có line ref khác nên chỉ dùng để đối chiếu claim, không dùng làm bằng chứng.
- Không kết luận về CVE dependency ngoài lockfile hiện có; `cargo audit`/`cargo deny` nên chạy trong CI (C2) vì audit này không fetch advisory DB (offline).
- "Không còn lỗi" trong bảng prior-audit nghĩa là **bằng chứng source/test hiện tại** đã xử lý đúng; không chứng nhận hành vi trên account thật/Keychain thật/update thật.
