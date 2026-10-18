# Audit auto-resume của Codex — Codex Roster (2026-10-18)

**Phạm vi:** toàn bộ vòng đời auto-resume trong `src/session_resume.rs` (1.261 dòng gốc), các call site trong `src/app/service.rs`, `src/codex_activity.rs`, và đối chiếu phía Swift (`SessionResumeBatch.swift`, `CodexResumePolicy.swift`, `AccountStore.swift`).
**Phương pháp:** đọc production path + đọc test để lấy invariant, rồi kiểm tra production path có thực thi invariant đó không. Không chạy lệnh mutate, không đụng `~/.codex`, không network. Mọi kết luận đều truy được về `file:line`.
**Trạng thái:** các mục đánh dấu **Đã sửa** nằm trong commit `a06fcf7` (index lock + discovery bound) và các commit kế tiếp của đợt này.

## 1. Vòng đời thực tế (đã trace)

```
auto-switch decide ──(quota cạn, có candidate)──> apply
  ├─ capture_pending_continue(app_data, codex_root, active_account_id)   service.rs:500
  │    └─ discover_interrupted_sessions()  ← SQL state_5.sqlite + đọc tail rollout
  │    └─ ghi session-resume.json (pending_continues)   [session-resume.lock]
  ├─ activate_with_expected_active()  (đổi ~/.codex, AuthLock + OperationLock)
  ├─ mark_activated(app_data, account_id)                service.rs:970
  └─ take_pending_continue_hint(app_data, enabled)       service.rs:525
       └─ hint{ session_id, cwd, rollout_path, status }  → Swift deep-link / composer Play
```

**Cửa sổ thời gian:** `USAGE_LIMIT_RESUME_WINDOW = 6h` cho thread bị chặn usage-limit (`session_resume.rs:61`); nhánh mid-flight `task_started` dùng cửa sổ 45 phút (Swift) và `ACTIVATED_GRACE = 5s` cho mốc activate (`:55`).
**Khoá:** thứ tự tài liệu hoá trong code là `AuthLock → OperationLock → session-resume.lock` (`:126`, `:180`).

## 2. Phát hiện

| ID | Mức | Vị trí | Trigger → Tác động | Trạng thái |
|---|---|---|---|---|
| **AR-1** | **High** | `session_resume.rs:126,180,245,286,317`; đối thủ `service.rs:970` | `session-resume.json` được read-modify-write **không khoá** trong khi `activate` giữ `AuthLock`+`OperationLock` và `mark_activated` ghi cùng file. Ghi đan xen ⇒ mất `pending_continues` (switch xong nhưng **không resume** thread vừa bị chặn) hoặc mất `activated_at` ⇒ capture sau đó gán sai rollout của account khác. | **Đã sửa**: mọi RMW đi qua `with_index_mut` + `SessionResumeLock` (fs2 `try_lock_exclusive`, timeout 30s, retry 50ms). Có test đa luồng. |
| **AR-2** | Medium | `session_resume.rs:317-337` | `take_pending_continue_hint(enabled=false)` vẫn `take()` queue ⇒ tắt auto-resume đúng lúc switch làm mất queue; bật lại không resume được. | **Đã sửa**: khi `!enabled` chỉ đọc + phát warning "preserved pending continue queue", **không** tiêu thụ. Test `..._disabled_preserves_batch`. |
| **AR-3** | Medium–High | `session_resume.rs:63-66,563-584`; gọi từ `service.rs:44-68` → `codex_activity.rs` | `status()` (notch/CLI poll vài giây/lần) quét **mọi** thread chưa archive rồi đọc ≥512 KB mỗi rollout (có fallback đọc cả file). Với hàng nghìn thread ⇒ GB đọc mỗi lần poll, làm chậm cả notch. | **Đã sửa**: SQL lọc `COALESCE(recency_at_ms, updated_at_ms) >= now-6h` + `LIMIT 50`; tail cap 128 KB; cap mở rộng 1 MB; cache `(path,size,mtime)`; counter `rollout_bytes_read()/rollout_cache_hits()` để đo. |
| **AR-4** | Low–Medium | `session_resume.rs:889-905` | Codex tạo `sessions/YYYY/MM/DD` theo **ngày local**, code cũ suy ra theo `now_utc().date()` ⇒ lệch ngày gần nửa đêm hoặc với UTC offset lớn ⇒ bỏ sót thread. | **Đã sửa**: `session_day_dates()` quét **cả thang local và UTC**, dedupe, mới nhất trước. Test UTC+14. |
| **AR-5** | Low | `session_resume.rs:469-488` | Hint chỉ có `session_id` mà không có `rollout_path` vẫn báo `ready` ⇒ Swift thử deep-link rồi fail. | **Đã sửa**: thiếu rollout ⇒ `ready_cli`; rollout không còn ⇒ `rollout_gone`; chỉ `ready` khi file rollout tồn tại. |
| **AR-6** | Medium | Rust `session_resume.rs` ↔ Swift `SessionResumeBatch.swift:1378,1403`, `CodexResumePolicy.swift:1633-1661`, `AccountStore.swift:200` | Policy bị cài **hai lần**: dedupe "recently continued", ngưỡng idle (Rust 45s vs Swift 20s), quyền sở hữu queue, cách đọc queue. Sửa một bên dễ lệch bên kia; không có test chéo. | **Chuyển cho Swift** (task B/F): Rust nên là nguồn duy nhất cho `status`/`idle_secs`, Swift chỉ render + enqueue. |
| **AR-7** | Medium | `service.rs:500,525`; `session_resume.rs:86-96` | Lỗi discovery/capture vẫn bị nuốt ở call site (`let _ =`); API `take_last_warnings()` đã có nhưng chưa nối vào output/UI ⇒ người dùng không biết resume đã bị bỏ. | **Một phần**: warnings API + counters đã có; nối vào `AutoSwitchOutput.warnings` thuộc task A1/E1 (đang làm). |
| **AR-8** | Low | `service.rs:500` | `capture_pending_continue` chạy **trước** khi swap; nếu swap fail, queue còn lại (an toàn) nhưng không có TTL rõ ràng cho `pending_continues` ⇒ có thể resume một thread rất cũ ở lần switch sau. | **Còn lại**: đề xuất TTL (ví dụ 6h khớp `USAGE_LIMIT_RESUME_WINDOW`) khi take. |
| **AR-9** | Low | `session_resume.rs:55` | `ACTIVATED_GRACE = 5s`: thread activate trong 5s bị coi là thuộc account vừa activate. Đúng ý đồ nhưng rất hẹp nếu máy chậm; chưa có test biên. | **Còn lại**: thêm test với mtime lệch 4.9s/5.1s. |
| **AR-10** | Info | `session_resume.rs:544-620` | Phân loại `task_complete` + `usage_limit_exceeded` (6h) vs `task_started` mid-flight (45m) là thiết kế có chủ đích, có test. | **Giữ nguyên** |
| **AR-11** | Low | `session_resume.rs` (log/ids) | Không log nội dung rollout; chỉ session id, đường dẫn, trạng thái. | **Giữ nguyên** |

## 3. Đã sửa trong đợt này (kèm test)

| Thay đổi | Test chứng minh |
|---|---|
| Khoá xuyên process cho mọi RMW của `session-resume.json`, thứ tự khoá tài liệu hoá | `session_resume` tests (đa luồng) — 18 test xanh |
| `enabled=false` không tiêu thụ queue | `empty_capture_replaces_stale_pending_and_disabled_preserves_batch` |
| SQL recency + `LIMIT 50` + tail 128 KB + cap 1 MB + cache | `database_excludes_archived_threads_and_has_no_single_thread_limit` (fixture dùng timestamp hiện tại), `long_running_turn_is_detected_beyond_tail_and_new_completion_wins` |
| Thang ngày local+UTC | `session_day_ladder_covers_local_and_utc_dates_newest_first` |
| `ready` cần rollout thật | `captures_latest_user_thread_and_builds_ready_hint` |
| Toàn bộ suite | `cargo test`: **410 passed, 0 failed, 1 ignored** |

## 4. Chuyển cho Swift (task B/F)

1. Hiển thị **pending/queued resume** (số lượng + account), kết quả resume gần nhất, và lý do thất bại — hiện chỉ có caption ngắn, không có chỗ xem queue.
2. Toggle auto-resume phải phản ánh thực tế: `disabled` vs `đang chờ quota` vs `đã queue N thread`.
3. Bỏ tính lại policy trong Swift (dedupe/ngưỡng idle) — dùng field từ Rust khi có; giữ `SessionResumeBatch` chỉ như executor.
4. Nút "thử lại" cho resume thất bại.

## 5. Còn lại / giới hạn

- Chưa chạy thử trên account thật: mọi kết luận là đọc code + test fixture; chưa xác minh deep-link/Play control trên Desktop thật.
- Chưa có test 2 process thật cho lock (chỉ test đa luồng trong cùng process).
- AR-7/AR-8/AR-9 như bảng trên.
- Swift test không chạy được trên máy CLT-only (`no such module 'Testing'`); phần Swift cần Xcode/CI.

## 6. Điểm đang tốt — giữ nguyên

- Phân biệt rõ 3 trạng thái queue (`pending_continues` nhiều thread + `pending_continue` cũ) và migrate tương thích.
- `ACTIVATED_GRACE` + kiểm tra account id trong hint: chống gán nhầm thread của account khác.
- Cửa sổ usage-limit 6h khớp chu kỳ reset 5h; nhánh mid-flight tách riêng 45 phút.
- Test đặt tên theo invariant (`active_turn_after_quota_failure_is_not_rediscovered`, `long_running_turn_is_detected_beyond_tail_and_new_completion_wins`).
- Không log nội dung rollout, chỉ id/đường dẫn.
