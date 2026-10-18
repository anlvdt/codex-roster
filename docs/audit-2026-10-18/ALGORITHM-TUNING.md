# Algorithm tuning — Codex Roster (2026-10-18)

Tài liệu này ghi lại các thuật toán đã triển khai cho auto-switch, cách chọn tham số, và **giới hạn của bằng chứng**.
Mọi con số trong bảng §3 là **mô phỏng**, không phải đo trên máy thật.

## 1. Đã triển khai

| Thuật toán | Vị trí | Ghi chú |
|---|---|---|
| Burn-rate forecast EWMA + CI95 | `src/forecast.rs`, lệnh `quota-forecast` | Lọc mẫu theo cửa sổ hiện tại, bỏ delta âm (reset) và mẫu quá gần; `b_t = α·r_t + (1-α)·b_{t-1}` (α=0.3), variance EWMA α=0.2; `TTE = remaining / b_t`; CI95 = `TTE·(1 ± 1.96·cv)`; confidence theo số mẫu, `cv`, tuổi mẫu |
| Candidate scoring v2 | `switch_score_breakdown`, `compare_candidates` trong `src/app/service.rs` | `score = 1000·weekly + five + plan_bonus + reset_bonus − freshness_penalty + banked_bonus`; Pro +15, Plus +5; weekly reset <24h +10; cache >10 phút −20; banked reset +5 |
| Tie-break tất định | `compare_candidates` | `(score desc, plan_rank desc, last_activated_at asc, id asc)` — thứ tự không đổi giữa các lần chạy |
| Proactive threshold + dwell + weekly floor | `proactive_switch_allowed`, `dwell_satisfied`, `src/settings.rs` | Mặc định **tắt**; khi bật: 5h ≤ 5%, weekly ≥ 20%, account idle (không ghi rollout ~20s), dwell ≥ 10 phút |
| Dwell cho cả đường reactive | `decide` → status `waiting_for_dwell` | Chặn A→B→C→A thrash; thay cho cooldown 2 phút chỉ áp cho cặp from/target |

Tham số mặc định (additive, có thể đổi trong settings):

| Tham số | Mặc định | Vì sao |
|---|---|---|
| `auto_switch_proactive` | `false` | Hành vi cũ giữ nguyên cho tới khi người dùng bật |
| `auto_switch_threshold_percent` | `5` | Mô phỏng §3: 5–15% đều cho 0 turn lỗi với cùng số lần switch |
| `auto_switch_hysteresis_percent` | `15` | Target phải còn ≥15% headroom, tránh nhảy sang account gần cạn |
| `auto_switch_dwell_minutes` | `10` | Đủ dài để cắt thrash, đủ ngắn để không bỏ đói người dùng |
| `auto_switch_weekly_floor_percent` | `20` | Không đánh đổi weekly window chỉ để cứu 5h window |

## 2. Công thức forecast

Với chuỗi mẫu `(minute, used%)` trong cửa sổ hiện tại:

```
Δt = minute_i − minute_{i−1}                (bỏ nếu Δt < 1 phút)
r_i = (used_i − used_{i−1}) / Δt            (bỏ nếu < 0 — đó là reset)
b_t = 0.3·r_t + 0.7·b_{t−1}
v_t = 0.2·(r_t − b_{t−1})² + 0.8·v_{t−1}
TTE = remaining / b_t                       (None nếu b_t < 0.01 %/phút)
CI95 = TTE · (1 ± 1.96·σ/b_t), σ = √v
confidence = high  nếu #mẫu ≥ 4, cv ≤ 0.35, mẫu mới nhất ≤ 10 phút
           = medium nếu #mẫu ≥ 2, cv ≤ 0.60, mẫu mới nhất ≤ 30 phút
           = low   còn lại
```

Test bao phủ: burn đều (rate ~0.2%/phút, TTE ~100 phút, CI bao quanh ước lượng, confidence high), burn giật (CI rộng hơn TTE), reset giữa chuỗi (không làm rate âm/phồng), một mẫu (low, không có TTE), burn bằng 0 (không có TTE), mẫu ngoài cửa sổ (bị bỏ), fixture hồi quy TTE ~200 phút.

## 3. Mô phỏng: Reactive vs Threshold — **số liệu mô phỏng**

Harness: `cargo test simulate_reactive -- --ignored --nocapture` (`src/forecast.rs`).
Mô hình: 1 ngày = 1440 phút, 3 account, mỗi account 5h=100% và weekly=100%; mỗi phút "đang làm việc" với xác suất 0.8 và tiêu thụ 0.15–0.30%/phút (LCG có seed cố định, 5 seed: 1, 7, 42, 1234, 98765); switch tốn 8s, một turn lỗi tốn 25s; **cả hai policy dùng chung dwell 10 phút**; policy reactive chỉ switch **sau khi một turn đã lỗi**.

| Policy | Turn lỗi/ngày | Switch/ngày | Gián đoạn (s/ngày) |
|---|---|---|---|
| reactive (0%) | **2.0** | 2.0 | **66.0** |
| threshold 5% | 0.0 | 2.0 | 16.0 |
| threshold 10% | 0.0 | 2.0 | 16.0 |
| threshold 15% | 0.0 | 2.0 | 16.0 |
| threshold 20% | 0.0 | 7.6 | 60.8 |

Đọc bảng: ngưỡng 5–15% loại bỏ turn lỗi mà **không tăng số lần switch** so với reactive, và giảm gián đoạn ~50s/ngày. Ngưỡng 20% chỉ tăng switch (7.6 lần/ngày) mà không giảm thêm turn lỗi → không chọn.

**Giới hạn của mô hình (đọc kỹ trước khi trích dẫn):**
- Là mô phỏng tổng hợp, **không phải đo trên máy thật**; không có dữ liệu người dùng thật.
- Chỉ 1 ngày, 3 account; không mô hình hoá weekly window cạn dần qua nhiều ngày, reset tự nhiên, banked reset, hay độ trễ mạng khi switch.
- Thời lượng turn và chi phí switch là hằng số giả định (25s/8s), không đo.
- Kết luận "5–15% tương đương nhau" đúng trong mô hình này; trên tải thật có thể khác.

## 4. Còn lại

- **Durable switch saga (U6)**: chưa triển khai. Hiện tại đường apply vẫn là tuần tự (capture hint → activate → bookkeeping) với `warnings` khi bước sau lỗi (audit S7), chưa có file `switch-txn.json` với phase/rollback. Đây là hạng mục P2 còn lại.
- Harness chưa mô hình hoá nhiều ngày/tuần và chưa so sánh policy có hysteresis khác nhau.
