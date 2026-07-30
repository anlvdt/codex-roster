# Codex Roster

Native macOS account roster, quota monitor, and safe switcher for OpenAI / Codex.

[English](#english) · [Tiếng Việt](#tiếng-việt)

> Codex Roster is local-first. It manages only the Codex authentication files already present on your Mac. It is not affiliated with OpenAI.

## English

### What it does

- Save, label, archive, restore, and safely switch OpenAI / Codex account snapshots.
- Show the active account's quota in the menu bar and account quota/reset state in the sidebar.
- Launch the OpenAI device sign-in flow without reading passwords, verification codes, or browser cookies.
- Close and relaunch ChatGPT/Codex Desktop after a confirmed account switch.
- Refresh local Codex token statistics, public OpenAI Status, and the optional Codex Reset community outlook.
- Offer Vietnamese and English; Vietnamese is the default.

### Quota and automatic switching

`GPT Free`, `GPT Plus`, and `GPT Pro` identify the ChatGPT plan. They do not imply a fixed Codex quota. Codex Roster displays the quota/reset windows returned for the signed-in account.

**Auto-switch when quota is exhausted** is opt-in. It checks the active account, refreshes candidate quota, and switches only when the active account is at `0%` and another saved account has usable quota in every reported window. If every account is exhausted, it leaves ChatGPT untouched.

### Backup and recovery

- **File → Export backup…** creates a password-encrypted `.codexroster` file for transfer or off-device storage. The password is never stored by the app.
- The app automatically retains the latest five full local snapshot backups. They are encrypted with a random key held in this Mac's Keychain, so they can restore saved sessions on this same Mac.
- Use **Automation → Restore saved sessions** after local data loss. This replaces the current roster after confirmation.

Never share a snapshot file, password, browser cookie, access token, or refresh token.

### Install and run

Download the latest macOS ZIP from [Releases](https://github.com/anlvdt/codex-roster/releases), unzip it, and move **Codex Roster.app** to Applications. macOS may require you to approve the first launch because the application is independently distributed.

Build locally:

```sh
zsh scripts/build-macos-app.sh
open "build/Codex Roster.app"
```

### CLI

The app bundles `codex-roster`. For development, set `CODEX_ROSTER_CLI_PATH` to another build.

```text
codex-roster status [--json]
codex-roster list [--json]
codex-roster save [--json]
codex-roster usage [ACCOUNT_ID] [--json]
codex-roster activate [ACCOUNT_ID] [--force] [--json]
codex-roster delete [ACCOUNT_ID] [--json]
codex-roster archive ACCOUNT_ID [--restore] [--json]
codex-roster export OUTPUT.codexroster [--password-stdin] [--json]
codex-roster import INPUT.codexroster [--password-stdin] [--json]
codex-roster restore-full-backup [--json]
codex-roster auto-start-usage-windows [--enable|--disable] [--run] [--json]
codex-roster token-usage [--json]
codex-roster reset-outlook [--json]
codex-roster open-ai-status [--json]
```

### Privacy, status, and credits

Saved account data remains on this Mac. The OpenAI Status and Codex Reset requests are public service/forecast lookups; neither receives account credentials. Read [OpenAI's current ChatGPT and Codex pricing documentation](https://learn.chatgpt.com/docs/pricing) for plan and usage policy.

Codex Roster is MIT licensed. It is maintained by [LE AN (@anlvdt)](https://github.com/anlvdt). See [AUTHORS.md](AUTHORS.md) and [CREDITS.md](CREDITS.md) for original-foundation, research, and license attribution.

### Validation

```sh
cargo test
cargo clippy -- -D warnings
cargo fmt --check
swift build --package-path macos/NextAccount
```

## Tiếng Việt

### Ứng dụng làm gì

- Lưu, đặt tên, lưu trữ, khôi phục và chuyển an toàn các phiên tài khoản OpenAI / Codex.
- Hiển thị quota tài khoản đang dùng trên menu bar; hiển thị quota và thời điểm reset ở sidebar.
- Mở luồng đăng nhập thiết bị OpenAI mà không đọc mật khẩu, mã xác thực hay cookie trình duyệt.
- Đóng rồi mở lại ChatGPT/Codex Desktop sau khi bạn xác nhận chuyển tài khoản.
- Theo dõi token Codex cục bộ, trạng thái công khai OpenAI và dự báo cộng đồng Codex Reset.
- Hỗ trợ Tiếng Việt và English; mặc định là Tiếng Việt.

### Quota và tự động chuyển

`GPT Free`, `GPT Plus`, `GPT Pro` là nhãn gói ChatGPT, không phải quota Codex cố định. Codex Roster hiển thị quota/thời điểm reset thực tế được trả về cho tài khoản đang đăng nhập.

Chế độ **Tự động chuyển khi hết quota** là tùy chọn. Ứng dụng chỉ chuyển khi tài khoản hiện tại còn `0%`, đã làm mới quota tài khoản dự phòng và tài khoản đó còn quota ở mọi cửa sổ được trả về. Nếu mọi tài khoản đều hết quota, ChatGPT không bị đóng hay chuyển vòng lặp.

### Sao lưu và khôi phục

- **Tệp → Xuất bản sao lưu…** tạo file `.codexroster` được mã hóa bằng mật khẩu để chuyển máy hoặc lưu trữ ngoài máy. App không lưu mật khẩu này.
- Ứng dụng tự giữ năm bản sao đầy đủ gần nhất trên máy. Chúng được mã hóa bằng khóa ngẫu nhiên trong Keychain của máy Mac này, vì vậy có thể khôi phục lại phiên đã lưu trên chính máy đó.
- Dùng **Tự động hóa → Khôi phục phiên sao lưu** khi dữ liệu cục bộ gặp lỗi. Thao tác sẽ yêu cầu xác nhận trước khi thay roster hiện tại.

Không gửi file snapshot, mật khẩu backup, cookie trình duyệt, access token hay refresh token cho bất kỳ ai.

### Cài đặt và chạy

Tải ZIP macOS mới nhất từ [Releases](https://github.com/anlvdt/codex-roster/releases), giải nén rồi kéo **Codex Roster.app** vào Applications. Lần mở đầu, macOS có thể yêu cầu bạn cho phép vì ứng dụng được phát hành độc lập.

Tự build:

```sh
zsh scripts/build-macos-app.sh
open "build/Codex Roster.app"
```

### Riêng tư, trạng thái và ghi nhận

Dữ liệu tài khoản lưu trên máy Mac. Các yêu cầu tới OpenAI Status và Codex Reset chỉ lấy trạng thái/dự báo công khai, không gửi thông tin đăng nhập. Xem [tài liệu pricing và usage chính thức của ChatGPT/Codex](https://learn.chatgpt.com/docs/pricing) để biết chính sách gói và quota mới nhất.

Codex Roster dùng giấy phép MIT, được duy trì bởi [LE AN (@anlvdt)](https://github.com/anlvdt). Xem [AUTHORS.md](AUTHORS.md) và [CREDITS.md](CREDITS.md) để biết ghi nhận tác giả, nguồn tham khảo và ranh giới giấy phép.
