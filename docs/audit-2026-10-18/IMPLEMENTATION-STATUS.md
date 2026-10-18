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

**Gate hiện tại:** `cargo fmt --check` pass · `cargo clippy --all-targets -- -D warnings` pass · **423 test pass, 0 fail, 1 ignored** · `swift build --package-path macos/NextAccount` pass · `scripts/build-macos-app.sh` pass.

**Orca:** Codex chạy được 1 task nhỏ rồi **cạn hạn mức tháng đến 17/11/2026** (`You've hit your usage limit`); worker D đã được `worker-stop` + `worker-release` sạch và phần D do Lead hoàn thành. Các provider khác vẫn cạn (Claude 22/10, Cursor 11/12/2026, OpenCode/Muse sai model, antigravity/zcode fail).

## 2. Còn lại (theo thứ tự ưu tiên)

| # | Hạng mục | Ghi chú |
|---|---|---|
| 1 | A1: scheduler `next_probe_at` trong `auto_switch_monitor` | Phần còn lại của Q2 (đã fail-closed theo `reset_at`, chưa tối ưu nhịp poll) |
| 2 | A2 phần còn lại: đưa cảnh báo backup vào JSON `warnings[]`, cap `preserved-metadata-*`, dọn `.cas-backup-*` cũ, cap config VibeCafe | Phần lõi đã xong |
| 3 | A3 phần còn lại: `list` human (label/archived/local reset + `--all`), TUI search/Home/End/PgUp, `add-account-status` chi tiết | Help + safety đã xong |
| 4 | B phần còn lại: Light Mode token (VIS-1), a11y label/toggle/reduce-motion, freshness chip (QTA-1), notification loop 15s, archived filter, update badge | Đã xong menu-bar/`⌘,`/xoá/hover/passive refresh |
| 5 | E2: forecast EWMA, scoring v2 một nguồn, switch saga, harness tuning | Chưa bắt đầu |
| 6 | F/G: Swift wave 2 (HUD, dự báo, gợi ý) + verification độc lập | Chưa bắt đầu |

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
