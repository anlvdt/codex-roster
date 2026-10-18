# Audit toàn diện Codex Roster v0.5.0 — 2026-10-18

**Đối tượng:** commit `8f27e8c` (`chore(release) — sync Cargo.lock package version to 0.5.0`), phiên bản **0.5.0**, 128 file tracked.
**Sản phẩm:** macOS app (menu-bar/notch + Roster Console) + Rust CLI/TUI, quản lý tài khoản OpenAI Codex, quota 5 giờ/tuần, auto-switch, session continuity, backup mã hoá, self-update.
**Cách đọc:** tài liệu này là bản hợp nhất có ưu tiên. Bốn báo cáo chuyên sâu là nguồn bằng chứng chi tiết và được tham chiếu dạng `[01/IA-1]`, `[03/Q1]`…:

| Mã | Báo cáo | Phạm vi | Findings |
|---|---|---|---|
| `01` | [01-uiux-swift.md](01-uiux-swift.md) | SwiftUI/AppKit: notch, console, journey, visual, a11y, i18n | 40 (7 High) |
| `02` | [02-cli-tui.md](02-cli-tui.md) | CLI clap, TUI, JSON contract, automation safety, latency | 35 (11 High) |
| `03` | [03-logic-algorithms.md](03-logic-algorithms.md) | Quota, auto-switch, reset, continuity, token usage, locking | 43 (6 High) |
| `04` | [04-architecture-security.md](04-architecture-security.md) | Kiến trúc, bảo mật, crash-safety, CI/release, docs | 45 (3 High + 1 High bảo trì) |

**Tổng: 163 phát hiện · 0 Critical · 27 High · ~88 Medium · ~48 Low.** Không có lỗi cho phép compromise từ xa; toàn bộ High nằm trong 4 boundary của threat model (same-UID, supply chain/release, untrusted input, concurrency/crash).

---

## 0. TL;DR — kết luận điều hành

**Sản phẩm ở mức “khá vững về cơ chế an toàn, yếu về tính đúng đắn của quyết định, phản hồi lỗi, trải nghiệm và kỷ luật kiến trúc”.**

Điểm mạnh thật sự (không phải khẩu hiệu): đường ghi credential có lock xuyên process, backup + rollback + verify, không `unsafe`, chỉ 1 `.expect()` trong production, 409 test Rust + 69 test Swift xanh, và 12+ lỗi của audit 2025 đã được sửa đúng kèm test hồi quy. Đây là nền tốt hiếm có cho một app cá nhân.

Nhưng có **5 rủi ro lớn** cần xử lý trước khi mở rộng tính năng:

1. **Quyết định quota có thể sai một cách hệ thống.** Auto-switch coi phần trăm của một cửa sổ đã hết hạn là còn hiệu lực (Q1), backoff 10 phút bỏ qua `reset_at` nên account vừa reset vẫn bị báo “hết” (Q2), và window bị API bỏ trống thì được coi là “không cản trở” — candidate có thể được chọn dù 5 giờ đã cạn, còn active không bao giờ switch khi thiếu dữ liệu (Q3, S2). Đây là gốc của phần lớn High.
2. **Lỗi bị nuốt ở đúng chỗ người dùng cần biết.** Lỗi export/import/restore/refresh phát sinh từ Console không hiển thị; switch tay không có progress/success; backup tự động fail bằng `let _ =`; `--json` không trả JSON khi lỗi, thậm chí `activate --json` thiếu ID mở menu tương tác rồi exit 0.
3. **Chuỗi phát hành chưa đáng tin.** Bản đang cài trên máy này **ad-hoc sign (`TeamIdentifier=not set`), `spctl` rejected, không notarize**; updater khi thấy bản cài ad-hoc thì không pin được identity, chỉ check validity → update trust quy về SHA-256 lấy từ cùng GitHub API. Master key mã hoá snapshot lại nằm **plaintext** trong `keys/*.key` (0600) — đúng boundary same-UID.
4. **Khám phá và phản hồi UI kém hơn chất lượng logic.** Không có `NSStatusItem` nào (notch là cửa duy nhất), không có Settings/`⌘,` chuẩn macOS, delete account active không confirm/undo, hover 280 ms cướp focus, Light Mode console fail contrast (1.75–2.9:1), chữ 8–9.5pt.
5. **Nợ kiến trúc đang hút năng lực phát triển.** `AccountStore.swift` 5.247 dòng/204 hàm, `service.rs` 4.134, `repository.rs` 3.248; policy bị cài hai lần ở Rust và Swift; ~5.6k LOC provider (Claude/Cursor/Grok) **luôn được biên dịch** dù UI/CLI đã bỏ; 156 commit `fix` so với 64 `feat` trong 310 commit (273 commit chỉ trong 90 ngày).

**Nếu chỉ làm được 10 việc trong 2 tuần tới** (chi tiết ở §4):
`window_is_current` + `usage_unknown` cho decision engine · preflight process trong `decide` · lock cho `session-resume.json` · feedback layer + chặn delete active · menu-bar item + `⌘,` · non-TTY guard + Ctrl-C/cursor + `--json` bắt buộc ID · JSON error envelope + exit code · fail-closed `lsof` + cap body HTTP + atomic backup-list/key · quyết định & siết ký/notarize · dọn 384 MB dữ liệu mồ côi của tính năng đã bỏ.

**Đề xuất chiến lược:** 2 tuần “P0 hardening” (đúng/sạch/an toàn) → 6 tuần “P1 tin cậy & trải nghiệm” (quota HUD, contract v2, TUI v2, a11y, release pipeline) → 2–3 tháng “P2 kiến trúc” (ports/clock, atomic engine, tách god object, quyết định provider, E2E/fault-injection) → quý “P3 khác biệt hoá” (dự báo burn-rate, cost-aware switching, banked-reset EV, menu-bar HUD).

---

## 1. Baseline & phương pháp

### 1.1 Quy mô và trạng thái kỹ thuật (đo tại 2026-10-18)

| Hạng mục | Số liệu | Ghi chú |
|---|---|---|
| Rust `src/` | 32.836 dòng (gồm test) | `src/app/service.rs` 4.134, `repository.rs` 3.248, `providers.rs` 2.216 |
| Swift app | 25 file UI, ~13.5k dòng; 40 file gồm test | `AccountStore.swift` 5.247, `NextAccountApp.swift` 2.432 |
| Test Rust | **409 passed, 1 ignored, 0 failed** (31,6 s) | `cargo test --all-features`; 412 `#[test]` khai báo |
| Test Swift | **69 passed** (0,36 s) | `swift test --skip-build` (bundle có sẵn) |
| Build | `cargo check --all-targets` pass; `cargo fmt --check` pass | clippy không chạy lại trong audit này; CI có `-D warnings` |
| Lịch sử | 310 commit, 273 commit trong 90 ngày, 72 tag | 156 `fix` / 64 `feat` / 38 `chore` |
| Top file bị sửa | `NextAccountApp.swift` 93, `AccountStore.swift` 89, `cli.rs` 59, `service.rs` 59 | Churn tập trung ở UI + CLI/service |
| Git blob | 128 file tracked, `.git` 78 MB | `build/`, `dist/`, `target/`, `contrib/`, `macos/.build` **không** tracked (tốt) |
| Workspace dev | `target/` 39 GB, `build/` 4,6 GB, `macos/.build` 1,1 GB | Ngoài git nhưng tốn ổ đĩa; `build/` có 20 bundle backup + app AgentDock cũ |

### 1.2 Trạng thái runtime (đọc-only trên máy audit)

| Hạng mục | Quan sát | Ý nghĩa |
|---|---|---|
| App đang chạy | `/Applications/CodexRoster.app`, v0.5.0, uptime 19h31m | Cho phép kiểm chứng artifact thật |
| Ký | `Signature=adhoc`, `TeamIdentifier=not set`, `spctl` → **rejected** | Xác nhận `[04/S2]` là High trên bản phát hành thực tế |
| Tài nguyên idle | 0,0% CPU, RSS 76.848 KB, bundle 16 MB | Nền tảng ổn; vấn đề nằm ở burst khi mở notch/switch |
| Data dir | 395 MB / 7.159 file | **384 MB** là `chatgpt-web-profiles` — tính năng đã bỏ, 0 tham chiếu trong code hiện tại |
| Key files | `automatic-backup-key-v1.key`, `local-snapshot-key-v1.key`: **64 byte plaintext**, mode 0600, xattr backup-exclude | Xác nhận `[04/S1]`; xattr là best-effort, không bảo vệ trước same-UID |
| Release | GitHub API xác nhận **v0.5.0 release + tag tồn tại** | Local tag chưa fetch (`v0.4.9` mới nhất) — không phải lỗi release |
| Test Swift | `swift test` trần **fail compile** (`no such module 'Testing'`, 13 file dùng `import Testing`, 0 XCTest) | Máy chỉ có CLT; cần Xcode hoặc `--skip-build` với bundle sẵn |

### 1.3 Phương pháp

- **4 auditor độc lập**, mỗi người sở hữu một miền, chỉ ghi đúng file của mình; Lead tổng hợp + phản biện.
- Mọi finding phải có `file:line`, trigger → tác động, mức, confidence; tách rõ **reachable bug** vs **`[inference]`**.
- Không mutate: không `save/activate/delete/import/export/login`, không Keychain thật, không `~/.codex`, không network nghiệp vụ.
- **Lead tự kiểm chứng lại 23 tuyên bố quan trọng** (xem §9.1) — gồm 2 High bảo mật, các lỗi quota, focus-steal, delete active, non-TTY guard, help rỗng, dead code, provider trong binary.
- Giới hạn: không chạy GUI/Accessibility Inspector, không profile, không crash/power-loss test, không đánh giá CVE dependency ngoài lockfile. Các mục cần runtime được ghi rõ.

### 1.4 Scorecard (thang 10, dựa trên bằng chứng — không phải điểm cảm tính)

| Chiều | Điểm | Lý do ngắn |
|---|---:|---|
| An toàn credential (swap/rollback/lock) | **8** | `restore_snapshot_with_retry` + expected-active + `flock`; thiếu fsync, `lsof` fail-open [04/R1,R4] |
| Logic quota & auto-switch | **5** | Không có khái niệm window hết hạn/không rõ; trigger chỉ reactive [03/Q1–Q3,S1,S2,S9] |
| Độ tin cậy/crash safety | **6** | Recovery tốt; thiếu fsync, backup fail bị nuốt, metadata ghi không atomic [04/R1–R3] |
| Bảo mật chuỗi phát hành | **4** | Ad-hoc + notarize thủ công, key plaintext, `npx --yes`, Actions không pin SHA [04/S1–S4,C1–C3] |
| UI/UX & IA | **5** | Không menu-bar item, không `⌘,`, delete active không confirm, thiếu feedback [01/IA-1,FLOW-1..3] |
| Accessibility | **4** | Light Mode fail contrast, chữ 8–9,5pt, hover cướp focus, thiếu label [01/VIS-1,A11Y-1..5] |
| CLI/automation contract | **5** | 22/33 lệnh không help, JSON timestamp dạng mảng, `--json` vỡ khi lỗi, non-TTY busy-loop [02] |
| Hiệu năng | **6** | Cold start ≥6 subprocess + 4 network; hover 4–6 subprocess; scan process/rollout mỗi `status` [01/PERF-1, 02/TUI-01, 04/P1–P2] |
| Kiến trúc/bảo trì | **4** | God object 2 ngôn ngữ, policy nhân đôi, 5,6k LOC provider luôn compile [04/A1,A3,A4] |
| Kiểm thử/CI | **6** | Test tốt cho policy; thiếu E2E contract, fault-injection, coverage, release gate [04/C1–C7] |
| Tài liệu/đồng bộ sản phẩm | **4** | README/About mô tả tính năng đã bỏ; PR_DESCRIPTION còn Claude; VI default lệch code [01/IA-6, 04/D1–D4] |
| **Tổng hợp** | **5,2/10** | Nền an toàn tốt, nhưng độ tin cậy quyết định + trải nghiệm + kỷ luật kiến trúc chưa theo kịp |

---

## 2. Tám vấn đề gốc (root causes)

Mỗi vấn đề gốc gộp nhiều finding ở các báo cáo khác nhau; xử lý đúng gốc sẽ đóng nhiều dòng cùng lúc.

### R1 — Decision engine thiếu khái niệm “cửa sổ đã hết hạn / cửa sổ chưa biết”

- **Bằng chứng:** [`03/Q1`] `reset_at` quá khứ không làm cache stale (`service.rs:1572-1593,1775-1795,1859-1873`); [`03/Q2`] backoff 10 phút bỏ qua `reset_at` (`service.rs:1877,1883-1890`); [`03/Q3`] window thiếu → `is_usable_for_switch` bỏ qua 5 giờ (`service.rs:1569-1593`); [`03/S2`] active không có usage ⇒ `active_has_quota` vĩnh viễn; [`02/OUT-06`]/[`01/QTA-1`] cùng dữ liệu cũ nhưng UI không nói tuổi.
- **Tác động:** switch sai/xếp hạng sai trong cửa sổ 15 phút; “all accounts exhausted” sai tới 10 phút sau reset; auto-switch “câm” đúng lúc cần; hai surface hiển thị 1% vs 0% cho cùng payload.
- **Hướng sửa:** `window_is_current(w, now) = w.reset_at > now`; thêm trạng thái `usage_unknown`; `next_probe_at` tính từ `reset_at` + backoff lũy thừa; eligibility yêu cầu 5 giờ known-usable (trừ credits); hiển thị freshness mọi nơi.

### R2 — Switch không phải một transaction

- **Bằng chứng:** [`03/C1`] `session-resume.json` read-modify-write **không lock** (`session_resume.rs:101-181`) trong khi activate giữ AuthLock/OperationLock; [`03/C3`] lock nhả giữa `decide` và `apply`; [`03/S7`] swap `~/.codex` xong nhưng metadata fail ⇒ trả Err, mất cooldown/resume; [`03/S1`] decide trả `ready` dù Codex CLI đang chạy → GUI quit/relaunch Desktop lặp mỗi ~10 s; [`04/R4`] `lsof` fail → fail-open; [`04/R5`] verify chỉ 1 s.
- **Tác động:** mất auto-resume, switch lặp gây gián đoạn Desktop, credential bị ghi dưới open handle, trạng thái nửa vời sau crash/kill.
- **Hướng sửa:** saga bền `switch-txn.json` (`decided → captured → auth_swapped → verified`), idempotent resume; một lock order; preflight trong `decide`; `lsof` fail-closed; fsync + verify dài hơn.

### R3 — Lỗi bị nuốt và không có kênh phản hồi thống nhất

- **Bằng chứng:** [`01/FLOW-2`] alert duy nhất gắn cửa sổ notch, Console không có alert; [`01/FLOW-3`] switch tay không progress/success; [`01/FLOW-4/8`] empty state hiện khi đang load, action no-op im lặng; [`02/OUT-03`] `--json` lỗi → stderr text, không JSON; [`02/OUT-04`] `activate --json` thiếu ID → mở menu, exit 0; [`04/R2`] `let _ = write_automatic_full_backup`; [`04/R3`] backup list `fs::write` trực tiếp; [`04/O1`] worker log rơi vào stderr/TUI.
- **Tác động:** người dùng tưởng thao tác thành công; script không phân loại được lỗi; mất backup mà không biết; support không có trace.
- **Hướng sửa:** envelope `{"error":{code,message,hint,details}}`, bảng exit code; `warnings[]` trong output; feedback layer dùng chung notch+console; atomic backup + surface lỗi; `doctor`.

### R4 — Bề mặt vào và khả năng khám phá thiếu

- **Bằng chứng:** [`01/IA-1`] **không có `NSStatusItem`/`MenuBarExtra` nào** (Lead grep 0) — tắt notch/lỡ đóng console là mất Settings/Quit; [`01/IA-2`] không có Settings scene/`⌘,`; [`01/IA-3`] archive/edit/delete chỉ trong context menu; [`01/IA-4`] update không badge/banner; [`01/IA-5`] 5–6 affordance refresh với 3 nghĩa; [`02/HLP-01`] TUI chỉ vào được bằng no-arg và không có trong help/README; [`02/CLI-01`] 22/33 lệnh không mô tả.
- **Tác động:** tính năng bị chôn; người dùng không biết app có gì; help CLI gần như trống.
- **Hướng sửa:** menu-bar item fallback + `⌘,`/About chuẩn HIG; action menu trên card + filter Archived; update badge; gom refresh về một control; `tui` subcommand + help đầy đủ + completion/man.

### R5 — Chất lượng trình bày, accessibility và i18n chưa được hệ thống hoá

- **Bằng chứng:** [`01/VIS-1`] console Light Mode dùng token dark-only: amber 1,75:1, emerald 1,76:1, accent 2,88:1; [`01/VIS-2`] chữ 8–9,5pt, không Dynamic Type; [`01/VIS-3`] không có spacing/radius scale, 2 type ramp; [`01/A11Y-1`] hover 280 ms gọi `activate(ignoringOtherApps:)` (Lead xác nhận 5 call site); [`01/A11Y-2`] N nút “Đổi” cùng label, toggle tự chế mất semantics; [`01/PERF-2`]/[`01/A11Y-4`] reduce-motion bỏ sót; [`02/TUI-07`]/[`02/TUI-08`] TUI hardcode `white()` trên nền sáng, đo width bằng byte; [`01/I18N-1`]/[`02/HLP-03`] CLI/TUI chỉ tiếng Anh, câu lỗi tiếng Anh bị **persist vào metadata** và phân loại bằng substring ở cả Rust lẫn Swift; [`01/I18N-2`] README nói VI mặc định nhưng code default `.system`.
- **Tác động:** người thị lực kém/nhạy cảm chuyển động/VoiceOver/keyboard-only bị chặn; người Việt nhận UI lẫn ngôn ngữ; đổi wording làm vỡ logic.
- **Hướng sửa:** token semantic light/dark + type/spacing scale; a11y checklist; reason code thay vì câu lỗi; catalog i18n dùng chung; reduce-motion helper.

### R6 — God object + policy nhân đôi + dead code

- **Bằng chứng:** [`04/A1`] 5.247/4.134/3.248/2.432 dòng; [`04/A4`] policy process/force/resume cài hai lần, được “ép” bằng script grep `check-auth-switch-safety.sh`; [`04/A5`] contract Rust↔Swift là free text; [`04/A3`] ~5.6k LOC provider luôn compile dù `external-providers` chỉ gate CLI/bin — Lead xác nhận binary release chứa chuỗi Claude/Cursor/Grok; [`04/A6`] global static; [`01/IA-7`] 7 API/component mồ côi; [`04/D2`] nhánh Windows còn trong `build.rs` dù crate `winresource` không tồn tại; commit `fix` chiếm 70%.
- **Tác động:** mỗi thay đổi credential phải sửa file 5k dòng; drift Rust↔Swift không ai bắt; compile/audit surface phình; tài liệu sai.
- **Hướng sửa:** ports/adapters (Clock/HTTP/Process/Command) + JSON contract versioned; tách `AccountStore`/`service`/`repository` theo strangler; quyết định dứt điểm provider (xoá hoặc feature thật); xoá dead code/docs cũ; module budget.

### R7 — Chuỗi cung ứng và niềm tin bản phát hành

- **Bằng chứng:** [`04/S2`] build mặc định ad-hoc, notarize chỉ khi có env, CI không set — **Lead xác nhận app đang cài ad-hoc/not rejected**; updater không pin identity khi installed ad-hoc (`GitHubUpdater.swift:373-384`); [`04/S1`] DEK plaintext (Lead xác nhận 64-byte file 0600); [`04/S3`] `npx --yes` vẫn execute registry code mỗi 30 phút; [`04/S4`] updater cap 128 MB **sau** khi tải, không cap giải nén, không allowlist host asset; [`04/S5`] body feed không cap; [`04/C1–C3`] Actions pin tag, không `--locked`/deny/coverage, không release workflow; [`04/S10`] binary từ env/PATH không verify signature.
- **Tác động:** kẻ chiếm GitHub release có thể đưa bundle ad-hoc “hợp lệ” → code exec trong `/Applications`; same-UID đọc key → giải mã toàn bộ account; OOM/DoS từ feed thứ ba.
- **Hướng sửa:** Developer ID + hardened runtime + notarize **bắt buộc** trong CI, fail nếu thiếu; updater fail-closed khi installed ad-hoc; wrap DEK bằng Keychain Data Protection/Secure Enclave hoặc sửa tuyên bố README; bỏ runtime `npx`; cap body/zip; pin Actions/`--locked`/deny.

### R8 — Hiệu năng/khởi động và tài nguyên (bao gồm dữ liệu mồ côi)

- **Bằng chứng:** [`04/P1`] cold start ≥6 subprocess CLI tuần tự + 4 network + age backup; [`01/PERF-1`] mỗi hover mở notch 4–6 subprocess + 2 network, `PassiveRefreshGate` **dead code** (Lead xác nhận chỉ có định nghĩa); [`04/P2`]/[`02/LAT-01`] mỗi `status` full process scan + query mọi thread + đọc ≥512 KB/rollout; [`02/TUI-01`] TUI sweep usage tuần tự trước frame đầu, song song worker; [`01/PERF-2`] loop notification 2 s chạy mãi; [`04/D5`] workspace 40 GB+; **Lead:** data dir 395 MB, 384 MB thuộc `chatgpt-web-profiles` (tính năng đã bỏ, 7.089 file, 0 tham chiếu), thêm 8 MB `codex-account-switcher-menubar` + `activity.jsonl`/`tray.lock`/`protected-recovery-points` mồ côi.
- **Tác động:** UX “nặng”, pin/CPU, notch mở chậm; dữ liệu nhạy cảm (browser profile ChatGPT) tồn đọng ngoài kiểm soát; ổ đĩa dev phình.
- **Hướng sửa:** gộp cold start thành 1 `status`; gate passive refresh; cache process/activity; LIMIT SQL + tail nhỏ; scheduler theo `next_probe_at`; migration dọn dữ liệu mồ côi + retention policy.

---

## 3. Top findings hợp nhất (32 mục ưu tiên)

Sắp theo mức và mức độ chặn promise sản phẩm. `ID gốc` để tra chi tiết.

| # | Mức | Vấn đề | Bằng chứng (Lead đã kiểm chứng nếu có ✓) | ID gốc |
|---|---|---|---|---|
| 1 | **High** | Master key mã hoá snapshot/backup nằm plaintext trên đĩa; same-UID hoặc backup tool đọc được → giải mã toàn bộ account | ✓ `keys/*.key` 64 B, 0600, xattr best-effort | 04/S1 |
| 2 | **High** | Bản phát hành mặc định **ad-hoc**, không notarize; updater không pin được identity khi ad-hoc → chiếm release = code exec | ✓ `codesign`: adhoc, `TeamIdentifier=not set`; `spctl` rejected | 04/S2 |
| 3 | **High** | Cache % của window đã qua `reset_at` vẫn được dùng để xếp hạng/quyết định | ✓ `service.rs:1572-1593,1859-1873` | 03/Q1 |
| 4 | **High** | Backoff 10 phút bỏ qua `reset_at`: account vừa reset vẫn “all exhausted” tới 10 phút | ✓ `service.rs:1883-1890` | 03/Q2 |
| 5 | **High** | Window thiếu/parse fail ⇒ candidate eligible dù 5 giờ có thể 0%; active `usage=None` không bao giờ switch | ✓ `service.rs:1569-1593`, `usage.rs:461-475` | 03/Q3, 03/S2 |
| 6 | **High** | `decide` trả `ready` không xét Codex CLI đang chạy → GUI quit/relaunch Desktop lặp ~10 s | `service.rs:204-318` vs `468-478`; `AccountStore.swift:2599-2665` | 03/S1 |
| 7 | **High** | `session-resume.json` RMW không lock trong khi activate giữ lock → mất `pending_continues`/`activated_at` | `session_resume.rs:101-181`; `service.rs:482-512` | 03/C1 |
| 8 | **High** | God object 5k dòng/ngôn ngữ + policy nhân đôi + grep-script ép invariant | `AccountStore 5247`, `service 4134`, `repository 3248`; `check-auth-switch-safety.sh` | 04/A1, A4 |
| 9 | **High** | Không có menu-bar item; notch là cửa duy nhất vào Settings/Quit | ✓ grep `NSStatusItem` = 0 | 01/IA-1 |
| 10 | **High** | Delete account **active** không confirm/undo (archive bị chặn, delete thì không); Rust cũng không guard | ✓ `PrismQuickSwitchDeck.swift:1295-1300`, `service.rs:1459-1466` | 01/FLOW-1 |
| 11 | **High** | Lỗi từ Console (export/import/restore/refresh) không hiển thị; switch tay không progress/success | `NotchWindow.swift:341-348`, `RosterConsoleView.swift:9-36` | 01/FLOW-2, FLOW-3 |
| 12 | **High** | Light Mode console fail contrast (amber 1,75:1; emerald 1,76:1; accent 2,88:1) vì token dark-only | `PrismTheme.swift:30-42`, `OperationsView.swift:114-122` | 01/VIS-1 |
| 13 | **High** | Hover notch 280 ms cướp focus app đang dùng (`activate(ignoringOtherApps:)`) | ✓ 5 call site trong `NotchWindow.swift` | 01/A11Y-1 |
| 14 | **High** | `codex-roster --help`: **22/33 lệnh không mô tả**, flag không help, không example | ✓ chạy `--help` | 02/CLI-01 |
| 15 | **High** | TUI non-TTY: `read_key` trả `Unknown` liên tục, loop không sleep → **busy-loop 100% CPU**, treo CI/script | ✓ không có `IsTerminal` trong `src/`; `tui.rs:510-565` | 02/SAF-01 |
| 16 | **High** | JSON `--json`: timestamp là **mảng 9 số** (time crate không bật `serde-human-readable`) → không dùng được với `jq`/script/third-party | `Cargo.toml:37`, `model.rs`; Swift `RustDate` | 02/OUT-01 |
| 17 | **High** | Không có `contract_version`; 8+ lệnh trả `serde_json::json!` inline, không DTO/golden test; optionality không nhất quán | `cli.rs:647-1141` | 02/OUT-02 |
| 18 | **High** | `--json` khi lỗi không trả JSON; `activate/delete --json` thiếu ID mở menu rồi **exit 0** | ✓ `cli.rs:706-750`; `main.rs` | 02/OUT-03, OUT-04 |
| 19 | **High** | TUI gần như vô hình: chỉ vào bằng no-arg, không có `tui` trong help/README | `cli.rs:377-378,1168-1183` | 02/HLP-01 |
| 20 | **High** | Ctrl-C bị bỏ qua trong TUI (raw mode tắt ISIG); lỗi/panic để lại cursor ẩn | `tui.rs:497,510-565,925-944` | 02/TUI-02 |
| 21 | **High** | TUI không search/filter/PgUp/PgDn; >10 account phải bấm từng dòng; label/archived không hiển thị | `tui.rs:510-578`, `304-325` | 02/TUI-03, TUI-05 |
| 22 | **Medium** | Cold start bắn ≥6 subprocess CLI tuần tự + 4 network + age backup trước khi UI có dữ liệu | `AccountStore.swift:2016-2035,2294-2299` | 04/P1 |
| 23 | **Medium** | Mỗi hover mở notch: 4–6 subprocess + 2 network; `PassiveRefreshGate` dead code (regression từ audit 10-02) | ✓ chỉ có định nghĩa trong `NotchQuotaSnapshot.swift:86` | 01/PERF-1 |
| 24 | **Medium** | `status()` full process scan + query mọi thread + đọc ≥512 KB/rollout (fallback cả file) mỗi poll | `service.rs:44-68`, `session_resume.rs:379-495` | 03/P1, 04/P2 |
| 25 | **Medium** | Credential/metadata ghi atomic visibility nhưng **không fsync**; power loss có thể để file cụt “trông hợp lệ” | `codex.rs:657-676`, `file_store.rs:99-190`, `index_store.rs:70` | 04/R1 |
| 26 | **Medium** | `lsof` fail/timeout → `HashSet::new()` → process đang mở `auth.json` bị coi là skippable (fail-open khi `--force`/auto-switch) | `process.rs:121-166` | 04/R4 |
| 27 | **Medium** | Automatic backup fail bị `let _ =` nuốt; account-list backup ghi trực tiếp (không temp+rename, 0644); `preserved-metadata-*` tăng vô hạn | `repository.rs:1132-1137`, `index_store.rs:72,162,182-190` | 04/R2, R3 |
| 28 | **Medium** | `npx --yes` vẫn chạy postinstall/transitive deps + PATH mỗi 30 phút (đã pin version) | `usage_refresh.rs:100-115`, `vibe_usage.rs:10` | 04/S3 |
| 29 | **Medium** | Feed thứ ba (`codex-resets.com`, status, VibeCafe) đọc body không cap → OOM/DoS process CLI | `usage.rs:805-966`, `reset_tracker.rs:255-270` | 04/S5 |
| 30 | **Medium** | CI: Actions pin tag (không SHA), `cargo test` không `--locked`, không `cargo deny`/coverage, không release workflow; `dist-workspace.toml` khai báo nhưng không dùng | `.github/workflows/ci.yml` | 04/C1–C3 |
| 31 | **Medium** | README hứa Intel nhưng artifact script/CI là **arm64-only**; About/README mô tả search/sort/bulk/forecast 24h-48h đã bỏ; PR_DESCRIPTION còn Claude; `docs/claude-*` stale | ✓ artifact arm64; grep UI không có search | 04/D1,D3; 01/IA-6 |
| 32 | **Medium** | Data mồ côi sau khi bỏ tính năng: **384 MB** `chatgpt-web-profiles` (7.089 file) + 8 MB app cũ + `activity.jsonl`/`tray.lock`; không migration/cleanup | ✓ data dir; grep 0 reference | Lead |

Bổ sung đáng chú ý (Medium): `reset_tracker` sort event bằng chuỗi RFC3339 thay vì thời gian (03/R1); token-usage dedupe có thể under-count và bảng giá substring (03/T2,T3); Swift test cần Xcode (Lead); i18n 439 cặp inline, 0 `NSLocalizedString` (Lead); provider code luôn compile (04/A3 + Lead); `enable-luna-reserve` một chiều (02/CLI-08); TUI selection theo index (02/TUI-04); TUI dùng màu `white()` cứng (02/TUI-07).

---

## 4. Đề xuất nâng cấp toàn diện

Bốn đợt. Mỗi mục có **Effort** (S ≤ 1 ngày, M ≤ 3 ngày, L ≤ 10 ngày người), **Impact**, **Risk**, và **tiêu chí nghiệm thu** để đưa thẳng vào backlog.

### P0 — Hardening 2 tuần (đúng · sạch · an toàn)

| ID | Việc | Why / How | Effort | Impact | Risk | Nghiệm thu |
|---|---|---|---|---|---|---|
| P0-1 | `window_is_current` + `usage_unknown` + `next_probe_at` | Gốc Q1/Q2/Q3/S2. Thêm helper; mọi predicate yêu cầu window hiện hành; `next_probe_at = min(fetched+15m, min reset+5s, now+backoff(n))`; state mới `usage_unknown` | S–M | **High** | Thấp | Test “cache 14m59s + reset đã qua ⇒ không dùng” và “vừa reset ⇒ probe lại <60 s” xanh; không test cũ nào bị đỏ (cập nhật fixture có chủ đích) |
| P0-2 | Preflight process trong `decide` | Gốc S1. Trả `waiting_for_processes` khi CLI đang chạy; GUI chỉ quit Desktop khi apply chắc chắn qua được | S | **High** | Thấp | Test mô phỏng CLI đang chạy ⇒ không `ready`; GUI không quit/relaunch lặp |
| P0-3 | Lock cho `session-resume.json` | Gốc C1. Acquire `OperationLock` (hoặc lock riêng) cho mọi RMW index | S | **High** | Thấp | Test 2 process đọc/ghi đan xen ⇒ không mất `pending_continues` |
| P0-4 | Đồng bộ hiển thị quota: 0% khi depleted + freshness ở mọi surface | Q7 + QTA-1: TUI/CLI hiện 1% trong khi Swift 0%; stale chỉ hiện ở compact ear. Đưa `display_remaining_percent()` vào model; chip “cập nhật Xm trước” + mờ bar | S | **High** | Thấp | Cùng payload cho cùng kết quả ở 4 surface; screenshot/unit test |
| P0-5 | Feedback layer + chặn delete active | FLOW-1/2/3/4/6/8. `RosterFeedback` (toast/banner/error) gắn cả notch + console; confirmationDialog + undo 8 s; disable delete khi `isActive` hoặc `isBusyForActions`; Rust `delete` từ chối active (trừ `--force-delete-active`) | S–M | **High** | Thấp | Không còn thao tác fail im lặng (ma trận 6 flow); delete active trả lỗi có hướng dẫn |
| P0-6 | Menu-bar item + `⌘,` Settings/About | IA-1/IA-2. `NSStatusItem` menu: Mở notch/Console/Cài đặt/Thoát (+ glyph quota sau); `CommandGroup` `.appSettings/.appInfo` | M | **High** | Thấp | Tắt notch vẫn vào được Settings/Quit; `⌘,` mở đúng tab |
| P0-7 | CLI/TUI an toàn khi không tương tác | SAF-01 + TUI-02 + OUT-04. `IsTerminal` guard trước TUI; arm Ctrl-C + `Drop`/panic hook restore cursor; `--json`/`--non-interactive` thiếu ID ⇒ `bail!` có hint | S | **High** | Thấp | `printf '' \| codex-roster` exit ≠0 trong <1 s, không ăn CPU; Ctrl-C thoát sạch |
| P0-8 | JSON error envelope + exit code + `contract_version` | OUT-02/03/05. `{"error":{code,message,hint,details}}`; taxonomy 0/2/3/4/5/6/7/8; top-level `contract_version:1` (additive); chuyển 8 `json!` sang DTO | M | **High** | TB (Swift phải chấp nhận field mới — decodeIfPresent đã an toàn) | Golden test mọi lệnh; `status --json \| jq` pass; error JSON parse được |
| P0-9 | Fail-closed + cap + atomic | R4 + S5 + R2/R3. `lsof` lỗi ⇒ coi mọi skippable là blocking (thêm `--unsafe-force`); `.take(2MB)` + content-type; backup list qua temp+rename+0600; trả `warnings[]` thay `let _ =` | S–M | **High** | Thấp | Test giả lập lsof fail ⇒ từ chối; feed body 100 MB bị cắt; backup fail hiện trong output |
| P0-10 | Siết ký/notarize + updater fail-closed | S2. Quyết định: bắt buộc Developer ID + hardened runtime + notarize trong CI; updater từ chối update khi installed ad-hoc (trừ dev flag); nếu chưa có cert, **sửa README** nêu rõ giới hạn | M | **High** | TB (cần cert/secret) | `codesign -dv` + `spctl -a` pass trên artifact release; test ad-hoc candidate bị từ chối |
| P0-11 | Key material: wrap DEK hoặc nói thật | S1/S6. Wrap DEK bằng Keychain Data Protection `WhenUnlockedThisDeviceOnly` (file chỉ chứa ciphertext DEK); nếu giữ tradeoff, sửa README: “mã hoá không chống same-UID” | M | **High** | TB (migration key cũ + prompt) | Không còn plaintext key; snapshot cũ vẫn mở được; README khớp |
| P0-12 | CI/release gate tối thiểu | C1/C2/P3/D1. `--locked` mọi cargo, SHA-pin Actions, `timeout-minutes`, `cargo deny`, strip/LTO; sửa README arch theo artifact thật | S | **High** | Thấp | CI đỏ nếu lockfile lệch/action không SHA; artifact nhỏ hơn; README khớp `file` |
| P0-13 | Dọn dữ liệu mồ côi + migration | 384 MB `chatgpt-web-profiles` + app cũ/activity/tray lock; thêm bước migrate một lần, log dung lượng thu hồi, tôn trọng Keychain | S | TB–Cao | TB (xóa dữ liệu người dùng ⇒ cần dry-run + confirm) | Có lệnh `cleanup --dry-run/--apply`, giảm ≥380 MB; không đụng snapshot/backup hợp lệ |
| P0-14 | `doctor` tối thiểu + KPI instrumentation | O1/O2. Checks: version/build, paths/perms, key source (không value), lock holders, leftover `.cas-backup-*`, port 1455/1457, CLI↔bundle version mismatch; log transition có account id + generation | S–M | TB–Cao | Thấp | 10 checks có `--json`; support bundle redact; log có trace switch |

**Definition of Done P0:** toàn bộ test cũ xanh; thêm ≥25 test hồi quy mới; `cargo fmt/clippy/test --locked` + Swift tests xanh trong CI; artifact release ký/notarize (hoặc README sửa đúng); 0 thao tác fail im lặng trong ma trận flow; không còn plaintext DEK; data dir <20 MB sau cleanup.

### P1 — Tin cậy & trải nghiệm 4–6 tuần

| ID | Việc | Why / How | Effort | Impact | Risk |
|---|---|---|---|---|---|
| P1-1 | Switch saga `switch-txn.json` | 03/U6: `decided→captured→auth_swapped→verified→done|rolled_back`; resume idempotent; stale >5 phút bỏ; trả `retry` thay `Err` khi bị superseded | M | **High** | TB |
| P1-2 | Quota forecast HUD (EWMA + TTE + CI) | 03/U1: `b_t=αr_t+(1-α)b_{t-1}`, `TTE=remaining/b`, CI95 `TTE·(1±1.96σ/b)`; hiển thị “cạn sau ~22p (14–35)” + confidence; tái dùng `provider/pace.rs` | M | **High** | Thấp (chỉ hiển thị trước) |
| P1-3 | Contract v2 đầy đủ + `schema` | 02/P1: DTO riêng cho CLI, RFC3339, policy optional thống nhất, JSON Schema + golden `insta`, smoke `jq` trong CI | M | **High** | TB |
| P1-4 | TUI v2 (giữ renderer, nâng cấp) | 02/P4 hướng 1: `/` filter, `?` help, Home/End/PgUp/PgDn, action r/a/u/l, label + `[archived]`, theme auto/dark/light, subscribe refresh, selection theo id | M | **High** | TB |
| P1-5 | CLI v2: help + completion + man + fuzzy switch | 02/P2/P6/P7: `///` 22 lệnh, example, `clap_complete`/`clap_mangen`, `switch <query>` resolve UUID/label/email với nhập nhằng ⇒ exit 3, `--dry-run`, `--wait`, `--format` | M–L | **High** | TB (giữ alias cho Swift) |
| P1-6 | Design system + a11y pass | 01/P3: token semantic light/dark + type/spacing/radius; Dynamic Type console; min 10.5pt; label account-specific; toggle semantics; reduce-motion helper; hit target ≥28pt | M | **High** | Thấp |
| P1-7 | Onboarding + update visibility + refresh hợp nhất | 01/P1/P2: 3 bước coach mark (hover/⌃⌥R/auto-switch/add-mode), badge update + confirm + notes, 1 control Refresh 4 mục | S–M | TB–Cao | TB |
| P1-8 | Ports/adapters + atomic write engine | 04/(a)1–2, R1: `Clock/Http/Process/Command` trait; `atomic_write` = create_new→write→sync_all→rename→fsync(dir), 0600; thay 5 nơi tự viết | M | **High** | Thấp |
| P1-9 | Release pipeline tự động | 04/C3: tag → build universal → sign → notarize → staple → verify → SHA256SUMS → publish; E2E contract Swift↔binary | M | **High** | TB |
| P1-10 | Bỏ runtime `npx` | 04/S3: collector in-process (chỉ HTTPS GET) hoặc vendor + SHA-256; nếu giữ: `npm ci` + path tuyệt đối + lockfile | M | TB–Cao | Thấp |

### P2 — Kiến trúc & bền vững 2–3 tháng

| ID | Việc | Why / How | Effort | Impact | Risk |
|---|---|---|---|---|---|
| P2-1 | Strangler tách `service.rs`/`repository.rs` | 04/(a)3–4: `activation/roster_ops/usage_ops/backup_ops`; `snapshot_store + backup_tx + metadata_store`; module budget ≤1.200 LOC | M–L | **High** | TB |
| P2-2 | Tách `AccountStore` | `CLIClient / ActivationCoordinator / QuotaStore / DesktopController / SessionResumeController / RosterStore`; test Swift không cần UI | L | **High** | TB–Cao |
| P2-3 | Quyết định provider subsystem | 04/A3 + 01/IA-7: (a) xoá code+docs+data và cleanup, hoặc (b) feature thật gating module+data; cấm trạng thái nửa vời | S | **High** | Thấp |
| P2-4 | Quality system | 03/U7/U8, 04/C5: `decide()` pure + replay JSONL + proptest invariants + cargo-fuzz; simulation harness tune threshold; fault-injection (fsync/rename/kill) + 2-process lock test; coverage gate cho `secrets/repository/codex/process` | M–L | **High** | Thấp |
| P2-5 | i18n & error-code architecture | 02/HLP-03, 04/A5: catalog dùng chung; persist reason code thay câu tiếng Anh; CLI/TUI theo `LANG`/`--lang`; contract test mapping Rust↔Swift | M | TB–Cao | TB |
| P2-6 | Universal build/Intel + xoá dead code | 04/D1/D2: universal binary hoặc bỏ tuyên bố Intel; xoá nhánh Windows/`build.rs`/WSL | S–M | TB | Thấp |
| P2-7 | Observability & privacy | 04/O1–O3: `tracing`/`os_log` thống nhất, rotate, redact email mặc định, diagnostics bundle, retention policy cho data nhạy cảm | M | TB–Cao | Thấp |
| P2-8 | Performance budgets | Gộp cold start 1 subprocess; cache process scan/activity; `status --fast`; adaptive poll; dedupe vibe scheduler; sparkline downsample; budget trong CI | S–M | **High** | TB |

### P3 — Khác biệt hoá trong quý

| ID | Việc | Why / How | Effort | Impact | Risk |
|---|---|---|---|---|---|
| P3-1 | Predictive + cost-aware switching | 03/U2/U3: threshold/hysteresis/dwell (`T=5%, H=15, D=10'`, `W_floor=20%`, idle gate), `P_fail=1-exp(-TTE/τ)`, switch khi `TTE<2.3τ`; mặc định off, có explainer | M–L | **High** | TB |
| P3-2 | Banked-reset EV + ranking v2 | 03/U4/U5: score `1000·weekly+5h+plan_bonus+reset_bonus−freshness+banked`, tie-break cố định, trả `switch:{eligible,score,breakdown,reason}`; rank credit theo `expires_at` | M | **High** | Thấp |
| P3-3 | Menu-bar mini-HUD + continuity timeline | 01/P0-3 mở rộng: glyph 2 vạch 5H/tuần, spinner + account đích khi switch, timeline switch/resume trong Operations | M | **High** | Thấp |
| P3-4 | Smart switch suggestions | Gợi ý chuyển trước ngưỡng (one-tap, preview, undo) — không tự chuyển; dùng score v2 | S–M | TB–Cao | TB |
| P3-5 | Beta/canary channel + telemetry opt-in | Release channel + rollback health (đã có nền), crash report opt-in, KPI thực tế thay vì suy luận | M | TB–Cao | TB |

---

## 5. Thiết kế chi tiết cho 6 đề xuất lớn

### 5.1 Quota Decision Engine v2 (đóng Q1/Q2/Q3/S2/S9 + QTA-1)

```text
Inputs: active usage (cached + fetched_at), candidate usages, settings, now, process/activity state
Step 0  normalize: với mỗi window w:
          known   = w.is_some()
          current = known && w.reset_at > now
          depleted = current && w.remaining <= 1
        usage.completeness = {five_known, weekly_known}
Step 1  active_state:
          unknown_usage (không cache & probe fail, hoặc completeness = 0)
          | exhausted   (mọi window current && depleted, weekly-dominant)
          | usable      (mọi window known ưu tiên; thiếu window ⇒ coi là unknown, KHÔNG eligible)
Step 2  candidates = filter(account => usable && !free && !blocked && !recent_error)
        score = 1000*weekly_remaining + five_remaining
                + plan_bonus(Pro 15/Plus 5)
                + reset_bonus(weekly.reset_at - now <= 24h ? 10 : 0)
                - freshness_penalty(age > 10m ? 20 : 0)
                + banked_bonus(credit chưa hết hạn ? 5 : 0)
        tie-break: (score desc, plan_rank, last_activated_at asc, id asc)
Step 3  decide(now) pure -> Decision { active_has_quota | usage_unknown | ready(candidate)
                                       | waiting_for_processes | banked_reset_available
                                       | all_accounts_exhausted }
Step 4  next_probe_at(account) = min(fetched+15m, min(current.reset_at)+5s, now+60s*2^(n-1) cap 15m)
        worker sleep = clamp(min(next_probe_at)-now, 15s, 120s)
```

**Acceptance:** property tests: `usable ⇒ ∀ window known && !depleted && reset_at > now`; `reset_at ≤ now ⇒ không dùng percent cũ`; `unknown ≠ usable`; golden replay 30 kịch bản biên (missing window, reset đúng giây, clock skew ±10 phút, DST).

### 5.2 Switch saga (đóng C1/C3/S7 + R4/R5)

```json
// <app_data>/switch-txn.json
{"txn_id":"…","from":"<uuid>","to":"<uuid>","phase":"decided|captured|auth_swapped|verified|done|rolled_back",
 "started_at":"…","attempt":1,"preflight":["codex-cli"]}
```

- `activate` giữ `AuthLock` + `OperationLock` trong **toàn bộ** critical section; `capture_pending_continue` dùng cùng lock; `mark_activated` idempotent theo `txn_id`.
- Mỗi poll: txn chưa `done` & age <5 phút ⇒ resume theo phase; `auth_swapped` mà live identity ≠ `to` ⇒ rollback từ snapshot `from` + phase `rolled_back`; >5 phút ⇒ đánh dấu stale, không switch lại cùng cặp.
- Preflight trong `decide` trả `waiting_for_processes`; GUI chỉ `quit` Desktop sau khi `apply` sẵn sàng (không còn quit/relaunch lặp).
- `lsof` lỗi ⇒ fail-closed; verify stability 2–3 s + theo dõi mtime; metadata write fail ⇒ trả `switched` kèm `warnings` (không `Err`).

### 5.3 Contract v2 + `doctor` (đóng OUT-01..07, HLP-02, O1/O2)

```json
{
  "contract_version": 1,
  "status": "ok",
  "data": { "...": "typed DTO, timestamps RFC3339 có offset" },
  "warnings": [{"code":"stale_refresh_token","message":"…"}]
}
// lỗi:
{"contract_version":1,"error":{"code":"login_required","message":"…","hint":"…","details":{}}}
```

- Exit code: `0 ok · 2 usage · 3 login required · 4 lock timeout · 5 no account · 6 network/quota · 7 keychain/decrypt · 8 unsupported`.
- `codex-roster schema [command]` + `doctor [--json] [--bundle]`: version/build, paths/perms, key source, lock holders, `.cas-backup-*` leftovers, port 1455/1457, CLI↔bundle mismatch, last errors (redacted).
- Giữ format on-disk (mảng `time`) — chỉ đổi surface JSON; Swift `RustDate` đã đọc được string nên additive-safe.

### 5.4 UX blueprint (đóng IA-1..7, FLOW-1..9, VIS-1..4, A11Y-1..5, QTA-1..5)

1. **Menu-bar item** (giải IA-1): glyph 2 vạch quota; menu Mở notch / Console / Cài đặt / Kiểm tra cập nhật / Thoát. Khi switch: spinner + tên account đích.
2. **Feedback layer**: toast (2–3 s) + banner + error surface dùng chung; route lỗi console về đúng cửa sổ; `switch` có progress pill “Đang chuyển… x/y” và không auto-collapse khi `isSwitching`.
3. **Destructive safety**: delete/archive có confirm nêu email + “không thể hoàn tác”, Undo 8 s, chặn active; import có diff số account; restore có nút “Xuất bản hiện tại trước”.
4. **Freshness & trust**: chip “cập nhật 12p trước” ở wing/popover/card; mờ thanh quota khi stale; reset outlook ghi nguồn + tuổi; tách hệ màu quota và reset.
5. **Design tokens**: semantic `statusSuccess/Warning/Danger` cho light/dark; spacing 2/4/8/12/16/24; radius 6/10/14/20; một type ramp; min 10.5pt cho text mang nghĩa.
6. **A11y**: label “Đổi sang {name}”, toggle `.isToggle`, reduce-motion helper, hit target ≥28pt, keyboard path cho action (menu Tác vụ/⌘K).
7. **Onboarding**: 3 coach mark lần đầu (hover 280 ms, ⌃⌥R, auto-switch + add-mode) + “Đừng hiện lại”; empty state chỉ khi `!isLoading`.

### 5.5 Release & security pipeline (đóng S1–S5, C1–C3)

```text
on tag v*:
  cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings
  cargo test --locked && swift test (Xcode)
  cargo deny check advisories bans licenses sources
  build universal (aarch64 + x86_64, lipo) + strip + LTO
  codesign --options runtime --timestamp (Developer ID)  [fail nếu thiếu]
  notarytool submit --wait && stapler staple && spctl -a -vvv  [fail nếu thiếu]
  gitleaks + syft (SBOM) + sha256sum > SHA256SUMS
  publish release + verify updater digest từ asset vừa upload
```

- Updater: allowlist host `github.com`/`objects.githubusercontent.com`; cap `expectedContentLength` khi tải; cap entry/tổng uncompressed trước `ditto`; **từ chối** candidate ad-hoc nếu installed có Developer ID; từ chối downgrade.
- Key: Keychain Data Protection `WhenUnlockedThisDeviceOnly` wrap DEK; file chỉ chứa ciphertext; migration đọc key cũ một lần, xoá plaintext sau xác nhận.
- Bỏ `npx`: gọi HTTPS endpoint của VibeCafe trực tiếp hoặc vendor binary + SHA-256.

### 5.6 Kiến trúc đích + strangler

```text
src/
  domain/     // pure: model, quota policy, switch policy, scoring, error enum
  ports/      // Clock, HttpClient, ProcessProbe, CommandRunner, SecretStore, SnapshotRepo
  platform/   // ureq, sysinfo/lsof, Command, keyring, macOS paths
  storage/    // atomic engine (fsync!), snapshot/metadata/backup/index, recovery
  usecase/    // activate, save, import_backup, auto_switch, usage_refresh
  app/        // CLI/TUI bridge, versioned JSON DTO, workers
macos/NextAccount/Sources/
  CLIClient / ActivationCoordinator / QuotaStore / DesktopController /
  SessionResumeController / RosterStore (ObservableObject mỏng) + Views
```

Thứ tự: ports+contract → atomic engine → tách repository → tách service → tách AccountStore → xoá provider/dead code. Mỗi bước có test hồi quy; không đổi behavior ngoài phạm vi.

---

## 6. Lộ trình, KPI và Definition of Done

### 6.1 Lộ trình

| Đợt | Thời gian | Nội dung | Exit criteria |
|---|---|---|---|
| **P0** | 2 tuần | 14 mục hardening | 0 Critical/High mới; Q1/Q2/Q3/S2 xanh; non-TTY không treo; release ký/notarize hoặc docs đúng; key không plaintext (hoặc README sửa); delete active an toàn; menu-bar item có; data dir <20 MB |
| **P1** | 4–6 tuần | 10 mục tin cậy/UX | Contract v2 + golden test; TUI v2 có search/Ctrl-C; quota HUD; a11y AA light mode; release pipeline tự động; saga switch |
| **P2** | 2–3 tháng | 8 mục kiến trúc/quality | Module budget đạt; E2E contract + fault injection + property test trong CI; provider quyết định xong; Intel/universal hoặc docs đúng; observability |
| **P3** | quý | 5 mục khác biệt | Predictive/cost-aware switch có backtest; ranking v2 một nguồn; HUD + timeline |

### 6.2 KPI (baseline → mục tiêu)

| KPI | Baseline hiện tại | Mục tiêu |
|---|---|---|
| Quyết định trên window đã hết hạn/không rõ | Có (Q1/Q2/Q3) | **0** |
| “All exhausted” sai sau reset | Tới 10 phút | **<60 s** |
| Thao tác fail không có feedback | 6 flow | **0** |
| Cold start: subprocess CLI | ≥6 | **1** |
| Cold start: thời gian tới notch có dữ liệu | “vài giây” (chưa đo) | **p95 <800 ms** (đo bằng signpost) |
| JSON contract | 0 version, 8 lệnh `json!`, timestamp mảng | **100% DTO + `contract_version` + RFC3339** |
| Help coverage | 11/33 lệnh có mô tả | **33/33** |
| Đường credential có fsync | 0 | **100%** |
| Release ký + notarize + staple | Không (ad-hoc) | **Có, CI fail nếu thiếu** |
| WCAG AA Light Mode | Fail (1,75–2,9:1) | **Pass ≥4,5:1** |
| Test tin cậy | 409 Rust + 69 Swift (không E2E contract/fault) | **+contract, +fault-injection, +property; coverage gate** |
| Dữ liệu mồ côi | 384 MB + 8 MB | **0** |
| Swift test chạy được trên máy dev CLT | Không | Documented (Xcode) hoặc `--skip-build` script |

### 6.3 Quyết định cần chủ sản phẩm chốt (chặn scoping)

| # | Câu hỏi | Đề xuất |
|---|---|---|
| D1 | Threat model same-UID: chấp nhận hay chống? | Chống bằng wrap DEK; nếu chấp nhận, **sửa README** và hạ severity |
| D2 | Đầu tư Developer ID + notarize ngay? | **Có** — đây là control duy nhất bảo vệ update chain |
| D3 | Provider subsystem (Claude/Cursor/Grok): xoá hay revive? | **Xoá** code+docs+data (product hiện Codex-only); revive thì tách feature thật |
| D4 | Ngôn ngữ mặc định: Tiếng Việt hay Theo hệ thống? | Theo hệ thống + README đúng, hoặc VI mặc định + code đổi (hiện docs/code lệch) |
| D5 | Hỗ trợ Intel? | Universal build hoặc bỏ tuyên bố README |
| D6 | `--json` cũ cho Swift: freeze hay version? | Additive v2 + `contract_version`, giữ key cũ ≥2 release |

---

## 7. Những gì đang tốt — giữ nguyên

1. **An toàn credential là trọng tâm đúng:** `activate_if_active_matches` + expected-active recheck, `restore_snapshot_with_retry` backup/rollback/verify, `AuthLock`/`OperationLock`/`AutoSwitchLock`, lock order nhất quán ở các path đã đọc.
2. **Không `unsafe`, gần như không panic:** production còn 1 `.expect()` (có ngữ cảnh), `unwrap` density thấp; test dùng `Result`.
3. **Nguyên tắc sản phẩm đúng:** không tự redeem banked reset, không switch vào account 0%, không downgrade Free/Go, không auto-switch khi mọi account cạn — các quyết định này bảo vệ tài nguyên không thể hoàn tác.
4. **Recovery engineering tốt:** magic versioning, size caps, `.bak/.tmp` recovery, generation monotonic, từ chối empty-list-over-≥2-account, preserved-metadata.
5. **Tolerant parsing quota:** một block hỏng không xoá phần còn lại; phân biệt `credits.balance=""` (không đọc được) với 0.
6. **Token/cost cache tăng dần** (cursor + length + mtime + prefix hash + rebuild khi truncate) và `format_local_reset_at` xử lý DST đúng (offset tại instant reset).
7. **Reset tracker thận trọng:** partial-feed không ghi đè state, URL allowlist, bound số notification, **chủ động không bịa xác suất**.
8. **Test đặt tên theo invariant** và bao phủ các quyết định khó (`auto_switch_requires_every_reported_window_to_be_usable`, `floored_ninety_nine_percent_window_counts_as_exhausted`…).
9. **Notch geometry cẩn thận:** pixel-align, overscan, chỉ hit-test capsule khi collapsed, hover intent chống drive-by — trải nghiệm “hug” tốt.
10. **Phiên bản trước đã sửa đúng 12+ lỗi audit 2025** (symlink-safe rename, updater digest+signature+health rollback, allowlist `security -i`, CLI locator ưu tiên bundled, URL allowlist, log 0600+rotate, semantic version compare…). Đây là nền để tin các fix mới sẽ được giữ.
11. **Swift updater có nhiều lớp đúng hướng:** SHA-256, `SecStaticCodeCheckValidity`, staging 0700, rollback health marker 5 phút, semantic version.
12. **Privacy mặc định tốt:** `os_log` dùng `privacy: .private`, không log raw token (chỉ fingerprint), `SecretStore` trait + `MemorySecretStore` cho test.

---

## 8. Rủi ro nếu không xử lý (risk register)

| Rủi ro | Khả năng | Tác động | Ứng phó |
|---|---|---|---|
| Update giả (chiếm GitHub release, bundle ad-hoc) | Thấp–TB | **Rất cao** (code exec, persistence) | P0-10 sign/notarize + fail-closed |
| Same-UID đọc key → mất toàn bộ account | TB | **Cao** | P0-11 wrap DEK / sửa docs |
| Switch sai do quota stale, mất turn/phiên | **Cao** | Cao | P0-1/P0-2 |
| Mất auto-resume/activated_at do race | TB | TB–Cao | P0-3 |
| Mất backup âm thầm khi disk đầy | TB | **Cao** | P0-9 |
| Người dùng không tìm thấy tính năng/không thấy lỗi | **Cao** | TB | P0-5/P0-6, P1-4 |
| Drift Rust↔Swift làm hỏng phân loại lỗi | TB | TB | P1-3, P2-5 |
| Nợ kiến trúc làm mỗi fix sinh regression mới | **Cao** | TB–Cao | P2-1/P2-2 + quality system |
| Dữ liệu nhạy cảm mồ côi (browser profile ChatGPT) | Đã xảy ra | TB (privacy) | P0-13 + retention policy |

---

## 9. Phụ lục

### 9.1 Verification log (Lead tự chạy lại)

| # | Kiểm chứng | Kết quả |
|---|---|---|
| 1 | `cargo fmt --check` | Pass (exit 0) |
| 2 | `cargo check --all-targets` | Pass |
| 3 | `cargo test --all-features` | **409 passed, 1 ignored, 0 failed** (31,62 s) |
| 4 | `swift test` (trần) | **Fail compile**: `no such module 'Testing'`; 13 file `import Testing`, 0 XCTest |
| 5 | `swift test --skip-build` | **69 passed** (0,36 s) |
| 6 | `codesign -dv --verbose=4 /Applications/CodexRoster.app` | `Signature=adhoc`, `TeamIdentifier=not set` |
| 7 | `spctl -a -vvv /Applications/CodexRoster.app` | `rejected` |
| 8 | `ls -la …/keys` | 2 file plaintext 64 B, mode `-rw-------` |
| 9 | `xattr -l …/keys/*.key` | `com.apple.metadata:com_apple_backup_excludeItem` (best-effort) |
| 10 | `du -sh` data dir + subdirs | 395 MB; `chatgpt-web-profiles` **384 MB**, 7.089 file |
| 11 | `grep -rn "chatgpt-web-profiles" src macos/.../Sources` | **0 tham chiếu** |
| 12 | `grep -rn "NSStatusItem\|MenuBarExtra\|statusItem" macos/.../Sources` | **0** |
| 13 | `grep -rn "IsTerminal\|is_terminal" src` | **0** (xác nhận đường non-TTY không có guard) |
| 14 | `grep -rn "ignoringOtherApps"` | 5 call site, gồm hover-open |
| 15 | `grep -rn "PassiveRefreshGate"` | Chỉ có định nghĩa → dead code |
| 16 | Đọc `service.rs:1540-1600,1855-1905`; `usage.rs:455-500`; `model.rs:676` | Xác nhận Q1/Q2/Q3/S2 |
| 17 | Đọc `cli.rs:690-750`; `service.rs:1450-1470,982-1002` | `refresh-usage` JSON hằng; `activate --json` không ID → interactive; delete không guard active; `load_activation_target` không check archived |
| 18 | `cargo run -- --help` | 33 lệnh; 22 lệnh không mô tả; 2 lệnh deprecated vẫn hiện |
| 19 | `strings build/…/codex-roster \| grep -i claude` | 21 dòng khớp; xác nhận provider stack trong binary default |
| 20 | GitHub API `releases?per_page=5` | v0.5.0 release tồn tại (local tag stale không phải lỗi) |
| 21 | `ps` app đang chạy | 0,0% CPU, RSS 76.848 KB, uptime 19h31m |
| 22 | Đếm i18n Swift | 439 `language.text(...)`, 0 `NSLocalizedString` |
| 23 | `git ls-files` + `du` | 128 tracked; `build`/`dist`/`target`/`contrib`/`macos/.build` không tracked; workspace >40 GB |

### 9.2 Chỉ số lịch sử (tín hiệu chiến lược)

- 310 commit / 72 tag; **273 commit trong 90 ngày** — tốc độ rất cao, nhưng:
- **156 `fix` vs 64 `feat`** — 70% công sức vào sửa lỗi; top file bị sửa là `NextAccountApp.swift` (93) và `AccountStore.swift` (89) — đúng hai god object.
- 4 hệ tích hợp đã thêm rồi gỡ: CCS/CLIProxy + cmux, Codex Router, Windows/Linux, Claude/AgentDock. Mỗi lần gỡ để lại code/data/docs mồ côi (xem #11, #19, data 384 MB).
- Đề xuất kỷ luật: **ADR** cho quyết định lớn; **feature-flag lifecycle** (owner + ngày hết hạn + cleanup bắt buộc); **release channel** (stable/beta); **deprecation policy** cho lệnh/settings (không để deprecated vô hạn trong help).

### 9.3 Giới hạn kiểm chứng (áp dụng cho toàn bộ tài liệu)

1. Không chạy GUI/Accessibility Inspector; các kết luận layout, sheet collapse, VO, Light Mode đo bằng công thức WCAG từ hex cần xác minh runtime.
2. Không crash/power-loss test; fsync/atomicity là phân tích source + hành vi nền tảng.
3. Không profile; latency là suy luận từ call-path + timeout/lock (5 s HTTP, 90 s lock, 120 s Swift).
4. Không kiểm tra CVE dependency ngoài lockfile; nên chạy `cargo audit`/`cargo deny` trong CI.
5. Không đánh giá behavior trên account thật/Keychain thật/update thật; các mức severity bảo mật phụ thuộc threat model đã nêu (same-UID được xem là in-scope).
6. Line number ứng với commit `8f27e8c`; có thể lệch sau khi sửa.

### 9.4 Bước tiếp theo đề xuất

1. Chốt 6 quyết định ở §6.3 (D1–D6) — đặc biệt D2 (ký/notarize) và D3 (provider).
2. Tạo backlog P0 với 14 mục, gắn owner + test nghiệm thu; mỗi mục là PR nhỏ, có test hồi quy.
3. Bắt đầu bằng 4 mục rẻ nhất, tác động lớn nhất: **P0-1 (quota validity)**, **P0-5 (feedback + delete safe)**, **P0-7 (non-TTY/Ctrl-C)**, **P0-9 (fail-closed + atomic)**.
4. Song song: dựng pipeline release ký/notarize (P0-10) vì nó chặn mọi phát hành an toàn sau này.
5. Đo baseline KPI bằng `doctor`/signpost trước khi tối ưu, tránh tối ưu theo cảm giác.

---

*Tài liệu này tổng hợp 163 phát hiện từ 4 báo cáo chuyên sâu, đã được Lead kiểm chứng lại 23 tuyên bố quan trọng. Không có source file nào bị sửa trong quá trình audit; chỉ tạo mới thư mục `docs/audit-2026-10-18/`.*
