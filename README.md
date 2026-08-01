# Codex Roster

Native macOS account roster, quota monitor, and safe switcher for OpenAI / Codex. A native Windows Preview is now in development.

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

**Auto-switch when quota is exhausted** is opt-in and shared by the macOS and Windows clients. It refreshes the active account and every candidate, then switches only when the active account is at `0%` and another saved account has usable quota in every reported window. It never chooses cached or stale candidate quota. The switch is deferred while Codex or ChatGPT is still running; automatic mode does not force-quit applications. If every account is exhausted, it leaves the current session untouched.

### Backup and recovery

- **File → Export backup…** creates a password-encrypted `.codexroster` file for transfer or off-device storage. The password is never stored by the app.
- The app automatically retains the latest five full local snapshot backups. They are encrypted with a random key held in this Mac's Keychain, so they can restore saved sessions on this same Mac.
- Use **Automation → Restore saved sessions** after local data loss. This replaces the current roster after confirmation.

#### macOS Keychain prompt

macOS may show a dialog such as:

> `codex-roster` / `Codex Roster` / `codex_roster-<hash>` wants to use your confidential information stored in **"com.codexroster.app"** in your keychain.

That is expected. Codex Roster keeps only a local encryption key for saved snapshots and automatic backups in the Keychain item `com.codexroster.app`. The helper CLI inside the app (and local `cargo test` / `cargo run` binaries, which may appear as `codex_roster-<hash>`) must read that item to decrypt sessions on this Mac. The dialog is from macOS, not a third-party login page.

- Choose **Allow** or **Always Allow** after confirming the Keychain item name is `com.codexroster.app`.
- **Deny** leaves saved sessions/backups encrypted and unreadable until access is granted.
- Codex Roster never asks for your OpenAI password through this dialog; enter your Mac login Keychain password only if macOS requests it.

Never share a snapshot file, password, browser cookie, access token, or refresh token.

### Install and run

Download the latest macOS ZIP from [Releases](https://github.com/anlvdt/codex-roster/releases), unzip it, and move **Codex Roster.app** to Applications. macOS may require you to approve the first launch because the application is independently distributed.

Build locally:

```sh
zsh scripts/build-macos-app.sh
open "build/Codex Roster.app"
```

### Windows Preview

The Windows shell uses **WinUI 3** and calls the same Rust CLI; see [windows/README.md](windows/README.md). It can monitor quota and safely auto-switch only after Codex is closed; it does not force-close or relaunch Codex automatically. It currently targets real-device testing, not public production use.

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
codex-roster auto-switch [--enable|--disable|--status|--apply] [--json]
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

Chế độ **Tự động chuyển khi hết quota** là tùy chọn và dùng chung chính sách trên macOS/Windows. Ứng dụng làm mới tài khoản hiện tại và từng ứng viên, chỉ chuyển khi tài khoản hiện tại còn `0%` và ứng viên còn quota ở mọi cửa sổ được trả về. App không dùng quota cache cũ, không force-close Codex/ChatGPT: nếu app vẫn đang chạy thì tự động chuyển được hoãn để bảo vệ công việc. Nếu mọi tài khoản đều hết quota, phiên hiện tại không bị thay đổi.

### Sao lưu và khôi phục

- **Tệp → Xuất bản sao lưu…** tạo file `.codexroster` được mã hóa bằng mật khẩu để chuyển máy hoặc lưu trữ ngoài máy. App không lưu mật khẩu này.
- Ứng dụng tự giữ năm bản sao đầy đủ gần nhất trên máy. Chúng được mã hóa bằng khóa ngẫu nhiên trong Keychain của máy Mac này, vì vậy có thể khôi phục lại phiên đã lưu trên chính máy đó.
- Dùng **Tự động hóa → Khôi phục phiên sao lưu** khi dữ liệu cục bộ gặp lỗi. Thao tác sẽ yêu cầu xác nhận trước khi thay roster hiện tại.

#### Thông báo Keychain trên macOS

macOS có thể hiện hộp thoại kiểu:

> `codex-roster` / `Codex Roster` / `codex_roster-<hash>` muốn dùng thông tin bảo mật trong **"com.codexroster.app"** trên keychain của bạn.

Đây là hành vi bình thường. Codex Roster chỉ lưu khóa mã hóa cục bộ cho snapshot và bản sao lưu tự động trong mục Keychain `com.codexroster.app`. CLI đi kèm app (và binary `cargo test` / `cargo run` khi phát triển, đôi khi hiện tên `codex_roster-<hash>`) cần đọc mục đó để giải mã phiên trên chính máy này. Hộp thoại do macOS hiện, không phải trang đăng nhập bên thứ ba.

- Chọn **Allow** hoặc **Always Allow** sau khi xác nhận tên mục Keychain là `com.codexroster.app`.
- **Deny** sẽ khiến phiên/bản sao lưu đã mã hóa không đọc được cho đến khi được cấp quyền.
- Codex Roster không hỏi mật khẩu OpenAI qua hộp thoại này; chỉ nhập mật khẩu Keychain đăng nhập của Mac nếu macOS yêu cầu.

Không gửi file snapshot, mật khẩu backup, cookie trình duyệt, access token hay refresh token cho bất kỳ ai.

### Cài đặt và chạy

Tải ZIP macOS mới nhất từ [Releases](https://github.com/anlvdt/codex-roster/releases), giải nén rồi kéo **Codex Roster.app** vào Applications. Lần mở đầu, macOS có thể yêu cầu bạn cho phép vì ứng dụng được phát hành độc lập.

Tự build:

```sh
zsh scripts/build-macos-app.sh
open "build/Codex Roster.app"
```

### Windows Preview

Bản shell Windows native dùng **WinUI 3** và gọi chung Rust CLI; xem [windows/README.md](windows/README.md). Bản này có thể tự chuyển an toàn sau khi Codex đã đóng, nhưng không force-close hay tự mở lại Codex. Bản này đang dành cho kiểm chứng trên Windows thật, chưa phải bản phát hành production.

### Riêng tư, trạng thái và ghi nhận

Dữ liệu tài khoản lưu trên máy Mac. Các yêu cầu tới OpenAI Status và Codex Reset chỉ lấy trạng thái/dự báo công khai, không gửi thông tin đăng nhập. Xem [tài liệu pricing và usage chính thức của ChatGPT/Codex](https://learn.chatgpt.com/docs/pricing) để biết chính sách gói và quota mới nhất.

Codex Roster dùng giấy phép MIT, được duy trì bởi [LE AN (@anlvdt)](https://github.com/anlvdt). Xem [AUTHORS.md](AUTHORS.md) và [CREDITS.md](CREDITS.md) để biết ghi nhận tác giả, nguồn tham khảo và ranh giới giấy phép.
