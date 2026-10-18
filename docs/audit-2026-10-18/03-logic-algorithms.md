# Audit logic & thuật toán — Codex Roster (2026-10-18)

Auditor: `logic-auditor` (task-3). Snapshot: `8f27e8ce8fed3f0a83320623c933e1d87b4d7cdc` (v0.5.0).
Read-only trên source. Chỉ tạo file này. Không chạy `cargo test`, không network, không Keychain, không `~/.codex`.

## Phạm vi & phương pháp

**Phạm vi logic/thuật toán (không phải security/perf chung):**

| Vùng | File chính | LOC |
|---|---|---|
| Quota model + parse/aggregate | `src/usage.rs`, `src/model.rs` | 2003 + 729 |
| Auto-switch Codex | `src/app/service.rs` (decide/apply/eligibility/score), `src/app/auto_switch_monitor.rs` | 4134 + 141 |
| Auto-switch provider ngoài (feature-gated) | `src/app/provider_auto_switch.rs`, `src/provider/pace.rs` | 866 + 97 |
| Reset outlook/notification | `src/reset_tracker.rs` | 1057 |
| Session continuity | `src/session_resume.rs` vs `macos/.../CodexResumePolicy.swift`, `SessionResumeBatch.swift`, `AccountStore.swift` | 1261 / 106 / 5000+ |
| Token/cost estimator | `src/token_usage.rs` | 1014 |
| Quota history/sparkline | `src/quota_history.rs` | 186 |
| Activity/idle | `src/codex_activity.rs` | 208 |
| Locking | `src/operation_lock.rs`, `src/repository/index_store.rs`, `src/file_store.rs` | 171 + 691 |
| Time/format | `src/time_display.rs` | 35 |

**Phương pháp:** đọc production path + đọc test để lấy invariant dự kiến, rồi kiểm tra production path có thực thi invariant đó không. Mọi kết luận đều quy về một trong hai loại:

- **Reachable bug**: chỉ ra được chuỗi caller cụ thể (worker/GUI/CLI) dẫn tới hành vi sai.
- **Theoretical concern** (ghi rõ `[inference]`): đúng về code nhưng chưa chứng minh được payload/hệ điều hành thực tế kích hoạt.

**Rubric mức độ (dùng xuyên suốt):**

| Mức | Định nghĩa |
|---|---|
| **Critical** | Mất/hỏng credential, mất dữ liệu không phục hồi, hoặc ghi sai tài khoản. |
| **High** | Trạng thái quyết định sai một cách hệ thống (switch sai/không switch được/danh sách sai) ảnh hưởng trực tiếp promise sản phẩm; hoặc vòng lặp gây hại cho phiên người dùng. |
| **Medium** | Sai số liệu hiển thị/ranking, mất dữ liệu phụ (history/resume), hoặc chậm trễ có giới hạn. |
| **Low** | Edge case hẹp, khó đạt, hoặc chỉ ảnh hưởng maintainability/testability. |

**Kết luận mức cao:** không có **Critical** trong phạm vi đọc được. Tổng **43 phát hiện**: **6 High**, **21 Medium**, **16 Low** (Q4 có nhánh code-level High nhưng khả năng kích hoạt thấp nên xếp Medium). Phần lớn High tập trung ở một gốc: *quyết định auto-switch không có khái niệm "window đã hết hạn / window chưa biết"*. Các safeguard ghi file (`restore_snapshot_with_retry` rollback, `replace_file_with_recovery`, `activate_if_active_matches`) đủ tốt để chặn nhóm Critical.

---

## Mô hình dữ liệu & luồng quyết định

### 1. Quota model (chuỗi parse thật)

```
GET https://chatgpt.com/backend-api/wham/usage   (Bearer AT, ChatGPT-Account-Id)
  → UsageResponse::from_value()            usage.rs:336-375   tolerant, field-by-field
    ├─ rate_limit.primary_window   → AccountUsageView.five_hour   usage.rs:640-645
    ├─ rate_limit.secondary_window → AccountUsageView.weekly      usage.rs:646-651
    ├─ credits (has_credits/unlimited/balance)                    usage.rs:486-498
    ├─ individual_limit / spend_control → CreditLimitView         usage.rs:500-523, 1078-1103
    ├─ rate_limit_reset_credits.available_count → banked_resets    usage.rs:407-417
    ├─ additional_rate_limits[gpt-reserve|luna] → luna_reserve     usage.rs:1161-1217
    └─ placeholders: email, plan_type, account_id
GET .../wham/rate-limit-reset-credits  → chi tiết credit (best-effort)  usage.rs:829-855
```

`UsageWindow` **chỉ** đọc `used_percent` + `reset_at` (`usage.rs:461-475`); mọi field khác của API (kể cả bất kỳ `limit_window_seconds`/`window_minutes` nếu có) bị bỏ. Mapping **cứng**: `primary_window ⇒ five_hour`, `secondary_window ⇒ weekly`.

| Field | Kiểu | Ý nghĩa thực tế | Ghi chú |
|---|---|---|---|
| `used_percent` | `u8` | server **floor** số nguyên, 99 nghĩa là đã bị chặn | `flexible_u8` clamp `0..=255` (`usage.rs:592-594`) — không clamp 100 |
| `remaining_percent` | `u8` | `100.saturating_sub(used)` (`usage.rs:1037`) | suy ra cục bộ, không có trong payload |
| `reset_at` | `OffsetDateTime` UTC | mốc reset của window hiện tại | Unix seconds; **không** có khái niệm "window đã trượt" |
| `fetched_at` | `OffsetDateTime` | **cuối** lần fetch thành công | dùng làm mốc freshness 15 phút |
| `plan_label` | `Option<String>` | plan của **lần fetch này** | `normalize_plan_label` (`usage.rs:1105-1133`) |
| `banked_resets` | `Option<summary>` | credit reset riêng tài khoản | `count = max(reported, available rows)` (`usage.rs:698-704`) |
| `credits` | `Option<CreditsView>` | spend balance | `balance=""` = không đọc được, **không** phải 0 (`usage.rs:1042-1066`) |

**Ngữ nghĩa phần trăm:** API trả *used* (đã dùng), app tự tính *remaining*. Vì server floor `used`, một window bị chặn đọc là `used=99/remaining=1`. Vì vậy app coi `remaining <= 1` là **depleted** (`EXHAUSTED_REMAINING_PERCENT`, `service.rs:1544-1553`) — đây là quyết định đúng và được mirror sang Swift (`AccountStore.swift:5112-5117`).

**Staleness / caching (toàn bộ hằng thời gian liên quan quyết định):**

| Hằng | Giá trị | Nơi | Vai trò |
|---|---|---|---|
| `cached_usage_is_fresh` | 15 phút | `service.rs:1859-1873` | chỉ coi cache là "tươi" nếu **mọi** window còn quota |
| `EXHAUSTED_USAGE_PROBE_BACKOFF` | 10 phút | `service.rs:1877` | cache exhausted không bị probe lại trong 10 phút |
| `RECENT_LIVE_PROBE_WINDOW` | 20 s | `service.rs:1881` | apply bỏ probe live nếu decide vừa probe |
| `AUTO_SWITCH_ACCOUNT_COOLDOWN` | 2 phút | `service.rs:1799` | loại source+target khỏi lần switch kế |
| `AUTO_SWITCH_POLL_SECONDS` | 45 s | `auto_switch_monitor.rs:14` | nhịp worker TUI/CLI |
| `AUTO_SWITCH_EXHAUSTED_BACKOFF_SECONDS` | 45 s | `auto_switch_monitor.rs:16` | **bằng đúng poll** → không phải backoff |
| `AUTO_SWITCH_BANKED_RESET_BACKOFF_SECONDS` | 20 s | `auto_switch_monitor.rs:19` | poll nhanh hơn khi có banked reset |
| `USAGE_REFRESH_POLL_SECONDS` | 120 s | `usage_refresh.rs:17` | sweep cache stale |
| `USAGE_FRESHNESS` (Claude) | **2 phút** | `provider_auto_switch.rs:19` | khác hẳn 15 phút của Codex |
| GUI decide poll | 10 s khi active 0%, 45 s khác | `AccountStore.swift:461-482` | mỗi nhịp spawn 1 CLI `auto-switch` |

**`usage_error_blocks_activation`:** là **classifier chuỗi** trên message đã lưu (`usage.rs:232-256`, `282-298`), không phải kiểu dữ liệu. Nó quyết định 6 chỗ: null `usage` trong `AccountView` (`app.rs:42-56`), loại khỏi candidate, bỏ qua probe, chặn banked fallback, chặn auto-start ping, và ẩn báo lỗi. Hệ quả: đổi wording/ngôn ngữ message sẽ đổi hành vi (xem Q5).

### 2. Invariant "eligible" — ma trận thực tế

| Trạng thái window của account | `is_exhausted_for_switch` (active) | `is_usable_for_switch` (candidate) | Kết luận |
|---|---|---|---|
| 5h + weekly đều ≥ 2% | false | true | eligible |
| 5h ≤ 1% (weekly ổn) | **true** | false | exhausted, cần switch |
| weekly ≤ 1% (5h ổn) | **true** | false | exhausted (weekly dominant) |
| 5h thiếu, weekly 90% | false | **true** | **eligible** — 5h thật có thể đã cạn |
| weekly thiếu, 5h 90% | false | **true** | eligible (fallback có chủ đích) |
| cả hai thiếu (`usage = Some` rỗng) | **false** | **false** | active ⇒ `active_has_quota`; candidate ⇒ không eligible |
| `usage = None` (chưa từng fetch / bị block) | **false** | false | active ⇒ `active_has_quota` (**S2**) |
| credits positive hữu hạn | false | true | eligible (credit gia hạn được) |
| `reset_at` đã ở quá khứ (percent cũ) | **theo percent cũ** | **theo percent cũ** | **Q1** |

Invariant trong comment ("eligible ⇔ mọi window được báo cáo còn quota") chỉ đúng với window **được parse thành công**. Window bị API bỏ trống, hoặc bị parser bỏ, được coi là *không cản trở*.

### 3. State machine thực tế của auto-switch Codex

```
                 ┌───────────────── add_account_session_active ─────────────┐
                 │                                                          v
  [*] ─ (enabled?) ──no──> disabled                              waiting_for_login
        │yes                                                             ^
        v                                                               │ no live/saved active
  ┌─> decide (AutoSwitchLock) ─────────────────────────────────────────┘
  │     ├─ is_exhausted_for_switch(active.usage)?  ──no──> active_has_quota
  │     ├─ probe candidates (fresh cache ⇒ skip; exhausted ⇒ 10m backoff skip)
  │     ├─ rank by switch_quota_score (weekly*1000 + 5h; depleted = -1)
  │     ├─ revalidate top-down (live AT probe / deferred-cache shortcut)
  │     │      └─ one passes ──> ready(candidate)
  │     ├─ banked reset (active > 0, hoặc fallback exhausted+credits>0) ─> banked_reset_available
  │     └─ none ──> all_accounts_exhausted
  │
  │   ready ──(apply, AutoSwitchLock lại)──
  │     ├─ live probe nếu cache > 20s; !exhausted ⇒ active_has_quota (huỷ switch)
  │     ├─ preferred id ⇒ revalidate; không thì walk cached hints (broad hơn!)
  │     ├─ none ⇒ all_accounts_exhausted
  │     ├─ final belt: usable && !exhausted
  │     ├─ preflight warnings (Desktop/CLI đang chạy) ⇒ waiting_for_processes
  │     ├─ capture_pending_continue(active)        ← ghi index KHÔNG lock
  │     ├─ activate_with_expected_active  (AuthLock + expected-active check + restore+rollback)
  │     ├─ save last_auto_switch_{at,from,target}  (+2m cooldown)
  │     └─ take_pending_continue_hint ⇒ switched + session_resume
  └──────────── (sleep 45s; GUI: 10s khi 0%, tự quit/relaunch Desktop) ────────┘
```

**Sequence auto-switch do GUI chủ động (đường thật trên macOS):**

```
Swift poll (10s @0%)                  Rust CLI (process riêng)             Filesystem/Keychain
  │ auto-switch --json                       │
  │────────────────────────────────────────> │ decide: usage(None) ──────────> AuthLock, HTTP
  │<────────── status=ready, candidate=B ──── │  (probe A,B,C…, cache writes)
  │ isTurnActive()? (session write <20s) ──── │
  │ prepareForAccountSwitch(force)            │
  │  ⇒ quit ChatGPT Desktop                   │
  │ auto-switch --apply --force --account-id B │
  │────────────────────────────────────────> │ apply: probe live nếu cache>20s
  │                                          │ activate_if_active_matches(B, A)
  │                                          │   AuthLock + process scan (CLI ⇒ block!)
  │<──── waiting_for_processes | switched ─── │   restore auth.json (+rollback), metadata
  │ relaunch Desktop + confirm acceptance    │
```

**Ai sở hữu quyết định:** Rust sở hữu toàn bộ predicate; Swift sở hữu *sub-state machine* (closingDesktop/relaunchingDesktop/pausedAllExhausted) **và tự tính lại** `isExhaustedForSwitch`/`isUsableForSwitch`/`switchQuotaScore` (`AccountStore.swift:4595-4657`). Đây là nguồn drift chính (S4, P4).

---

## Phát hiện

### A. Quota model, thời gian & ngữ nghĩa phần trăm

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| **Q1** | High | `service.rs:1572-1593` (`is_usable_for_switch`), `1775-1795` (`switch_quota_score`), `1859-1873` (`cached_usage_is_fresh`) | Cache được fetch ở T với `5h=40%`, `5h.reset_at=T+2m`. Ở T+5m window đã reset thật (thực tế 100%) nhưng cache vẫn "fresh" (<15m) và các hàm trên vẫn dùng 40%. Ngược lại cache `0%` với `reset_at` đã qua vẫn bị coi là exhausted. → Ranking/quyết định dựa trên số liệu của window đã chết; "all_accounts_exhausted"/"active_has_quota" sai trong cửa sổ 15 phút. **Đối chứng**: display path nhận biết (`cli.rs:1226-1227`, `tui.rs:348-349`, `auto_start.rs:194-196`) và provider path nhận biết (`provider_auto_switch.rs:96-100`). Chỉ decision path của Codex thiếu. | Thêm `window_is_current(w, now) = w.reset_at > now`; mọi predicate phải yêu cầu **mọi** window hiện hành hợp lệ; window có `reset_at <= now` ⇒ coi là *unknown* ⇒ phải refetch trước khi quyết định. | High |
| **Q2** | High | `service.rs:1877`, `1883-1890` (`exhausted_cached_usage_skips_probe`), dùng ở `272-276`, `1083-1085` | A cạn quota lúc T. Account B (0% lúc T) reset tự nhiên lúc T+3m. T+5m worker decide: cache B exhausted, age 5m < 10m ⇒ **bỏ probe** ⇒ `all_accounts_exhausted` tới T+10m dù B đã có quota. → Trạng thái sai tới ~10 phút, tự hết nhưng user thấy "hết tài khoản" và có thể switch tay. | Backoff phải bị vô hiệu khi **bất kỳ** `reset_at <= now` (window đã trượt) hoặc khi `remaining <= 1` và `reset_at` trong quá khứ; thêm `next_retry_at` được tính từ `min(reset_at)` thay vì hằng 10 phút. | High |
| **Q3** | High | `usage.rs:461-475` (window cần cả `used_percent` + `reset_at`), `service.rs:1569-1593`, `1555-1567` | `primary_window` bị API bỏ trống, hoặc parse fail 1 field ⇒ `five_hour = None`. `is_usable_for_switch` chỉ kiểm weekly ⇒ **candidate eligible** dù 5h (window chặn turn thật) có thể 0%. Song song `is_exhausted_for_switch(None/None)` = false ⇒ active không bao giờ kích hoạt switch. → Vi phạm invariant cốt lõi ở cả hai chiều; không có field "completeness" để phân biệt *không có window* với *window bị mất khi parse*. | Thêm `AccountUsageView.completeness` (`five_hour_known`, `weekly_known`) hoặc `windows_observed: u8`; eligibility yêu cầu 5h known-usable (trừ khi có credits); active unknown ⇒ `usage_unknown` chứ không phải `active_has_quota`. | High |
| **Q4** | Medium | `usage.rs:1032-1034` (`window_view`), `640-651` | Một `reset_at` không biểu diễn được (`from_unix_timestamp` fail: âm lớn, tràn) ⇒ `into_view` trả `Err` ⇒ **toàn bộ** usage fetch thất bại, account bị đánh dấu `Usage unavailable` dù window kia hợp lệ. Ngược lại, thiếu `used_percent` chỉ làm mất window đó **im lặng**. | `window_view` nên skip window lỗi và set cờ `degraded` thay vì fail cả response; test với `reset_at` âm/`i64::MAX`. | High |
| **Q5** | Medium | `usage.rs:232-298`; lưu tại `repository.rs:596-624`; đọc lại ở `app.rs:42-56`, `service.rs:1669-1672` | Classifier là substring trên message **đã lưu**: message chứa `"decrypt"`, `"credential key"`, `"snapshot payload"` ở bất kỳ đâu ⇒ bị coi là *local recovery* ⇒ account vĩnh viễn bị loại khỏi auto-switch. Đổi wording trong tương lai làm phân loại cũ đổi nghĩa (dữ liệu lịch sử). | Lưu **enum** `UsageErrorKind` + message; classifier chỉ dùng khi decode record cũ (migration 1 lần). | Medium |
| **Q6** | Medium | `usage.rs:698-704` (`effective_banked_available_count`), `service.rs:1644-1658` (`banked_reset_count`) | Chỉ filter `status == "available"`, **không** filter `expires_at < now`. Credit đã hết hạn nhưng status chưa cập nhật ⇒ báo `banked_reset_available` và chặn nhánh `all_accounts_exhausted` ⇒ user chờ một reset không tồn tại; auto-resume sau redeem không bao giờ xảy ra. | `available && expires_at.map_or(true, |e| e > now)`; thêm test credit hết hạn. | Medium |
| **Q7** | Medium | `tui.rs:351`, `cli.rs:1231` vs `AccountStore.swift:5119-5122` | Window bị ChatGPT chặn đọc `remaining=1` hiển thị là "1%" trong TUI/CLI, nhưng Swift hiển thị 0% (`displayRemainingPercent`). → Cùng một payload, hai UI nói hai số khác nhau; user thấy "còn 1%" nhưng turn bị block. | Đưa `display_remaining_percent()` vào `model.rs` và dùng chung; hoặc hiển thị "0% (blocked)". | High |
| **Q8** | Low | `usage.rs:577-594` (`flexible_i64`, `flexible_u8`) | `used_percent` được clamp `0..=255` ⇒ có thể hiện 150%; `"inf"`/`"1e400"` parse thành `f64::INFINITY` rồi `as i64` saturate `i64::MAX` ⇒ `reset_at` lỗi ⇒ Q4. | Clamp `0..=100`; trong `flexible_i64` thêm `.filter(|v| v.is_finite())`. | High |
| **Q9** | Low | `service.rs:1110`, `time_display.rs:3-9` | `now_local().unwrap_or(now_utc())` và `UtcOffset::local_offset_at(..).unwrap_or(reset_at)` **im lặng** fallback UTC. Trên macOS offset lấy được, nhưng nếu fail (TZ lạ/CI) thì "today" của token usage và giờ reset hiển thị lệch 7–14h mà không có dấu hiệu. | Trả `Result`/cờ `offset_unknown` và render "UTC" khi fallback; test với offset không xác định. | Medium |
| **Q10** | Low | `usage.rs:625`, `service.rs:1057`, `token_usage.rs:73-75` | Không có xử lý clock skew: `fetched_at`/`now` đều từ clock máy. Nếu đồng hồ máy chậm 10 phút, cache 15 phút thành 5 phút ⇒ probe dày hơn; nếu nhanh 10 phút ⇒ cache "già" giả ⇒ probe liên tục; `reset_at` sắp tới bị coi là đã qua. Không dùng `Date` header của server. | Ghi `server_now` (từ `Date` response header) và tính `skew = server_now − local_now`; dùng `now_skewed()` cho freshness. | Medium |

### B. Auto-switch: trigger, ranking, apply, thrash

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| **S1** | High | `service.rs:204-318` (decide) vs `468-478` (apply preflight); `AccountStore.swift:2599-2665` | `decide` trả `ready` **không** xét process. GUI: `ready` ⇒ quit ChatGPT Desktop ⇒ `apply --force` ⇒ `ensure_activation_processes_stopped` thấy Codex **CLI** đang chạy (allow_desktop chỉ bỏ qua Desktop, `process.rs:89-116`) ⇒ `waiting_for_processes` ⇒ relaunch Desktop. Active vẫn 0% ⇒ 10s sau lặp lại. → Vòng quit/relaunch ChatGPT Desktop mỗi ~10s trong khi user đang chạy CLI agent; mất web session, mất cửa sổ, CPU/IO. | `decide` phải trả `waiting_for_processes` khi `activation_blocking_warnings(allow_desktop=true)` khác rỗng (chỉ CLI cản), và GUI chỉ quit Desktop khi apply chắc chắn qua được. | High |
| **S2** | High | `service.rs:1555-1567`, `24` (`ALLOW_LIVE_TOKEN_REFRESH=false`), `1283`, `1315-1327` | Live account hết hạn access token và **chưa có cache** (máy mới, hoặc roster vừa import): usage live fetch luôn 401 (Roster cố ý không refresh AT live) ⇒ `usage = None` ⇒ `is_exhausted_for_switch(None) = false` ⇒ `active_has_quota` mãi mãi. User phải tự mở Codex. → Auto-switch "câm" đúng lúc cần nhất; không có trạng thái `usage_unknown` để UI giải thích. | Trả `usage_unknown` khi không có cache và probe fail; với account live, hoặc cho phép 1 lần RT refresh có kiểm soát (dưới AuthLock + marker), hoặc escalate UI "mở Codex để làm mới phiên". | High |
| **S3** | Medium | `service.rs:1752-1770` (`is_cached_auto_switch_hint`) vs `237-286`+`288-299` (decide); dùng ở `423-440` | Apply tự dựng lại danh sách candidate bằng predicate **rộng hơn**: cached hint không cần probe, dùng `plan_hint_for_auto_switch` (roster label), không xét `recent_usage_error_skips_probe`. Account vừa 403/deactivated với cache usable <15 phút bị decide loại nhưng **apply vẫn có thể chọn** (đường `auto-switch --apply` không `--account-id`). | Một nguồn duy nhất: apply chỉ nhận `candidate_id` từ decide (+ `--account-id`), hoặc dùng chung `is_eligible_auto_switch_candidate` + cờ `probe_verified`. | Medium |
| **S4** | Medium | `service.rs:1772-1795` (`switch_quota_score`), `1842` (sort ổn định theo thứ tự roster); `AccountStore.swift:4639-4657` | Score chỉ gồm weekly×1000+5h: bỏ qua plan (Pro/Plus), độ gần reset, chi phí switch gần đây, banked expiry. Tie ⇒ giữ thứ tự repository (không phải tie-break tường minh). Swift **cộng 1e6** khi `hasWeeklyResetWithin24Hours` ⇒ thứ tự "best" trên UI khác thứ tự auto-switch chọn. | Score đa yếu tố integer tường minh (xem U5) + tie-break cố định; đưa score sang Rust và trả qua JSON để Swift chỉ hiển thị. | High |
| **S5** | Medium | `service.rs:1797-1812`, `378`, `492-497` | Cooldown chỉ 2 phút cho cả source và target, không có minimum dwell. Với 3 account A/B/C luân phiên cạn nhanh, có thể ping-pong A→B→C→A mỗi ~2–3 phút; mỗi lần là 1 lần quit/relaunch Desktop. `last_auto_switch_at` lấy `now` **trước** activation (có thể kéo dài vài giây) ⇒ cooldown thực ngắn hơn khai báo. | Dwell tối thiểu (10–15 phút) theo account + ghi thời điểm **sau** activation thành công; cooldown tăng theo số lần switch trong 1h (exponential backoff). | Medium |
| **S6** | Medium | `service.rs:320-358`, `1660-1677` | Nhánh banked reset: nếu active có banked ⇒ báo active; nếu không, chọn candidate exhausted có `banked_reset_count > 0`, sort **chỉ theo count** (`341`). Bỏ qua `expires_at` ⇒ có thể đề xuất account có credit hết hạn sau 1h thay vì account có credit hạn 20 ngày. | Rank theo `min(expires_at)` (sớm nhất trước) rồi count; hiển thị hạn cho user. Xem U4. | High |
| **S7** | Medium | `service.rs:899-912` | `restore_snapshot_with_retry` xong nhưng `sync_activated_account` fail ⇒ trả `Err` dù `~/.codex` đã đổi account. `apply` return sớm ⇒ không ghi `last_auto_switch_*`, không `mark_activated`, không `take_pending_continue_hint` ⇒ auto-resume mất cho lần switch đó, worker log "failed" dù thực tế đã switch. | Tách "credential switch result" khỏi "bookkeeping result": vẫn trả `switched` kèm `warnings` (pattern đã làm cho provider ở `provider_auto_switch.rs:487-512`). | High |
| **S8** | Low | `service.rs:207`, `387`, `1103` (`let _ = self.usage(..)`) | Lỗi probe live bị nuốt; decide không phân biệt "probe fail, dùng cache cũ" với "probe OK". Không có field `stale` trong `AutoSwitchOutput`. | Thêm `probe: ok` / `failed` / `skipped` + `cache_age_secs` vào output; log/UI hiển thị. | High |
| **S9** | Medium | `service.rs:1544-1553`, `204-232`; `provider_auto_switch.rs:110-127` | Trigger của Codex chỉ duy nhất `remaining <= 1` (reactive): turn đang chạy mới bị chặn rồi mới switch, không có ngưỡng chủ động/hysteresis như nhánh Claude (threshold 95%, hysteresis 10, cooldown 5 phút). → Trải nghiệm lỗi turn là *đầu vào* của cơ chế. | Thêm threshold/hysteresis cho Codex (U2), mặc định off / 5%. | High |
| **S10** | Low | `auto_switch_monitor.rs:14-19`, `70-96`; `AccountStore.swift:480-482`, `461-482` | `AUTO_SWITCH_EXHAUSTED_BACKOFF_SECONDS == AUTO_SWITCH_POLL_SECONDS` (45) ⇒ nhánh "backoff" không có tác dụng. GUI poll 10s khi 0% và spawn process CLI mỗi lần, worker 45s chạy song song ⇒ 2 vòng decide độc lập (dù serialize bằng `AutoSwitchLock`), mỗi vòng đều probe live + candidate. | Hợp nhất một scheduler; nếu giữ 2, cho CLI trả `next_poll_ms` (server-driven cadence) và GUI tôn trọng. | High |

### C. Concurrency, lock, locking granularity

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| **C1** | High | `session_resume.rs:101-107`, `138-160`, `163-181` (`load_index`→`save_index` không lock); gọi ở `service.rs:482-486`, `507-512`; đối thủ `mark_activated`/`capture_for_account` dưới `AuthLock`+`OperationLock` (`service.rs:851-866`, `952`) | Worker auto-switch gọi `capture_pending_continue` (read-modify-write `session-resume.json`) **không lock** trong khi GUI/CLI khác đang `activate` (giữ 2 lock khác) và gọi `mark_activated`/`capture_for_account` trên cùng file. Ghi đan xen ⇒ mất `pending_continues` ⇒ switch thành công nhưng **không resume** thread vừa bị chặn; hoặc mất `activated_at` ⇒ capture sau đó gán sai rollout của account khác (đúng loại lỗi mà `ACTIVATED_GRACE` cố chặn). | Acquire `OperationLock` trong mọi đường ghi index này (hoặc lock riêng `session-resume.lock`); coi `pending_continues` là dữ liệu one-shot cần bảo vệ. | High |
| **C2** | Medium | `quota_history.rs:53-62` (`tmp` cố định + rename), `80-106` (RMW), `108-130` (read mà **có ghi**); `service.rs:1114-1130`; writer dưới lock ở `repository.rs:584-592` | GUI gọi `quota-history` (không lock) đọc file, prune, **save** ⇒ ghi đè sample vừa được worker thêm. Hai writer dùng cùng `quota-history-v1.json.tmp` ⇒ có thể rename file dở. → Mất điểm sparkline ngẫu nhiên. | Dùng `replace_file_with_recovery` + tmp theo UUID + `OperationLock`; `load_samples` không nên ghi. | High |
| **C3** | Medium | `service.rs:195-201` (lock cho mỗi lần gọi decide hoặc apply), `369-375` (apply không lấy lại lock mà dựa vào kế thừa ở `195`), `870-880` (expected-active check) | Decide và apply là **hai transaction** dưới cùng lock nhưng lock được nhả giữa hai bước. Nếu process khác switch trong khoảng đó, apply fail với `"automatic switch was superseded…"` (Err) và worker coi là lỗi thay vì decide lại. Cửa sổ thực tế ngắn (GUI quit Desktop ~1–3s nằm **trong** khoảng này!). | Giữ lock xuyên decide→apply (hoặc token lease `switch_txn_id` ghi xuống đĩa); khi bị superseded ⇒ trả `retry` chứ không `Err`. | High |
| **C4** | Low | `service.rs:1892-1903` (`recent_usage_error_skips_probe`) + `repository.rs:620` (`updated_at`) + `626-643` (label/archive cũng set `updated_at`) | `updated_at` vừa là "thời điểm lỗi" vừa là "thời điểm sửa metadata". User đổi label/archive một account đang lỗi 403 ⇒ backoff 10 phút bị **reset**, probe lại ngay; ngược lại account lỗi từ 20 phút trước vừa được relabel ⇒ bị coi là lỗi mới ⇒ bỏ probe 10 phút. | Thêm `last_usage_error_at` riêng (migration `#[serde(default)]`). | High |
| **C5** | Low | `operation_lock.rs:14` (`ACQUIRE_TIMEOUT=90s`), `60-83`; `service.rs:237-286` | Decide giữ `AutoSwitchLock` trong lúc probe N candidate: mỗi candidate có thể = decrypt Keychain + 2 request × timeout 5s ⇒ N=10 có thể >90s. Process thứ hai (GUI) chờ lock rồi fail timeout → hiển thị lỗi generic dù chỉ là chậm. | Timeout theo ước lượng công việc (N×2×5s) hoặc trả `busy` thay vì `error`; ưu tiên probe song song có giới hạn (xem U5). | Medium |

### D. Reset tracker & notification

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| **R1** | Medium | `reset_tracker.rs:622-628`, `693-713` | Sắp xếp/truncate theo **so sánh chuỗi RFC3339** (`announced_at`). Feed trộn offset (`Z` vs `+07:00`) ⇒ thứ tự không phải thứ tự thời gian ⇒ `truncate(MAX_SEEN_EVENT_IDS)` có thể bỏ event mới hơn, và `record_seen_event_ids` giữ nhầm id ⇒ thông báo trễ/mất. | Parse sang `OffsetDateTime` rồi mới sort/truncate (đã có `parse_event_time`). | High |
| **R2** | Low | `reset_tracker.rs:715-719` | State ghi bằng `fs::write` (không atomic, không recovery) ⇒ crash giữa chừng ⇒ JSON hỏng ⇒ `existing = None` ⇒ coi như lần đầu ⇒ **replay** 1 event gần nhất (thông báo trùng). | Dùng `replace_file_with_recovery` như `settings.rs`/`session_resume.rs`. | High |
| **R3** | Low | `reset_tracker.rs:655-663`, `678-691` | Cửa sổ dedupe `announced_at >= initialized_at`: nếu đồng hồ máy bị chỉnh **lùi** (NTP/DST thủ công), event đã công bố có timestamp < `initialized_at` bị loại **vĩnh viễn** chứ không chỉ trễ; cửa sổ rate-limit 1h cũng dựa trên `now` nên có thể reset sớm. | Dùng `>= initialized_at - 6h` cho lần poll đầu sau skew, hoặc lưu watermark `max(announced_at đã thấy)`. | Medium |
| **R4** | Low | `reset_tracker.rs:37`, `102`, `149-156` | `cadence_days` (`avg_interval_days`) và `next_reset_at` của feed bên thứ ba được trình bày như dữ kiện, không có confidence/interval; không có per-account probability (đúng chủ đích — test `reset_tracker.rs:827-834` khẳng định không có key xác suất). | Giữ nguyên việc **không** bịa xác suất; nếu hiển thị cadence, nhãn "ước tính từ feed bên thứ ba" + ngày cập nhật. | High |

### E. Session continuity (Rust vs Swift)

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| **P1** | Medium | `session_resume.rs:379-448` (query **không** LIMIT/recency filter), `465-495` (đọc tail 512KB + fallback đọc **toàn bộ** file), gọi từ `service.rs:44-64` → `codex_activity.rs:168-178` | `status()` (notch/CLI poll vài giây/lần) đi qua activity strip ⇒ `discover_interrupted_sessions` mở **mọi** thread chưa archive trong `state_5.sqlite`, đọc ≥512KB mỗi rollout (thậm chí toàn file nếu tail không có lifecycle event). 2000 thread ⇒ GB đọc mỗi lần poll; cũng là chi phí trong `capture_pending_continue`. | Lọc SQL theo `COALESCE(recency_at_ms, updated_at_ms) >= now−6h`, `LIMIT 50`; chỉ đọc tail 64–128KB; cache `(path, size, digest)`→state để không parse lại; tách `waiting` khỏi `status` (chỉ tính khi mở panel). | High |
| **P2** | Low `[inference]` | `session_resume.rs:36`, `396-413`, `641-681` | Thư mục `sessions/YYYY/MM/DD` được Codex tạo theo **ngày local**, app suy ra theo `OffsetDateTime::now_utc().date()`. Fallback chỉ quét `0..=1` ngày quanh UTC date nên phủ được ±1 ngày; nếu lệch ≥2 ngày (TZ +14/−12 cộng DST) hoặc clock lệch, discovery bỏ sót ngày hiện tại. Swift dùng `Calendar.current` (`AccountStore.swift:209-236`). | Dùng local date (hoặc quét cả `now±1` local **và** UTC) trong cả 3 chỗ; thêm test với clock cố định ở UTC+14. | Medium |
| **P3** | Low | `session_resume.rs:304-321` | `rollout_exists` mặc định `true` khi `rollout_path = None` ⇒ nhánh cuối trả `status="ready"` dù không có bằng chứng rollout tồn tại (chỉ có session_id). Swift sẽ thử deep-link và fail. | Yêu cầu `rollout_path.is_some()` cho `ready`; nếu không ⇒ `ready_cli`. | High |
| **P4** | Medium | `session_resume.rs:212-231` vs `SessionResumeBatch.swift:20-21`; `codex_activity.rs:18` (`45s`) vs `AccountStore.swift:200` (`20s`); `CodexResumePolicy.swift:10-22` | Dedupe theo id làm 2 lần (Rust + Swift), cửa sổ "recently continued" ở Swift nhưng không có ở Rust; ngưỡng idle 45s vs 20s; "what needs continue" chỉ ở Rust, "queue ownership" chỉ ở Swift. Thay đổi policy phải sửa 2 nơi, không có test chéo. | Đưa toàn bộ policy sang Rust, expose `status` per-thread (`interrupted` / `completed` / `running`, `idle_secs`); Swift chỉ render + enqueue. | High |
| **P5** | Low | `session_resume.rs:163-181` | `take_pending_continue_hint(enabled=false)` vẫn `take()` rồi trả `None` ⇒ tắt auto-resume lúc switch làm mất queue; bật lại sau không resume được. | Khi `!enabled`, **không** consume (hoặc consume và lưu `deferred_until`). | High |

### F. Token usage / cost

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| **T1** | Medium | `token_usage.rs:15` (version), `73-75`, `188-204` (`utc_offset_seconds` trong cache key), `351` (key `by_day` là ngày theo offset) | Mỗi lần DST/TZ đổi, `utc_offset_seconds` khác ⇒ **invalidate toàn bộ cache** ⇒ đọc lại mọi rollout từ đầu (với kho lớn: vài trăm MB) — đúng nhưng đắt; đồng thời number liệu ngày cũ được tính lại theo offset mới (không nhất quán lịch sử). | Lưu `by_day` theo **UTC date**; group theo offset tại thời điểm query; chỉ cần bump version khi đổi logic, không khi đổi TZ. | High |
| **T2** | Medium | `token_usage.rs:299-341` | Dedupe bằng `previous_signature == (last.tokens, total.tokens)`: nếu hai turn liên tiếp có cùng `last_token_usage` và `total_token_usage` (payload thiếu `total`, hoặc total bị reset) thì turn thứ hai bị **bỏ** ⇒ under-count. Ngược lại nếu `total` luôn đổi thì đúng. | Dedupe bằng `(line_offset, signature)`; chỉ coi là duplicate khi cùng record; với trường hợp thiếu total dùng timestamp strictly increasing. | Medium |
| **T3** | Medium | `token_usage.rs:594-674`, `676-684`, `15` | Bảng giá match bằng substring: `contains("sol")`, `contains("gpt-5")` trước `mini`, `contains("opus")`; model lạ rơi vào default 2.5/10 ⇒ **sai giá âm thầm**. `CACHE_VERSION` thủ công nên đổi bảng giá mà quên bump ⇒ cost cũ vẫn nằm trong cache (`by_day_cost`, `by_model` đã merge). | Bảng giá khai báo (model → rate + effective_from) thay vì substring; hash bảng giá vào cache version để tự invalidate; test cho từng nhánh. | High |
| **T4** | Low | `token_usage.rs:104-108`, `352-353`, `139-142` | `estimated_cost_usd` = Σ per-model (f64) trong khi daily = Σ per-event f64 ⇒ hai tổng khác nhau ở mức 1e-12 nhưng vẫn là 2 nguồn; `day_costs` chỉ cộng ngày có trong `by_day_cost`. | Một nguồn duy nhất: tính cost theo event rồi derive mọi aggregate; assertion tolerance trong test. | High |
| **T5** | Low | `token_usage.rs:86-116`; `534-539` | Cache key = path tương đối; file chuyển `sessions/` ↔ `archived_sessions/` mất state tăng dần (recount, không double count). `cache_hit_percent` min(100) che định nghĩa >100% và trả 0 khi `input_tokens=0` (không phân biệt "không có dữ liệu"). | Key theo `(file_name, session_id)`; phân biệt `None` vs `0%.` | Low |

### G. Chất lượng test & khả năng kiểm chứng

| ID | Mức | Vị trí (file:line) | Trigger → Tác động | Đề xuất | Confidence |
|---|---|---|---|---|---|
| **X1** | Medium | 146 chỗ `OffsetDateTime::now_utc()` (≈70 trong test). Fixture mẫu luôn đặt `reset_at: now`: `service.rs:2580`, `2645-2649`, `2739-2743`, `2800-2804` | Mọi test auto-switch mã hoá "reset đã xảy ra" là trạng thái **bình thường**; do đó fix Q1 (coi `reset_at <= now` là stale) sẽ làm đỏ hàng chục test — dấu hiệu invariant đúng chưa hề được mã hoá. Không có test nào cho "window đã trượt nhưng percent còn cao". | Thêm `fn window(remaining, reset_in: Duration, now)` chuẩn hoá mọi fixture; test mới cho `reset_at` quá khứ (pass/fail theo Q1). | High |
| **X2** | Medium | `service.rs:235`, `378` (decide/apply tự đọc clock); `session_resume.rs:414` (`SystemTime::now()`); `token_usage` nhận `now` (tốt); `codex_activity.rs:137` | Không inject được clock vào `App`/decide/apply/session_resume ⇒ test tích hợp bắt buộc dùng thời gian thật ⇒ flaky khi chạy quanh biên (00:00 local, reset_at ≈ now) và không test được "sau 15 phút". | `trait Clock { fn now(&self) -> OffsetDateTime }` (SystemClock/ManualClock) trong `App`; `decide_auto_switch(now)`; `session_resume(..., now: SystemTime)`. | High |
| **X3** | Medium | `session_resume.rs:786` (`sleep 20ms` để tách mtime); `Cargo.toml` không có `proptest`/`cargo-fuzz` | Test phụ thuộc mtime granularity; không có property/fuzz cho 2 parser nguy hiểm nhất (`UsageResponse::from_value`, `token_usage` JSONL) và cho ranking. | Bỏ sleep bằng `filetime_set` (đã dùng ở `session_resume.rs:836`); thêm `proptest` cho: `remaining = 100−used`, `is_usable ⇒ ∀window !depleted`, score monotone, parser không panic với JSON tuỳ ý. | High |
| **X4** | Low | `usage.rs:1228-1281` (`prove_saved_session_refresh`, `refresh_snapshot_if_access_token_stale`) — **không có caller production** (grep chỉ thấy test + comment ở `service.rs:1248`) | Bộ test xanh (1612–1767) chứng minh hành vi "refresh AT khi restore" **không được nối vào** activation (`service.rs:881-907` restore nguyên snapshot). Người đọc dễ tin là activation refresh token. | Hoặc wire vào activation (dưới AuthLock, chỉ khi AT sắp hết hạn), hoặc xoá + xoá test để tránh false confidence. | High |

### Bảng edge case bắt buộc (đối chiếu nhanh)

**1. Missing/partial/null windows**

| Payload | Parse ra | Hành vi hiện tại | Đúng? |
|---|---|---|---|
| `primary_window: null`, weekly 90% | `five_hour=None` | candidate **eligible** (Q3) | ✗ |
| `primary_window: {used_percent: 0}` (thiếu reset_at) | `five_hour=None` | eligible, không có tín hiệu thiếu dữ liệu | ✗ |
| `weekly: {used_percent: "high"}` | `weekly=None` | visible test `usage.rs:1794-1812`; active ⇒ có thể `active_has_quota` sai | ~ |
| `rate_limit: "garbage"` | cả 2 `None` | active ⇒ `active_has_quota`; candidate ⇒ không usable | ~ |
| `reset_at: 0` | 1970 | window "hết hạn" theo display, nhưng percent vẫn được dùng để quyết định (Q1) | ✗ |
| `used_percent: 150` | 150 | `remaining=0`, hiển thị "150% đã dùng" (Q8) | ✗ |
| `available_count: "many"` | `banked_resets=None` | im lặng bỏ; không ảnh hưởng switch | ✓ |

**2. Biên thời gian**

| Tình huống | Kết quả hiện tại | Ghi chú |
|---|---|---|
| `reset_at == now` (đúng giây) | display "reset passed"; decision vẫn dùng percent cũ | Q1; ranh giới `<=` vs `<` không nhất quán giữa các module |
| `reset_at = now+1s`, cache age 14m59s | coi là fresh ⇒ quyết định trên dữ liệu sắp chết | Q1 |
| Cache exhausted age 9m59s + reset vừa xảy ra | bỏ probe | Q2 |
| Decide xong, Desktop quit 2s, active vừa reset | apply probe lại (cache >20s) ⇒ `active_has_quota`, hủy switch | ✓ đúng (chống switch thừa) |
| Switch thành công ở T, T+2m01s active lại cạn | A/B hết cooldown ⇒ có thể switch ngược | S5 |
| DST: `reset_at` sau 1h đồng hồ nhảy | `format_local_reset_at` dùng offset **tại reset instant** ⇒ đúng | ✓ (giữ nguyên) |
| 23:30 local (UTC+7), rollout hôm nay | discovery fallback `0..=1` quanh UTC date ⇒ phủ | ~ P2 |

**3. Concurrency**

| Hai tác nhân | Cơ chế hiện tại | Khe hở |
|---|---|---|
| GUI decide / worker decide | `AutoSwitchLock` (`service.rs:195`) | ✓ serialize (nhưng timeout 90s, C5) |
| decide ↔ apply | lock nhả giữa 2 bước | C3 |
| GUI apply ↔ worker apply | `AutoSwitchLock` + expected-active | ✓ |
| `activate` ↔ `refresh usage` | `AuthLock` | ✓ (refresh giữ lock qua HTTP 5s+5s) |
| `activate` ↔ `capture_pending_continue` | không lock chung | **C1** |
| `quota-history` read ↔ record | không lock | **C2** |
| reset notification (GUI + worker) | không lock, ghi đè state | R2 |

---

## Đề xuất thuật toán nâng cấp

Mỗi mục: **What/Why** → **How (công thức/pseudo)** → **Effort / Impact / Risk** → **cách validate offline**.

### U1. Burn-rate EWMA + "time-to-empty" có khoảng tin cậy (5h và weekly)

**What/Why:** Hiện chỉ có trạng thái nhị phân "còn quota / cạn" và trigger ở ≤1% (S9). Với dữ liệu đã có sẵn — `quota_history` ghi sample mỗi 5 phút/account (`quota_history.rs:17-20`) — ta dự báo được *khi nào* cạn và *có kịp turn tiếp theo không*, biến auto-switch từ reactive thành predictive.

**How:**

```
Với mỗi account + window (5h, weekly):
  samples = quota_history.samples (lọc window hiện hành: reset_at > now)
  r_i = (used_i - used_{i-1}) / Δt_i        # %/phút, bỏ Δt < 60s, bỏ r_i < 0 (reset)
  b_t = α·r_t + (1-α)·b_{t-1},  α = 0.3     # EWMA mức tiêu thụ (≈ nửa đời 2 sample)
  σ²_t = α·(r_t - b_t)² + (1-α)·σ²_{t-1}, α_var = 0.2
  TTE  = remaining / b_t                     # phút
  CI95: tổng phương sai xấp xỉ  TTE²·σ²/b² ⇒ [TTE·(1-1.96·cv), TTE·(1+1.96·cv)], cv=σ/b
  confidence = high nếu n_samples ≥ 4 và cv ≤ 0.35 và age(sample cuối) ≤ 10 phút
  # fallback khi chưa đủ sample: dùng provider::pace::compute_pace(used, reset_at, fetched_at, period)
```
5h dùng period 5h, weekly dùng period 7 ngày (hiện `compute_pace` chỉ áp cho `seven_day*`, `claude.rs:687-706` — cần generalize cho `five_hour` với `SUPPRESS_AFTER_RESET` riêng, vì 24h suppress không hợp lệ với window 5h).

**Hiển thị:** "5h: còn 8% · cạn sau ~22 phút (CI 14–35)". Guard chia 0: `b_t < 0.01` ⇒ TTE = ∞, confidence low.

**Effort M · Impact High** (nền tảng cho U2/U3; user thấy trước khi bị chặn) · **Risk Low** (read-only, chỉ hiển thị ở bước 1) · **Validate:** replay fixture `quota-history-v1.json` tổng hợp; metric MAE của `TTE` so với thời điểm cạn thật (từ payload `reset_at` + `remaining` kế tiếp); bootstrap 500 traces synthetic.

### U2. Threshold + hysteresis + dwell cho Codex path (parity với nhánh Claude)

**What/Why:** Nhánh Claude đã có `threshold/hysteresis/cooldown/strategy` (`provider_auto_switch.rs:103-182`, `settings.rs:27-37`) nhưng Codex thì không. Sao chép *mô hình quyết định*, không sao chép hằng số.

**How:**
```
trigger =
  AtLimit      nếu remaining_5h <= 1                          # như hiện tại
  Proactive    nếu remaining_5h <= T_low (mặc định 5)
               và remaining_weekly >= W_floor (mặc định 20)
               và idle (không có rollout write trong 20s)
  else None
chặn nếu: now - last_switch < D (dwell, mặc định 10 phút)
candidate hợp lệ nếu: score(candidate) >= score(active) + H (H = 15)
cooldown per-account: 15 phút, tăng gấp đôi mỗi switch trong 1h (tối đa 1h)
```
Lý do có `W_floor`: không "đốt" account có weekly thấp chỉ vì 5h sắp cạn; lý do `idle`: turn đang chạy không thể switch (process scan sẽ chặn, S1).

**Effort S/M · Impact High** (giảm failed turn) · **Risk Medium** (switch sớm đốt quota account khác) ⇒ mặc định **off**, expose 4 setting + màn hình giải thích · **Validate:** U8 simulation; A/B trên fixture lịch sử 2 tuần của user (replay: với mỗi quyết định thật, so sánh "switch tại threshold" vs "switch tại 0%" theo số turn lỗi và số lần switch).

### U3. Thời điểm switch tối ưu (cost-aware)

**What/Why:** Switch có chi phí: quit/relaunch Desktop (~5–15s), mất focus, đôi khi clear web session (`AccountStore.swift:2629-2646`). Đáng switch *sớm* nếu xác suất hỏng turn tiếp theo đủ lớn.

**How:**
```
τ = EWMA thời lượng turn (từ timestamp event trong rollout, U1; mặc định 6 phút)
P_fail = 1 - exp(-TTE_5h / τ)                 # xấp xỉ exponential cho "turn vắt qua mốc cạn"
c  = chi phí switch chuẩn hoá (1 đơn vị ≈ 10s gián đoạn)
p  = thiệt hại 1 turn hỏng (mất context + retry) ≈ 8–10·c
switch nếu P_fail > c / (c + p)   ⇔  TTE < τ · ln(1 + p/c) ≈ 2.3τ
```
Ví dụ τ=6 phút ⇒ switch khi 5h còn < ~14 phút *và* account hiện tại đang idle; kết hợp `R = remaining/total` để tránh switch khi vừa reset.

**Effort M/L · Impact High** · **Risk Medium** (cần τ ổn định) · **Validate:** U8 với phân bố turn log-normal; so sánh policy ngưỡng cố định vs cost-aware theo metric "gián đoạn/tuần" và "% turn lỗi".

### U4. EV cho banked reset (redeem ngay vs giữ) + rank theo hạn

**What/Why:** Hiện chỉ đếm credit, không dùng `expires_at` (Q6/S6). Credit là tài nguyên có hạn sử dụng — cần mô hình quyết định đơn giản nhưng đúng hướng.

**How:**
```
V_credit = 100% của binding window (5h và/hoặc weekly)
value_if_redeem_now = fraction_remaining_of_window        # 0..1, = remaining_natural / 100
   (nếu window tự reset trong 30 phút thì redeem gần như vô giá trị)
expected_usage_horizon H (EWMA: số giờ dùng/tuần / 7)
Δ = thời gian tới natural reset gần nhất
hold_value = clamp(Δ / H, 0, 1)                            # cơ hội dùng credit sau
redeem_now nếu: exhausted
             và ( expires_at - now < 48h           # sắp mất
                    hoặc value_if_redeem_now >= 0.5   # window còn dài
                    hoặc Δ >= H )                     # tự reset còn xa
rank nhiều account có credit: sort theo (expires_at sớm nhất, -count)
```
**Effort S** (rank theo expiry) → **M** (EV + hiển thị lý do) · **Impact Medium** (tránh mất credit) · **Risk Low** (không tự redeem — chỉ tư vấn) · **Validate:** bảng fixture 6 kịch bản (credit hết hạn 1h/20 ngày, window vừa/vừa lâu reset) + unit test decision table.

### U5. Candidate scoring v2 + single source of truth

**What/Why:** `switch_quota_score` hiện chỉ 2 chiều (S4) và Swift tự thêm boost (drift). Cần score integer xác định, nhiều yếu tố, và **chỉ tính ở Rust**.

**How:**
```
score = 1000·weekly + 5h                        # lexicographic giữ nguyên
      + plan_bonus        # Pro: +15, Plus: +5, khác: 0  (xét theo usage.plan_label)
      + reset_bonus       # weekly.reset_at - now <= 24h  ⇒ +10   (khớp boost của Swift)
      + freshness_penalty # age > 10 phút ⇒ −20 (proxy "có thể đã cũ")
      + banked_bonus      # có credit redeem được ⇒ +5
tie-break: (score desc, plan_rank asc, last_activated_at asc, id asc) — deterministic
```
Trả `switch: {eligible, score, score_breakdown, reason}` trong `list --json`/`status --json`; Swift bỏ `switchQuotaScore`, chỉ sort theo field này.

**Effort M · Impact High** (chọn tốt hơn + hết drift) · **Risk Low** (thuần so sánh) · **Validate:** property test "score không đổi khi tăng weekly", "depleted luôn −1"; golden file 30 roster snapshot + expected ranking; diff ranking Rust vs Swift trước/sau (kỳ vọng = 0).

### U6. Saga switch có trạng thái bền (idempotent, crash-safe)

**What/Why:** decide→apply là 2 transaction (C3), GUI và worker có thể cùng lái, crash giữa quit-Desktop và activate để lại session nửa vời. `active_since/activated_at` + `restore` rollback đã có nhưng không có "intent" bền.

**How:**
```
$APP_DATA/switch-txn.json { txn_id, from_id, to_id, phase, started_at, attempt }
phase: decided → captured → auth_swapped → verified → done | rolled_back
Mỗi poll: nếu có txn chưa done và age < 5 phút ⇒ resume theo phase (idempotent):
  captured      ⇒ bỏ qua capture, sang activate
  auth_swapped  ⇒ verify live identity == to_id; nếu không ⇒ rollback về from snapshot (roster) + phase=rolled_back
  verified      ⇒ chỉ ghi bookkeeping + resume hint
Xoá txn sau done; qúa 5 phút ⇒ coi là stale, không switch lại cùng cặp.
```
**Effort M · Impact High** (hết double-switch/mid-flight mất resume) · **Risk Medium** (thêm state phải migration/xoá đúng) · **Validate:** fault-injection test tại từng phase (drop file, kill giữa chừng bằng fixture `phase`), property "resume 2 lần = 1 lần".

### U7. Deterministic replay + property/invariant fuzz cho quota & ranking

**What/Why:** Không có proptest/fuzz (X3); các predicate là pure nên rất dễ test nếu tách I/O ra.

**How:**
- Tách `fn decide(active: &AccountUsageView, candidates: &[AccountView], settings: &Settings, now: OffsetDateTime) -> Decision` (pure, không network/lock) — `decide_auto_switch` chỉ còn phần fetch/persist.
- Fixture JSONL: `{"now": "...", "active": {...}, "accounts": [...], "settings": {...}, "expected": "ready|no_candidate|...", "candidate": "..."}`; replay = table-driven test.
- `proptest` invariants:
  - `∀ w: used ∈ 0..=100 ⇒ remaining(w) == 100-used`
  - `is_usable(usage) ⇒ ∀ reported window !depleted`
  - `weekly1 > weekly2 ⇒ score(w1) > score(w2)` khi cùng 5h và cùng plan
  - `decide != Switch` khi `is_usable(active)`
  - `parse(arbitrary_json)` không panic, không trả `Some(window)` với `used > 100`
- `cargo-fuzz` target cho `UsageResponse::from_value` + `continuation_state` (JSONL line).

**Effort S/M · Impact High** (chặn regression Q1/Q3/Q4) · **Risk Low** · **Validate:** CI chạy `proptest` 1k case/target và replay golden corpus.

### U8. Simulation harness (synthetic traces) để tune threshold

**What/Why:** Mọi ngưỡng mới (U2/U3/U4) cần dữ liệu để chọn, không thể đo trên account thật (task cấm).

**How:** binary `#[cfg(test)]` hoặc `src/bin/quota-sim.rs`:
```
accounts: N=2..8, plan ∈ {Plus, Pro}
burn: Poisson(λ(t)) với λ(t) = λ0 · diurnal(t) · burst(user activity)
windows: 5h rolling + weekly fixed reset (UTC), reset khi đạt, credit banked ngẫu nhiên + expiry
switch: cost c ~ N(10s, 3s), có thể fail với xác suất p_proc
policy: enum {Reactive, Threshold(T,H,D), CostAware(τ)}  (gọi cùng `decide` pure của U7)
metric: failed_turns/ngày, switches/ngày, gián đoạn(giây)/ngày, % thời gian không dùng được account tốt
grid search T ∈ {1,3,5,10}, H ∈ {5,10,20}, D ∈ {5,10,20} ⇒ Pareto front
```
**Effort M · Impact High** (chọn hằng số có cơ sở, hồi quy được) · **Risk None** (offline) · **Validate:** chạy 200 seed, báo cáo mean±CI; snapshot kết quả vào docs.

### U9. Clock injection + xoá flakiness

**What/Why:** X1/X2 — ~70 chỗ `now_utc()` trong test, không injectable, fixture "reset_at = now".

**How:**
```rust
trait Clock: Send + Sync { fn now(&self) -> OffsetDateTime; }
struct SystemClock; struct ManualClock(AtomicI64);
App::with_clock(env, repo, Arc<dyn Clock>)
fn decide_auto_switch(&self, now: OffsetDateTime, enabled: bool)
fn discover_interrupted_sessions(root: &Path, now: SystemTime)
// test helper
fn window(remaining: u8, reset_in: time::Duration, now: OffsetDateTime) -> UsageWindowView
```
Thay `thread::sleep` bằng `filetime_set` (đã có pattern) và `ManualClock::advance`.

**Effort M · Impact High** (test Q1/Q2/Q3 được, hết biên giờ) · **Risk Low** · **Validate:** suite hiện tại pass với ManualClock; thêm test "sau 15m01s cache không còn fresh".

### U10. Idle/turn-activity một nguồn

**What/Why:** Rust 45s (`codex_activity.rs:18`), Swift 20s (`AccountStore.swift:200`), Rust worker không có turn gate (chỉ process gate ⇒ S1). Ba định nghĩa "đang bận".

**How:** `codex_activity::is_turn_active(codex_root, now, quiet=20s)` (dùng DB `recency_at_ms` thay vì walk dir — rẻ hơn P1), expose `activity: {turn_active, last_write_at, quiet_secs}` vào `status --json`; Rust decide dùng nó để trả `waiting_for_turn` (mới) thay vì `ready`; Swift chỉ đọc.

**Effort S · Impact Medium** · **Risk Low** · **Validate:** fixture mtime cố định; test 3 trạng thái; test "decide không ready khi turn_active".

### U11. Cửa sổ dự báo thay cho hằng số backoff (retry planner)

**What/Why:** Q2 + S10: 10 phút/45s là hằng số không liên hệ với `reset_at`.

**How:**
```
next_probe_at(account) = min(
    fetched_at + 15m,                        # freshness
    min(reset_at(window)) + 5s,              # ngay sau reset
    now + backoff(n),                        # n = consecutive failures: 60s·2^(n-1) cap 15m
)
worker sleep = clamp(min over accounts next_probe_at - now, 15s, 120s)
```
**Effort S · Impact High** (hết Q2, hết poll thừa) · **Risk Low** · **Validate:** unit test cho bảng transition; property "không probe trước next_probe_at".

---

## Quick wins (≤1 ngày)

| # | Việc | File:line | Fixes |
|---|---|---|---|
| 1 | Helper `window_is_current(w, now) = w.reset_at > now`; coi window quá hạn là unknown trong `is_usable_for_switch`, `is_exhausted_for_switch`, `cached_usage_is_fresh`, `switch_quota_score` | `service.rs:1555-1593`, `1775-1795`, `1859-1873` | Q1, Q2 (phần "window đã trượt") |
| 2 | Vô hiệu `exhausted_cached_usage_skips_probe` khi có window `reset_at <= now` (hoặc tính `next_retry_at` từ `reset_at`) | `service.rs:1883-1890` | Q2 |
| 3 | Eligibility yêu cầu 5h known-usable (trừ credits); thêm `windows_known` vào `AccountUsageView` | `service.rs:1569-1593`, `model.rs:453-476` | Q3 |
| 4 | Status mới `usage_unknown` thay cho `active_has_quota` khi active không có usage | `service.rs:223-232` | S2 |
| 5 | Lọc `expires_at > now` trong `banked_reset_count` + `effective_banked_available_count`; rank fallback theo expiry | `service.rs:1644-1658`, `usage.rs:698-704` | Q6, S6 |
| 6 | Acquire `OperationLock` trong `capture_pending_continue`/`take_pending_continue_hint`/`mark_activated` | `session_resume.rs:101-181`, `service.rs:482-512` | C1 |
| 7 | `quota_history`: `replace_file_with_recovery` + tmp UUID + `OperationLock`; `load_samples` không ghi | `quota_history.rs:53-130` | C2 |
| 8 | Preflight CLI blockers **trước** khi trả `ready` (trả `waiting_for_processes`) | `service.rs:305-318` | S1 |
| 9 | TUI/CLI dùng `display remaining` (0% khi depleted) | `tui.rs:351`, `cli.rs:1231` | Q7 |
| 10 | Sort reset events bằng `parse_event_time` thay vì so chuỗi; ghi state bằng `replace_file_with_recovery` | `reset_tracker.rs:622-628`, `715-719` | R1, R2 |
| 11 | `plan_for_auto_switch`: đã tốt — chỉ thêm test khẳng định roster label không dùng khi có usage | `service.rs:1699-1730` | — |

---

## Điểm đang tốt — giữ nguyên

1. **`EXHAUSTED_REMAINING_PERCENT = 1`** (`service.rs:1544-1553`): đúng với floor phía server; mirrored sang Swift kèm comment (`AccountStore.swift:5112-5117`). Đừng đổi thành 0.
2. **Banked reset không bao giờ tự redeem và không tự switch vào account còn cạn** — trạng thái `banked_reset_available` riêng, message rõ (`service.rs:320-358`). Đây là quyết định sản phẩm đúng (credit là hành động của user).
3. **Free/Go bị loại khỏi auto-switch, label rỗng cũng coi là Free** (`service.rs:1691-1730`): chặn downgrade âm thầm.
4. **Expected-active re-check + `activate_if_active_matches`** (`service.rs:836-880`): chống lost-update ở bước cuối; kết hợp `AutoSwitchLock` là mô hình khoá đúng.
5. **`restore_snapshot_with_retry` có backup + rollback + verify stable** (`codex.rs:440-510`): mid-switch failure không để auth nửa vời.
6. **Single-use RT được serialize** bởi `AuthLock` + `TOKEN_REFRESH_LOCK` (`usage.rs:30`, `operation_lock.rs:30-44`); deferred-AT design (`usage_error_is_deferred_access_token_refresh`) tránh đốt RT — đúng hướng "session longevity".
7. **Tolerant parsing** `UsageResponse::from_value` (`usage.rs:336-375`): một block hỏng không xoá phần còn lại; có test cho malformed/missing (`usage.rs:1794-1835`).
8. **`credits.balance = ""` nghĩa là "không đọc được", không phải 0** (`model.rs:683-689`, `usage.rs:1042-1066`): phân biệt rất tốt.
9. **`provider/pace.rs::compute_pace`** (`pace.rs:12-79`): công thức đúng, kể cả `rem_euclid` cho reset quá khứ và `SUPPRESS_AFTER_RESET`; có test cho stale reset — nên tái dùng cho Codex (U1).
10. **`time_display::format_local_reset_at`** dùng offset **tại thời điểm reset** (`time_display.rs:3-9`): xử lý DST đúng kiểu (không dùng offset hiện tại).
11. **reset_tracker**: partial-feed không ghi đè state (`reset_tracker.rs:603-676`), bound `MAX_SEEN_EVENT_IDS`/`MAX_NOTIFICATIONS_PER_HOUR`, URL allowlist (`trusted_https_url`), và **chủ động không bịa xác suất** (test khẳng định không có `chance_24_hours`).
12. **test đặt tên như invariant** (`auto_switch_requires_every_reported_window_to_be_usable`, `floored_ninety_nine_percent_window_counts_as_exhausted`, `auto_switch_treats_credits_as_remaining_quota`): tài sản lớn — chỉ cần bổ sung ca "window đã trượt" và "window thiếu".
13. **`token_usage` cache increment**: cursor + length + mtime + prefix hash + rebuild khi truncate (`token_usage.rs:254-376`), có test cho append/truncate/prefix — thiết kế tốt, chỉ cần sửa offset-key (T1).
14. **`file_store::replace_file_with_recovery`** + recovery tiers (`index_store.rs:214-289`): nền tảng đúng cho mọi state file; các file **chưa** dùng (quota-history, reset notification, session-resume) nên được đưa vào.

---

## Giả định & giới hạn kiểm chứng

1. **Không chạy test/build** (theo yêu cầu của Lead: tránh tranh `target/` và baseline đã có). Toàn bộ kết luận là static analysis + đọc test; không có số đo CPU/RSS/độ trễ, không có kết quả `cargo test` mới.
2. **Không gọi network, không Keychain, không đụng `~/.codex`**. Mọi kết luận về payload API (`primary_window`/`secondary_window`, `reset_at` đơn vị giây, 99 = blocked) dựa trên code + test + comment, **không** xác minh với API thật. Chưa xác minh được liệu API có trường độ dài window (việc map cứng primary=5h, secondary=weekly là *giả định* di truyền từ v0.4; nếu OpenAI đổi ngữ nghĩa, nhãn sẽ sai — chưa có cảnh báo trong code).
3. **Line number** ứng với commit `8f27e8c`; các file Swift đọc ở mức policy, không đọc toàn bộ 5000+ LOC của `AccountStore.swift`.
4. **Reachability của S1/S2** phụ thuộc môi trường (có Codex CLI đang chạy; access token live hết hạn). Đã chỉ ra chuỗi caller cụ thể nhưng chưa dựng được repro do cấm mutate. Mức confidence ghi trong từng dòng.
5. **Mọi so sánh "Rust vs Swift"** là đọc code, không phải chạy app; offset/line của Swift có thể lệch nếu build configuration `#if` khác.
6. **Feature `external-providers`**: các file `provider_auto_switch.rs`/`claude.rs`/`pace.rs` chỉ biên dịch khi bật feature (mặc định **tắt**, `Cargo.toml:15-17`). Các phát hiện liên quan được dùng làm **đối chứng thiết kế** (Claude có threshold/hysteresis, Codex không) và làm nguồn cho U1/U2, không phải bug đang chạy trong bản default.
7. **Không đánh giá UX copy/notification cuối cùng**, chỉ logic dẫn tới trạng thái. Các phát hiện perf chỉ nêu khi chúng là hệ quả của lựa chọn *thuật toán* (P1, S10, C5), không phải audit hiệu năng đầy đủ.
8. **Không xét tính đúng của bảng giá** (giá model thay đổi theo thời gian, không thể verify offline); chỉ nêu rủi ro cấu trúc (T3).

---

*Hết báo cáo. File read-only ngoại trừ tài liệu này. Không sửa source, không commit.*
