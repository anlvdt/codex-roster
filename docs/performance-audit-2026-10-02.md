# AgentDock — audit hiệu năng, 02/10/2026

## Phạm vi và bằng chứng

Đọc luồng SwiftUI/AppKit notch, hai roster, lịch refresh/auto-switch/thông báo,
CLI subprocess và các đường login/update. Lấy hai mẫu `sample` 5 giây khi
notch thu gọn, kiểm tra giao diện trực tiếp bằng accessibility sau khi cài bản mới.
Không có phép đo frame-time/FPS hoặc benchmark với hàng trăm tài khoản.

## Các vấn đề đã sửa

| Vấn đề | Bằng chứng | Thay đổi |
| --- | --- | --- |
| Ghi trạng thái thông báo không đổi mỗi 2 giây | Mẫu trước có `showOpenAIIncidentIfNeeded → saveSignalState → JSONEncoder` và UserDefaults | Thoát sớm khi indicator không thay đổi; vẫn ghi khi chuyển sang sự cố hoặc phục hồi |
| Refresh do mở lại trang Claude | `onAppear → claudeTabDidAppear` chạy list, auto-switch status, quota, auto-switch status trên mỗi lần mount | Cooldown monotonic 60 giây cho refresh thụ động; refresh nút bấm và monitor định kỳ tiếp tục hoạt động |
| Refresh provider status lặp giữa các cửa sổ/trang | Bốn nơi gọi refresh thụ động cùng một store | Gộp yêu cầu thụ động trong 60 giây; guard in-flight vẫn giữ nguyên |
| AppKit đưa notch lên trước khi quota publish | `configureWindow` gọi `orderFrontRegardless` sau mỗi update | Chỉ đưa lên trước khi mới gắn window hoặc window chưa hiện; resize vẫn chỉ khi frame đổi |
| Roster ẩn vẫn nằm trong cây view | Panel mở rộng trước đây chỉ opacity 0 khi thu gọn | Giữ qua fade 120 ms, tháo nội dung sau 130 ms khi đóng; chỉ còn compact telemetry |
| Notch luôn đọc quota Codex | Xác nhận bản cũ đang trang Claude 68%/32% nhưng compact đọc Codex | Snapshot theo trang đang chọn; Claude dùng five_hour/seven_day, đúng reset; không mang banked reset hoặc quota Codex sang Claude |

## Kết quả đo và giới hạn

- Trước: CPU tại thời điểm `ps` 0.0%, RSS 106.1 MiB; physical footprint trong
  sample 49.5 MB, peak 117.0 MB.
- Sau khi mở/chuyển cả hai trang rồi đóng: CPU tại thời điểm `ps` 0.0%, RSS
  126.5 MiB; physical footprint 52.0 MB, peak 129.6 MB.
- Hai vòng sử dụng khác nhau, allocator/AppKit có thể giữ cache; số liệu này
  **chưa chứng minh RAM giảm**. Không dùng chúng để công bố % tăng tốc.
- Mẫu sau không còn stack `saveSignalState` ở lượt kiểm tra indicator không đổi.
  Giảm công việc nền được chứng minh bằng guard nguồn và mẫu profiler; hai
  sample ngắn không đủ kết luận năng lượng hoặc CPU dài hạn.
- Bundle 19 MB, ZIP 7.2 MB (số làm tròn của `du`).
- UI đã xác minh Claude 68%/32% và Codex 50%/45%, cả khi mở và thu gọn.
  Quota tiếp tục cập nhật nên các giá trị này chỉ là ảnh chụp thời điểm kiểm tra.

## Những điểm đã kiểm tra, chưa đổi kiến trúc

- CLI I/O chạy trên global queue, stdout/stderr được drain đồng thời; không
  chuyển subprocess vào main thread. Decode JSON vẫn cần profiling với dữ liệu
  lớn trước khi chuyển actor hay thêm Sendable constraints.
- Animation notch dùng opacity/offset 120–140 ms; AppKit không resize nội suy.
  Reduce Motion vẫn được tôn trọng.
- Roster Codex có các phím số gắn với card, nên đổi tất cả sang lazy layout cần
  chuyển đăng ký shortcut ra ngoài card và kiểm tra cuộn/nhóm. Chưa đổi mù quáng.
- Các kiểm tra quota/auto-switch/reset vẫn có nhịp hiện tại để giữ độ trễ phục
  hồi. Chưa tăng poll interval toàn cục chỉ để cải thiện số liệu lúc nghỉ.
- Mạng, auth, login và cập nhật ứng dụng cần đo tình huống riêng; audit này
  không tuyên bố loại bỏ mọi hang trong những luồng đó.

## Xác minh giao hàng

4 test tập trung qua: cooldown và clock rollback; map quota/reset Claude; no-data
không fallback provider; layout status rows. Test dùng package tạm symlink nguồn
vì test target toàn repo đang có lỗi actor isolation ở test updater từ trước.
Release Swift/Rust build, ZIP, codesign và SHA-256 ba binary installed đều hợp lệ.
Bản đang chạy đã thay tại `MyApps/codex-roster/build/AgentDock.app`, bản trước giữ
ở `AgentDock.backup-e7615024.app`.

GitNexus impact từng bề mặt sửa: LOW hoặc UNKNOWN (đã đối chiếu nơi gọi bằng
source). Detect-changes trên toàn working tree báo CRITICAL, 26 file / 227 symbol /
30 flow; đây là tổng các thay đổi tích lũy cả login, quota, resume và branding từ
những yêu cầu trước, không phải riêng đợt tối ưu này. Không commit hoặc xóa các
thay đổi tích lũy.
