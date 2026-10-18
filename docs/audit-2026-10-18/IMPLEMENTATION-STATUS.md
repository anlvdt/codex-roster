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

**Gate hiện tại:** `cargo fmt --check` pass · `cargo clippy --all-targets -- -D warnings` pass · **417 test pass, 0 fail, 1 ignored** · `swift build --package-path macos/NextAccount` pass.

## 2. Còn lại (theo thứ tự ưu tiên)

| # | Hạng mục | Ghi chú |
|---|---|---|
| 1 | A1: scheduler `next_probe_at` trong `auto_switch_monitor` | Phần còn lại của Q2 (hiện đã fail-closed theo `reset_at`, chưa tối ưu nhịp poll) |
| 2 | A2: atomic write + fsync, backup surfacing, HTTP body caps | Chưa bắt đầu |
| 3 | A3 phần còn lại: help 22 lệnh, `list` human, TUI search/PgUp, bỏ deprecated khỏi help | Chưa bắt đầu |
| 4 | B phần còn lại: menu-bar item, `⌘,`, delete confirm, Light Mode token, a11y, freshness chip, `PassiveRefreshGate` | Chỉ mới xong phần lỗi guard |
| 5 | C: `[profile.release]` strip/LTO, CI `--locked` + SHA-pin, release workflow ký/notarize | Chưa bắt đầu |
| 6 | E1: contract v2 (`contract_version`, RFC3339, error envelope, exit code) + `doctor` | Chưa bắt đầu |
| 7 | E2: forecast EWMA, scoring v2 một nguồn, switch saga, harness tuning | Chưa bắt đầu |
| 8 | D: README/CHANGELOG/PR_DESCRIPTION truth-up + archive docs cũ | Chưa bắt đầu |
| 9 | F/G: Swift wave 2 (HUD, dự báo, gợi ý) + verification độc lập | Chưa bắt đầu |

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
