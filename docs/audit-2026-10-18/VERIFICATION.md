# Independent verification — Codex Roster audit implementation

Ngày: 2026-10-18 · Nhánh: `main` · Người chạy: Lead (không phải tác giả của từng thay đổi riêng lẻ)
Mục đích: kiểm chứng lại các tuyên bố trong [IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md) bằng lệnh chạy thật, trên cây làm việc sạch.

## 1. Gate đầy đủ (chạy trên `main`, cây sạch)

| Lệnh | Kết quả |
|---|---|
| `cargo fmt --check` | PASS |
| `bash scripts/check-auth-switch-safety.sh` | PASS — `Auth switch safety checks passed.` (sau khi sửa, xem §3) |
| `cargo clippy --locked --all-targets --all-features -- -D warnings` | PASS — **0 warning/error** |
| `cargo test --locked --all-features` | **454 passed, 0 failed, 2 ignored** |
| `cargo test` (mặc định) | **452 passed, 0 failed, 2 ignored** |
| `swift build --package-path macos/NextAccount` | PASS — `Build complete!` |
| `bash scripts/build-macos-app.sh` | PASS — bundle `build/CodexRoster.app` được build + ký (ad-hoc) |

Ghi chú: 2 test `ignored` là harness mô phỏng tuning (chạy bằng `--ignored --nocapture`) và một test có sẵn từ trước.

## 2. Kiểm chứng hợp đồng Rust ↔ Swift bằng dữ liệu thật

Không chỉ đọc code: `quota-forecast --json` được xuất từ binary thật rồi decode bằng một chương trình Swift **độc lập** (chỉ chứa struct `Decodable` + `JSONDecoder` với `convertFromSnakeCase`, mô phỏng đúng cách app decode):

```
$ ./target/debug/codex-roster quota-forecast --json > /tmp/forecast.json
$ swiftc -o /tmp/decode_check /tmp/decode_check.swift && /tmp/decode_check
decoded ok: account=6650CC28 fiveHour=true weekly=false
five_hour: remaining=0.0% burn=0.4062199319107247 tte=0.0 confidence=low samples=47
```

Lần chạy đầu **thất bại** (`DecodingError … Path: generatedAt`) và đó là một phát hiện thật: `QuotaForecastOutput.generated_at` vẫn serialize theo mảng 9 số trong khi các view khác đã dùng RFC3339. Đã sửa (`#[serde(with = "time::serde::rfc3339")]`, cùng `ProviderAccountView`) rồi chạy lại — PASS. `RustDate` trong app vẫn đọc được cả hai dạng nên không có rủi ro hồi quy.

## 3. Vấn đề phát hiện trong lúc verification và đã sửa

`scripts/check-auth-switch-safety.sh` **fail** trên `main`: *"Expected exactly two guarded macOS --force append sites; found 6."*
Nguyên nhân: script đếm mọi lần xuất hiện chuỗi `--force` trong mã Swift, nhưng 4 lần mới là **chuỗi thông báo hướng dẫn người dùng** (được thêm khi bản địa hoá lỗi guard ở vòng 1), không phải site thêm cờ. Đã sửa script để đếm đúng `append("--force")` (vẫn giữ nguyên bất biến: đúng 2 site và cả hai phải có guard `forceDesktop`/`didCloseDesktop`). Sau khi sửa: PASS.

Đây là ví dụ cho thấy gate CI của repo bắt được thay đổi ngoài dự kiến — nếu không chạy script này, một gate CI sẽ đỏ trên `main`.

## 4. Rà 29 điểm then chốt của audit so với code hiện tại

Script grep theo từng tuyên bố; **29/29 PASS**. Nhóm theo báo cáo gốc:

- **P0 activation guard (lỗi người dùng báo)**: `BlockKind` phân loại process; holder scan fail-closed (`HolderScan::Unknown`); message máy đọc được `activation_blocked_by_cli:`; `decide` trả `waiting_for_processes`; app dịch lỗi + nút copy details.
- **Auto-resume (R)**: `SessionResumeLock` (khoá xuyên process); scan rollout có giới hạn (`ROLLOUT_TAIL_BYTES`, `ROLLOUT_MAX_SCAN_BYTES`).
- **Quota decision (A1)**: `window_is_current` được dùng trong predicate; `has_current_five_hour_window` chặn account thiếu cửa sổ 5h; banked credit hết hạn bị loại (`expires_at.is_none_or`).
- **Storage/HTTP (A2)**: `atomic_write` + `sync_all` cho credential; cap body feed (`MAX_FEED_BYTES`).
- **CLI/TUI (A3)**: `is_quit_key` (Ctrl-C/Esc/q); guard non-TTY (`stdin().is_terminal()`); `CONTRACT_VERSION`; `doctor`/`schema`.
- **Thuật toán (E2)**: `forecast_window` (EWMA); `switch_score_breakdown`; `switch_txn` (saga + reconcile); `next_probe_seconds_for_active`.
- **Swift UX (B)**: `requestDelete`/`confirmPendingDelete`; hover `.open` không activate; `refreshPublicDataPassively`; vòng thông báo 15s; `installStatusItem` + `⌘,`; chip archived + `pendingUpdateInstall`; `statusOK` (role màu ngữ nghĩa); `QuotaFreshnessLabel`.

## 4b. Vòng rà bổ sung (vòng 9–10)

Rà lại 24 điểm then chốt sau các vòng CLI/TUI, housekeeping và B còn lại: **24/24 PASS**. Bổ sung vào danh sách §4: `list --all` + giờ reset theo múi giờ máy; TUI search/paging (`first_matching_label`); cap config/response VibeCafe (`MAX_CONFIG_BYTES`); cap `preserved-metadata-*`; dọn thư mục staging (`.cas-*`); check `account_list_backup` trong `doctor`; forecast hiển thị trong deck; toast feedback; loading gate (`hasLoadedAccounts`).

**Rà i18n:** quét toàn bộ literal trong `macos/NextAccount/Sources/NextAccount/*.swift` không đi qua `language.text`/`AppLanguage.text` với ngữ cảnh hiển thị (`Text(`, `errorMessage`, `title:`, `help:`, `accessibilityLabel`, `.failed(`) — **0 chuỗi tiếng Anh lộ** (2 hit còn lại là tên riêng attribution: "Pimpmuckl / codex-account-switcher", "Ducksss / codex-profiles"). Vậy hạng mục I18N-1 đã xử lý xong trong phạm vi audit yêu cầu.

## 5. Giới hạn của lần verification này (đọc kỹ)

- **Chưa chạy GUI thật.** Mọi kết luận về UI dựa trên `swift build` + đọc code; chưa thao tác notch/console trên app đang chạy. Vì vậy các claim "hiển thị đúng", "VoiceOver đọc đúng", "màu đạt WCAG AA" là **suy luận từ code**, chưa đo bằng công cụ.
- **`swift test` không chạy được trên máy này** (CLT-only, `no such module 'Testing'`); bộ test Swift chỉ được CI chạy trên `macos-latest`.
- **Không có test nào chạm Keychain, OAuth thật, hay `~/.codex`**; các đường đó được kiểm chứng bằng code + test với fixture.
- **Khoá `session-resume.json`** được test bằng nhiều luồng, chưa test bằng hai process thật.
- **Saga switch** có test module đầy đủ nhưng **chưa có integration test cho một lần apply thành công** đầu-cuối.
- **Số liệu tuning trong ALGORITHM-TUNING.md là mô phỏng**, không phải đo trên máy thật.
- Verification do **cùng một tác nhân** thực hiện (Lead), không phải bên thứ ba độc lập; đây là mức kiểm chứng tốt nhất có thể trong điều kiện toàn bộ provider agent (Orca) đều cạn quota.

## 6. Hạng mục audit còn lại (chưa triển khai)

Xem bảng "Còn lại" trong [IMPLEMENTATION-STATUS.md](IMPLEMENTATION-STATUS.md). Tóm tắt: phần B còn lại (Light Mode cho vài sheet, i18n leaks sót, empty-state loading gate), A2 phần phụ (cảnh báo backup vào JSON `warnings[]`, cap `preserved-metadata-*`, dọn `.cas-*`), A3 `list` human + TUI search, và F/G wave 2 đầy đủ (HUD/dự báo nâng cao/gợi ý + review độc lập bởi agent khác).
