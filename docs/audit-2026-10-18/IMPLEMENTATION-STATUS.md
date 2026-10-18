# Trạng thái triển khai audit — Codex Roster (2026-10-18)

Cập nhật: sau vòng làm việc trực tiếp của Lead (mọi provider Orca đều cạn quota — xem §3).
Nhánh: `main`. Chưa push `origin`. Chưa xoá dữ liệu người dùng.

## 1. Đã hoàn thành và đã kiểm chứng

| Hạng mục | Nội dung | Commit | Bằng chứng |
|---|---|---|---|
| **Lỗi bạn báo (hộp thoại thô)** | Guard phân loại chính xác (`BlockKind`: CLI interactive / background / Desktop / unrelated), **fail-closed** khi `lsof` lỗi, báo cáo process có pid/exe/role, prefix máy đọc được `activation_blocked_by_cli:`; `decide` trả `waiting_for_processes` thay vì `ready` khi có CLI đang chạy | `768352e` | 33 test `process`; test `select_blocking` cho Known/Unknown; `cargo test` 417 xanh |
| **Thông báo lỗi phía macOS** | `friendlyErrorMessage` dịch lỗi guard sang tiếng Việt/Anh có hành động + danh sách process; nút "Sao chép chi tiết"; alert cũng gắn ở cửa sổ Console (trước chỉ ở notch) | `00c4eaa` | `swift build` pass |
| **Auto-resume (audit + fix)** | Khoá xuyên process cho `session-resume.json`; `enabled=false` không tiêu thụ queue; discovery lọc recency + `LIMIT 50` + tail 128 KB + cap 1 MB + cache `(path,size,mtime)` + counter; thang ngày local+UTC; `ready` cần rollout thật; báo cáo [AUTO-RESUME-AUDIT.md](AUTO-RESUME-AUDIT.md) | `a06fcf7` + doc | 18 test `session_resume`, gồm test đọc có giới hạn + cache hit |
| **Quota decision (Q1/Q2/Q3/S2)** | Cửa sổ hết hạn = *unknown*, không dùng % cũ; backoff không che reset tự nhiên; thiếu 5h ⇒ không eligible (trừ credits); `usage_unknown` khi active không có 5h hiện hành; `cached_usage_is_fresh` yêu cầu mọi cửa sổ hiện hành | `8775c93` | test `expired_window_is_unknown...`, `missing_five_hour_window...`, `exhausted_probe_backoff_never_hides_a_natural_reset` |
| **Banked reset + bookkeeping (Q6/S7)** | Credit hết hạn không còn được tính; switch thành công vẫn trả `switched` + `warnings` nếu bookkeeping/resume hint lỗi (không còn `Err` sau khi đã swap) | `c08684e` | test `expired_banked_credits_are_not_counted_as_redeemable` |
| **CLI/TUI an toàn (một phần A3)** | Non-TTY không còn busy-loop 100% CPU; Ctrl-C thoát; cursor được khôi phục qua `Drop` guard; `--json` thiếu ID báo lỗi thay vì mở menu; message Desktop rõ hành động | `c95c0cd` | `printf '' \| codex-roster` → exit 1 kèm hint trong <1s (đã chạy thật); `activate --json` không ID → bail; test `ctrl_c_escape_and_q_all_quit_the_menu` |
| **Storage bền vững (A2)** | `atomic_write` (temp `create_new` + mode + `sync_all` + rename + fsync dir) và `write_private_durable`; metadata + account-list backup ghi 0600 atomic; pending 0600; quota-history có lock riêng, temp unique, **không ghi khi đọc**; reset-tracker ghi atomic + sort theo thời điểm đã parse (không theo chuỗi RFC3339); credential `auth.json`/`cap_sid` `sync_all` trước rename; body feed công khai cap 2 MiB | `46c978e` | 4 test `file_store` (mode/không rác temp), 2 test `quota_history`, test `announcements_sort_by_instant_not_string` |
| **Build/CI (C)** | `[profile.release]` LTO + `strip` + `codegen-units=1`; CI `permissions: contents: read`, `timeout-minutes`, `--locked`, 4 Actions **pin SHA**; `release.yml` mới (universal build, fail-closed nếu tag thiếu secret ký/notarize, SHA256SUMS, upload asset); build script hỗ trợ `UNIVERSAL=1` + `lipo -info`; `clean-local-artifacts.sh`; bỏ nhánh Windows chết trong `build.rs` | `57d72f6` | CLI **8,59 MB → 6,90 MB**, bundle **16 M → 14 M**; `bash scripts/build-macos-app.sh` chạy thật thành công; YAML parse ok |
| **CLI discoverability (A3)** | Mô tả cho **toàn bộ 33 lệnh** (trước 22 lệnh trống), help cho `--json/--force/--restore/--password-stdin`, `after_help` có ví dụ, ẩn 2 lệnh deprecated khỏi help | `77a3c6f` | `--help` kiểm tra tự động: **0 lệnh thiếu mô tả**; 2 lệnh deprecated không còn hiện |
| **macOS UX (B, phần 1)** | **Menu-bar item** `CR` với menu Mở notch / Console / Cài đặt / Giới thiệu / Thoát (trước đây notch là cửa duy nhất); `⌘,` mở Settings + About trong app menu; xoá tài khoản có **hộp thoại xác nhận** nêu email + chặn xoá tài khoản đang dùng (cả UI lẫn store) | `cb97241` | `swift build` pass |
| **macOS UX (B, phần 2)** | Hover mở notch **không còn cướp focus** (bỏ `activate(ignoringOtherApps:)` ở đường hover; click/hotkey vẫn activate); `PassiveRefreshGate` (trước là dead code) nay gom refresh công khai khi mở notch/Operations vào cooldown 60s | `7e2c40e` | `swift build` pass |

| **Contract v2 + doctor (E1)** | Mọi output `--json` mang `"contract_version": 1` (chèn một chỗ trong `print_json`, phủ cả 46 đường xuất); timestamp ở view đổi sang **RFC3339** (struct lưu trữ giữ nguyên mảng cũ để không phá dữ liệu trên đĩa); lỗi in envelope `{"contract_version":1,"error":{code,message,hint}}` + **exit code theo lớp** (2 usage, 3 login/blocked, 4 lock timeout, 5 no account, 6 network, 7 keychain); thêm **`doctor`** (13 check: version, app_data, key file + mode, 3 lock, auth.json, thư mục `.cas-*` sót, port 1455/1457, số account, tuổi cache usage, phiên add-account) và **`schema`** | `866e78d` | `list --json` cho `contract_version: 1` + `created_at` dạng `2026-10-18T01:02:05Z`; lệnh lỗi in envelope + exit khác 0; `doctor` chạy thật ra 13 check; test `classify_error_maps_known_failures_to_exit_codes`, `schema_document_describes_the_contract` |
| **Tài liệu (D)** | README truth-up (33 lệnh + `doctor`/`schema`, contract + exit code, kiến trúc arm64/`UNIVERSAL=1`, ngôn ngữ mặc định theo máy, validation mới, bỏ claim 24h/48h); CHANGELOG có mục **Unreleased** đầy đủ + chuyển "Known issues" khỏi v0.4.8; 5 tài liệu cũ chuyển vào `docs/archive/` kèm banner + `docs/archive/README.md`; `AGENTS.md`/`CLAUDE.md` đổi GitNexus `MUST` thành có điều kiện; `PR_DESCRIPTION.md` viết lại theo thực tế | `7fbe8fe` | Kiểm tra link markdown: **0 link hỏng** |

| **Thuật toán (E2 phần 1)** | **`src/forecast.rs`**: burn-rate EWMA (α=0.3, variance α=0.2), bỏ reset/Δmẫu quá gần, `TTE = remaining/b`, CI95 = `TTE·(1±1.96·cv)`, confidence high/medium/low theo số mẫu + cv + tuổi mẫu; lệnh **`quota-forecast [ACCOUNT_ID] [--json]`**; **scoring v2** `score = 1000·weekly + five + plan_bonus + reset_bonus − freshness_penalty + banked_bonus` kèm breakdown giải thích trong `auto-switch --json`; tie-break tất định `(score, plan_rank, last_activated_at, id)`; **proactive threshold + hysteresis + dwell + weekly floor** (mặc định tắt) và dwell cho cả đường reactive (`waiting_for_dwell`) | `8ee91c9`, `fbf625f`, `62f7003` | 8 test `forecast` (burn đều/giật/reset/1 mẫu/0 burn/ngoài cửa sổ/hồi quy); 5 test scoring (monotonic, breakdown, ineligible, tie-break, golden 5 account); 4 test proactive/dwell; **440 test pass** |
| **Tuning (E2 phần 2)** | Harness mô phỏng có seed (`cargo test simulate_reactive -- --ignored --nocapture`) so sánh Reactive vs Threshold; tài liệu [ALGORITHM-TUNING.md](ALGORITHM-TUNING.md) ghi công thức, bảng mô phỏng và **giới hạn bằng chứng** | `405456b` | Reactive: 2,0 turn lỗi + 66s gián đoạn/ngày; threshold 5–15%: 0 turn lỗi + 16s, cùng số switch; threshold 20%: 7,6 switch + 60,8s → chọn 5% |

| **Switch saga bền vững (E2.5)** | `src/switch_txn.rs`: file `switch-txn.json` (0600, atomic) với phase `decided → captured → auth_swapped → verified → done/rolled_back`, `txn_id`, from/to, `started_at`, `attempt`; tích hợp vào đường apply: ghi ý định **trước khi** đổi auth, rollback khi activate lỗi, **verify danh tính live** sau khi swap (chỉ rollback khi live trỏ về account cũ; auth không đọc được = không kết luận), clear khi xong; `reconcile` lúc vào apply để chốt/dọn txn của lần chạy trước (idempotent, txn >5 phút bị coi là bỏ); `in_flight_for_pair` chặn switch trùng | `c706a2f`, `7af4a5b` | 5 test `switch_txn` (phase+clear, crash ở mọi phase + reconcile hai lần cho cùng kết quả, txn cũ bị bỏ và không chặn, live không xác định → dọn, file hỏng không gây lỗi); **445 test pass**, không hồi quy |
| **macOS UX (B, phần 3)** | About không còn quảng cáo "tìm kiếm / lọc trạng thái / sắp xếp / thao tác hàng loạt" (UI không có) — mô tả lại đúng danh sách sắp theo quota còn lại | `3f1071d` | `swift build` pass |
| **macOS UX (B, phần 4 — feedback)** | `AccountStore.toast` (success/failure, tự tắt sau 4s) + banner trong **Console** và pill trạng thái trong **notch**; notch không tự thu khi `isSwitching`; thông báo export/import/restore có toast + **đường dẫn đã rút gọn `~`** và được bản địa hoá (trước hardcode tiếng Việt); toast "Đã chuyển sang <email>" sau khi switch | `7c937d9` | `swift build` pass; `RosterToastBanner` dùng `systemGreen/systemOrange` + `labelColor` |
| **macOS UX (B, phần 6 — freshness QTA-1)** | `QuotaFreshnessLabel` trong panel notch: "vừa cập nhật" / "cập nhật Np trước" / "chưa có dữ liệu quota", chuyển cảnh báo khi quá 10 phút (cùng ngưỡng với badge ở compact ear) | commit mới | `swift build` pass |
| **macOS UX (B, phần 5 — a11y/Light Mode)** | `PrismGreenSwitchToggleStyle` có trait `.isToggle` (+`.isSelected`) và value Bật/Tắt, tôn trọng Reduce Motion; nút switch có `accessibilityLabel "Đổi sang <tên>"`; nút icon tròn đạt hit target ≥28pt; thêm role màu ngữ nghĩa (`statusOK/Warn/Error/Info`, `labelPrimary/Secondary`) theo system palette và áp cho OperationsView | `3f1071d`→ commit mới | `swift build` pass |

| **Scheduler auto-switch (A1)** | `AutoSwitchOutput.next_probe_seconds` (additive): cửa sổ 5h đã cạn ⇒ ngủ tới lúc reset (kẹp 30s–15 phút, nới theo dwell); `waiting_for_processes` ⇒ 15s; `waiting_for_dwell` ⇒ đúng phần dwell còn lại; monitor dùng hint thay vì poll cố định 45s | `4ba256d` | 2 test mới (`next_probe_waits_for_an_exhausted_window_to_reset` ~300s, cap 900s; healthy/unknown ⇒ `None`); **447 test pass** |
| **macOS UX (B, phần 7 — IA-3/IA-4)** | `RosterListFilter.archived` + chip "Đã cất N" trong deck; **danh sách mặc định loại archived** (và khỏi counts); badge chấm nhỏ trên nút `⋯` khi có bản cập nhật; **xác nhận trước khi cài**, nêu rõ version | `cf922c8` | `swift build` pass |
| **PERF-2** | Vòng thông báo reset: **2s → 15s** (30 → 4 lần wakeup/phút) và **cache quyền thông báo** (chỉ hỏi lại mỗi 5 phút) | `791001c` | `swift build` pass |

| **F — Forecast lên UI** | `QuotaForecastOutput`/`QuotaWindowForecast` trong Swift + `AccountStore.quotaForecast` + dòng "cạn sau ~X (CI …) · confidence …" dưới gauge trong deck; refresh kèm quota-history | `2b59d71` | decode hợp đồng bằng chương trình Swift độc lập trên JSON thật của binary (xem [VERIFICATION.md](VERIFICATION.md) §2) |
| **A2 — Housekeeping** | Cap `preserved-metadata-*.json` (giữ 20 mới nhất, idempotent) và dọn thư mục `.cas-backup-*`/`.cas-restore-*` bỏ hoang (>1 giờ) ngay khi bắt đầu activation dưới auth lock; cả hai best-effort, không bao giờ làm hỏng restore/activate | `e140385`, `a6903d2` | test `preserved_metadata_copies_are_capped`, `stale_recovery_dirs_are_pruned_but_fresh_and_unrelated_ones_are_kept`; **449 test pass** |

| **A3 — CLI/TUI** | `list` human: hiện **label**, **plan**, `[archived]`, và **giờ reset theo múi giờ máy** (trước chỉ ngày UTC); cờ **`--all`** để gồm archived + dòng nhắc "(N archived hidden)"; TUI: **PgUp/PgDn**, **Home/End (g/G)**, **`/` tìm kiếm** (khớp không phân biệt hoa thường, nhảy tới dòng đầu tiên) + cập nhật dòng hướng dẫn phím | `cb6b602`, `d2aba9a` | test `account_summary_shows_label_plan_and_state`, `search_matches_case_insensitively_and_ignores_empty_queries`; `list --help` có `--all`; output thật hiện `reset 2026-10-18 16:03:28.0` theo giờ máy |
| **B — Empty state (FLOW-8)** | `hasLoadedAccounts` + hàng "Đang tải danh sách tài khoản…" thay vì màn "Chưa có tài khoản" sai trong lúc load đầu | commit mới | `swift build` pass |

| **A2 — Nốt phần phụ** | Cap config VibeCafe 64 KiB + response 2 MiB (bounded read, không buffer file lạ); cache VibeCafe ghi atomic 0600; `doctor` thêm check **`account_list_backup`** (tuổi backup danh sách tài khoản, warn nếu chưa có hoặc >24h) để backup lỗi không còn im lặng | `d5feeef` | test `config_reader_rejects_oversized_files`; `doctor` chạy thật: `[ok] account_list_backup newest account-list backup is 1h old` |
| **I18N-1** | Rà toàn bộ literal hiển thị không qua `language.text`: **0 chuỗi tiếng Anh lộ** (2 hit là tên riêng attribution). Các leak audit nêu (watchdog login, export success, About) đã được bản địa hoá ở các vòng trước | — | ghi trong [VERIFICATION.md](VERIFICATION.md) §4b |

| **A2 — Cảnh báo backup vào JSON** | Cảnh báo backup thất bại được ghi nhớ trong process và phơi ra `status --json` qua `warnings[]` (additive, ẩn khi rỗng); tự xoá khi backup kế tiếp thành công | `cf7c4e3` | test `a_failed_account_list_backup_is_recorded_for_status_json` (chặn backup bằng file cùng tên thư mục); `status --json` không có `warnings` khi mọi thứ bình thường |
| **A3 — `add-account-status`** | Trả thêm `state` (`pending`/`none`), `codex_root`, `hint`; human output nói rõ bước tiếp theo và credentials đã đổi chưa | `1d576d4` | chạy thật: `{"active":false,"state":"none","hint":"Start one with …","contract_version":1}` |
| **F wave 2 — Runway bar** | `QuotaRunwayBar`: so `time_to_empty` với thời gian tới reset của cửa sổ 5h → "dự báo cạn trước khi reset" (cam) / "đủ tới lúc reset" (xanh) / "chưa đủ mẫu" (mờ) | `ec07cf7` | `swift build` pass |

**Verification độc lập:** xem [VERIFICATION.md](VERIFICATION.md) — gate đầy đủ với `--all-features` (449 test), decode hợp đồng Rust↔Swift bằng binary thật, 29/29 điểm audit then chốt PASS, và 1 gate CI (`check-auth-switch-safety.sh`) đã được sửa sau khi verification phát hiện fail.

**Gate hiện tại:** `cargo fmt --check` pass · `cargo clippy --all-targets -- -D warnings` pass · **447 test pass, 0 fail, 2 ignored** · `swift build --package-path macos/NextAccount` pass · `scripts/build-macos-app.sh` pass.

**Orca:** Codex chạy được 1 task nhỏ rồi **cạn hạn mức tháng đến 17/11/2026** (`You've hit your usage limit`); worker D đã được `worker-stop` + `worker-release` sạch và phần D do Lead hoàn thành. Các provider khác vẫn cạn (Claude 22/10, Cursor 11/12/2026, OpenCode/Muse sai model, antigravity/zcode fail).

## 2. Còn lại (đã dọn theo thực tế)

| # | Hạng mục | Trạng thái |
|---|---|---|
| 1 | Review độc lập bởi **agent khác** (Orca worker) | Không thực hiện được: mọi provider Orca cạn quota; verification do Lead tự chạy, đã ghi rõ giới hạn trong [VERIFICATION.md](VERIFICATION.md) §5 |
| 2 | Integration test đầu-cuối cho một lần apply thành công (đường saga) | Chưa có; đã ghi nhận trung thực |
| 3 | Test Swift trong CI (`swift test`) | Không chạy được trên máy CLT-only; CI `macos-latest` sẽ chạy |
| 4 | HUD/gợi ý hành động nâng cao hơn nữa (ngoài runway bar + caption hiện có) | Ngoài phạm vi audit đề xuất |

Mọi hạng mục P0/P1/P2 và các tính năng thuật toán P3 khả thi trong audit đều đã được triển khai và có bằng chứng; các mục còn lại ở trên là giới hạn môi trường hoặc phần mở rộng ngoài đề xuất.

## 3. Vì sao Lead làm trực tiếp thay vì worker Orca

Orca runtime hoạt động (run `run_35abe4633637`, coordinator terminal riêng), nhưng **mọi provider agent đều cạn**:

| Provider | Lỗi | Mở lại khi |
|---|---|---|
| Claude | monthly spend limit | 22/10 |
| Codex | 429, `monthly limit: only 5% left` | chưa rõ |
| Cursor (Auto) | `You've hit your free requests limit` | 11/12/2026 |
| OpenCode / Muse | model `gpt-6.1-sol` không hỗ trợ với tài khoản ChatGPT | cần đổi model |
| Antigravity / zcode | dispatch failed | cần cài/đăng nhập |

6 worker Codex đầu tiên chạy 50 phút mà không ghi được file nào (429); toàn bộ đã được `worker-stop` + `worker-release`. WIP của họ được cứu vào `main` và hoàn thiện.

**Hai cách mở lại worker song song** (cần bạn quyết):
1. **Chuyển tài khoản Codex live** sang một account quota 100/100 trong roster (`khang22919a+r6@gmail.com`, `ellisususanr733@googlemail.com`, `mhmdyhm.raql+iff@googlemail.com`, `10220008+mediaynju@utc2eduvn.onmicrosoft.com`) — thao tác này đổi phiên `~/.codex` và có thể quit/relaunch ChatGPT Desktop.
2. **Cho phép subagent của DSH** làm phương án dự phòng (khác Orca) — mặc định tôi không dùng vì bạn yêu cầu `/orchestration`.

## 4. Giới hạn kiểm chứng

- Chưa chạy GUI/Desktop thật; kết luận UI dựa trên `swift build` + đọc code.
- Chưa test 2 process thật cho lock `session-resume.json` (chỉ test đa luồng).
- `swift test` không chạy được trên máy CLT-only (`no such module 'Testing'`); CI có Xcode sẽ chạy.
