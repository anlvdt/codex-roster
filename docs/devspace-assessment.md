# Deep Research: Có nên áp dụng DevSpace vào Codex Roster?

Ngày đánh giá: 30/08/2026

DevSpace được kiểm tra tại commit [`e4ef989`](https://github.com/Waishnav/devspace/tree/e4ef98997aa82a7a59fd0a820809409337cd8bce).

## Kết luận

**Không dùng DevSpace để thay thế ChatGPT Web for Codex.** Hai hệ thống có hướng hoạt động ngược nhau:

| | ChatGPT Web for Codex đã gỡ | DevSpace |
| --- | --- | --- |
| Mục tiêu | Đưa model từ phiên ChatGPT Web vào route Codex local | Cho ChatGPT/MCP client truy cập repo và terminal local |
| Gắn với account Roster | Có, từng browser profile/account | Không |
| Gắn với quota/switch account | Có | Không |
| Giao thức chính | Browser automation + local service | Remote MCP qua HTTPS/OAuth |
| Quyền trên máy | Browser session riêng | File tools trong allowlist, nhưng shell có toàn quyền của user local |

DevSpace tự mô tả là một MCP server tự host để ChatGPT đọc/sửa repo và chạy terminal local; tool surface mặc định gồm `open_workspace`, `read`, `apply_patch`, `exec_command`, `write_stdin`, `show_changes`. Đây là một sản phẩm “ChatGPT điều khiển máy local”, không phải model provider cho Codex. [README](https://github.com/Waishnav/devspace), [cấu hình tool surface](https://github.com/Waishnav/devspace/blob/e4ef98997aa82a7a59fd0a820809409337cd8bce/docs/configuration.md)

## Phần có thể áp dụng

Có thể áp dụng DevSpace sau này như **một tích hợp tùy chọn, độc lập** trong Codex Roster:

1. Card “DevSpace connector” chỉ hiển thị trạng thái, chạy `devspace doctor`, mở setup và start/stop theo yêu cầu rõ ràng của người dùng.
2. Giữ toàn bộ config và OAuth secret trong `~/.devspace`; Roster không đọc hay sao chép Owner password.
3. Cho người dùng chọn allowlist repo hẹp, hiển thị cảnh báo shell không sandbox, và không tự bật cùng hệ thống.
4. Không liên kết lifecycle DevSpace với switch account, quota, hoặc relaunch ChatGPT/Codex Desktop.
5. Chưa quản lý tunnel trong giai đoạn đầu; DevSpace hiện yêu cầu người dùng tự cung cấp public HTTPS tunnel/reverse proxy. [Security Model](https://github.com/Waishnav/devspace/blob/e4ef98997aa82a7a59fd0a820809409337cd8bce/docs/security.md)

Về pháp lý, repo dùng MIT nên có thể tích hợp hoặc sửa mã, với điều kiện giữ copyright/license notice khi sao chép phần đáng kể. [LICENSE](https://github.com/Waishnav/devspace/blob/e4ef98997aa82a7a59fd0a820809409337cd8bce/LICENSE)

## Vì sao chưa nên nhúng ngay

- **Ranh giới sản phẩm không khớp:** Codex Roster quản lý account/quota/session; DevSpace là remote coding gateway.
- **Rủi ro quyền truy cập cao:** DevSpace ghi rõ file tools bị giới hạn bởi workspace, nhưng shell command chạy với toàn quyền user local. Worktree chỉ là ranh giới workflow, không phải security boundary. [Security Model](https://github.com/Waishnav/devspace/blob/e4ef98997aa82a7a59fd0a820809409337cd8bce/docs/security.md)
- **Phụ thuộc nặng:** bản `1.0.8` yêu cầu Node `>=22.19 <27`, npm, Git và Bash; native PowerShell/cmd chưa được hỗ trợ. Điều này không khớp hoàn toàn với ứng dụng Windows native của Roster. [package.json](https://github.com/Waishnav/devspace/blob/e4ef98997aa82a7a59fd0a820809409337cd8bce/package.json), [README](https://github.com/Waishnav/devspace)
- **Tín hiệu supply-chain cần xử lý:** kiểm tra local ngày 30/08/2026 bằng `npm audit --omit=dev` trên lockfile của commit trên báo 12 package records có advisory, gồm 4 mức high. Đây là tín hiệu triage, không phải kết luận rằng DevSpace đang bị khai thác.
- **Độ bền môi trường:** typecheck pass. Test suite ban đầu fail trên macOS/Node 26.7.0 do Unix socket path trong thư mục tạm quá dài; chạy lại với `TMPDIR=/tmp` thì pass. Cần CI rõ ràng cho toàn bộ dải Node được công bố hỗ trợ.

OpenAI Docs xác nhận ChatGPT/Codex có thể kết nối remote MCP và khuyến nghị OAuth, nhưng cũng cảnh báo custom MCP có thể nhận dữ liệu nhạy cảm, prompt injection có thể dẫn đến hành động ngoài ý muốn, và write actions cần được xem xét cẩn thận. Điều này ủng hộ kiến trúc DevSpace về mặt giao thức, nhưng không phải sự chứng thực cho repo bên thứ ba. [Official OpenAI MCP documentation](https://developers.openai.com/api/docs/mcp)

## Security gate trước khi cân nhắc ship

- Không còn advisory production mức high chưa triage.
- `devspace doctor`, typecheck và test pass trên Node 22/24/26, macOS và Windows + Git Bash/WSL.
- Threat model riêng cho tunnel, OAuth token, prompt injection và shell không sandbox.
- UI bắt buộc giải thích quyền truy cập trước khi start; không auto-start mặc định.
- Allowed roots hẹp; không cho phép `~`, `/` hoặc `C:\` làm mặc định.
- Roster chỉ quản lý process/status, không giữ OAuth secret và không tự tạo tunnel.

## Trạng thái gỡ bỏ trong Codex Roster

Subsystem ChatGPT Web for Codex và tích hợp Codex Router đã được loại khỏi module Rust, CLI command, Swift store/card, auto-sync hooks, asset đăng nhập, bước đóng gói macOS và README. Các chức năng quản lý ChatGPT/Codex Desktop, quota và account switching không bị thay đổi.

Kiểm chứng:

- `cargo test`: 162/162 pass.
- `swift build --package-path macos/NextAccount`: pass.
- `cargo run --quiet -- --help`: không còn command `chat-gpt-web`.
- Tìm toàn repo: không còn symbol/URL/asset của ChatGPT Web for Codex.
- `swift test` chưa chạy được vì toolchain hiện tại thiếu module `Testing`; app target vẫn compile thành công.
- `cargo fmt --check` còn báo formatting có sẵn ở `reset_tracker.rs` và hai dòng CLI ngoài phạm vi; không tự sửa để tránh chạm mã không liên quan.

## Quyết định đề xuất

1. Giữ thay đổi hiện tại: gỡ hoàn toàn ChatGPT Web for Codex.
2. Không đưa DevSpace vào cùng PR/thay đổi này.
3. Nếu cần workflow ChatGPT Web điều khiển repo local, thử DevSpace như một công cụ cài ngoài trước.
4. Chỉ mở feature “DevSpace connector” trong Roster sau khi các security gate trên đạt.
