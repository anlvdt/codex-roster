# Codex Roster

Native macOS account roster, quota monitor, and safe switcher for OpenAI / Codex.

[English](#english) · [Tiếng Việt](#tiếng-việt)

> Codex Roster is a local-first, independent macOS app built for the Codex community. It is not affiliated with, endorsed by, or reviewed by OpenAI.

> “Codex”, “ChatGPT”, “OpenAI”, and related marks belong to OpenAI and are used only to describe compatibility. See the [OpenAI brand guidelines](https://openai.com/brand/).

> **Platform focus:** macOS is the only actively developed and released desktop app. Windows and Linux desktop work is paused; their existing source is retained for possible future maintenance.

## English

### What it does

- Save, label, archive, restore, and safely switch OpenAI / Codex account snapshots.
- Show the active account's quota in the menu bar and account quota/reset state in the sidebar.
- Launch the OpenAI browser sign-in flow without reading passwords, verification codes, or browser cookies.
- Close and relaunch ChatGPT/Codex Desktop after a confirmed account switch.
- Refresh local Codex token statistics, public OpenAI Status, and reset signals from [Tibo / @thsottiaux on X](https://x.com/thsottiaux), normalized through the independent [Codex Reset radar](https://codex-reset.com/) when X truncates long posts.
- Automatically install, update, configure, and repair [Codex Router](https://github.com/duolahypercho/codex-router) from its checksum-verified official installer; no Router controls are required for native Codex use.
- Offer Vietnamese and English; Vietnamese is the default.

### Optional external-model routing

Codex Router remains an independent installation and keeps ownership of its provider credentials, service, model catalog, and Codex configuration. Roster never reads API keys or copies Router state. On macOS, Roster downloads the official `v0.4.0-beta.4` installer, verifies its pinned SHA-256 checksum, prepares locked dependencies, enables native-only mode without asking for a provider key, repairs an unhealthy service, and checks for maintenance updates every six hours. Existing checkout, Homebrew, and `PATH` installations are detected automatically.

Use **Add external models** on the Router card to connect, enable, or hide providers without typing commands. Roster preserves every already-enabled provider and native GPT entry while Router performs the credential-safe OAuth/API-key prompt in Terminal. Hiding a provider does not delete its credential or curated models. Anonymous remote providers require an explicit warning confirmation before Roster enables them; they are never selected silently.

### Quota and automatic switching

`GPT Free`, `GPT Plus`, and `GPT Pro` identify the ChatGPT plan. They do not imply a fixed Codex quota. Codex Roster displays the quota/reset windows returned for the signed-in account.

**Auto-switch when quota is exhausted** is opt-in. It refreshes the active Codex account (`~/.codex`), prefers candidate quota cached within about 15 minutes, and revalidates the chosen candidate on apply (`--account-id`). It switches only when the active account is at `0%` and another saved account has usable quota in every reported window. On macOS, when ChatGPT/Codex Desktop is open, auto-switch closes it, applies the new `~/.codex` session, then relaunches Desktop so the UI matches Roster. If every account is exhausted, it leaves the current session untouched.

A banked rate-limit reset is reported separately from immediately usable quota. Roster identifies the account and reset count instead of silently consuming an irreversible reset or switching to an account that is still at `0%`; redeem the reset explicitly in Codex, then the next background check can use the refreshed quota.

Account lists can be sorted by ChatGPT plan (Pro → Plus → Free), remaining quota, display name, or email. The menu bar shows up to five quick-switch candidates using the same sort order.

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

The menu bar checks stable GitHub Releases at launch and every six hours. When an update is available, select **Update** there; the ZIP's GitHub SHA-256 digest is verified before the app replaces itself and reopens.

Build locally:

```sh
zsh scripts/build-macos-app.sh
open "build/Codex Roster.app"
```

### Platform status

- **macOS:** active product development, CI, packaging, and releases.
- **Windows:** desktop source and maintenance build scripts are retained, but feature work, CI packaging, previews, and releases are paused.
- **Linux:** no active desktop distribution. Shared Rust source remains in the repository only to preserve future portability.

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
codex-roster router status [--json]
codex-roster router providers [--json]
codex-roster router connect PROVIDER_ID [--allow-anonymous] [--json]
codex-roster router disable PROVIDER_ID [--json]
codex-roster router open [--json]
codex-roster router doctor [--json]
```

### Privacy, status, and credits

Saved account data remains on this Mac. OpenAI Status, Tibo's public X profile, and Codex Reset radar requests never include account credentials, identifiers, saved sessions, or quota data. The 24h/48h values are public-signal forecast scores, not statistical probabilities: explicit delivery times anchor scheduled resets, unscheduled hints decay with age, and a confirmed reset remains visible as the latest completed milestone. Public reset posts are advisory; authenticated per-account quota returned by Codex remains the source of truth. Read [OpenAI's current ChatGPT and Codex pricing documentation](https://learn.chatgpt.com/docs/pricing) for plan and usage policy.

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
- Theo dõi token Codex cục bộ, trạng thái công khai OpenAI và tín hiệu reset từ [Tibo / @thsottiaux trên X](https://x.com/thsottiaux); dùng radar độc lập [Codex Reset](https://codex-reset.com/) để chuẩn hóa khi X cắt ngắn bài đăng dài.
- Tự động cài, cập nhật, cấu hình và sửa [Codex Router](https://github.com/duolahypercho/codex-router) bằng installer chính thức đã xác minh checksum; dùng Codex native không cần thao tác Router.
- Hỗ trợ Tiếng Việt và English; mặc định là Tiếng Việt.

### Định tuyến model ngoài (tùy chọn)

Codex Router vẫn là ứng dụng độc lập và tự quản lý credential provider, dịch vụ, model catalog cùng cấu hình Codex. Roster không đọc API key hay sao chép state của Router. Trên macOS, Roster tải installer chính thức `v0.4.0-beta.4`, xác minh SHA-256, chuẩn bị dependency đã khóa, bật chế độ native không cần provider key, tự sửa service lỗi và kiểm tra bảo trì mỗi sáu giờ. Các bản cài checkout chuẩn, Homebrew và `PATH` vẫn được nhận diện tự động.

Dùng **Thêm model ngoài** trên thẻ Router để kết nối, bật hoặc ẩn provider mà không cần gõ lệnh. Roster luôn hợp nhất provider mới với danh sách đang bật và giữ nguyên native GPT; Router tự mở luồng OAuth/API key bảo mật trong Terminal. Ẩn provider không xoá credential hay model đã chọn. Gateway anonymous chỉ được bật sau khi người dùng xác nhận cảnh báo prompt sẽ rời khỏi máy.

### Quota và tự động chuyển

`GPT Free`, `GPT Plus`, `GPT Pro` là nhãn gói ChatGPT, không phải quota Codex cố định. Codex Roster hiển thị quota/thời điểm reset thực tế được trả về cho tài khoản đang đăng nhập.

Chế độ **Tự động chuyển khi hết quota** là tùy chọn. App theo dõi phiên Codex tại `~/.codex` (không đọc cookie đăng nhập riêng trong ChatGPT). Khi hết `0%`, macOS sẽ đóng ChatGPT/Codex nếu cần, chuyển phiên, rồi mở lại Desktop để khớp Roster. Nếu mọi tài khoản đều hết quota, phiên hiện tại không bị thay đổi.

Banked rate-limit reset được tách khỏi quota có thể dùng ngay. Roster sẽ nêu rõ account và số reset thay vì tự tiêu một reset không thể hoàn tác hoặc chuyển sang account vẫn `0%`; sau khi bạn redeem reset trong Codex, lần kiểm tra nền kế tiếp có thể dùng quota vừa được khôi phục.

Danh sách tài khoản có thể sắp xếp theo gói ChatGPT (Pro → Plus → Free), quota còn lại, tên hiển thị hoặc email. Menu bar hiện tối đa năm ứng viên chuyển nhanh theo cùng thứ tự sắp xếp.

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

Menu bar tự kiểm tra GitHub Releases ổn định khi khởi động và mỗi sáu giờ. Khi có bản mới, chọn **Cập nhật** tại đó; ứng dụng xác thực SHA-256 do GitHub công bố trước khi tự thay thế và mở lại.

Tự build:

```sh
zsh scripts/build-macos-app.sh
open "build/Codex Roster.app"
```

### Trạng thái nền tảng

- **macOS:** đang được phát triển, chạy CI, đóng gói và phát hành.
- **Windows:** giữ lại mã nguồn desktop và script maintenance, nhưng tạm dừng feature, CI đóng gói, preview và release.
- **Linux:** chưa phát triển bản desktop. Mã Rust dùng chung chỉ được giữ để bảo toàn khả năng mở rộng trong tương lai.

### Riêng tư, trạng thái và ghi nhận

Dữ liệu tài khoản lưu trên máy Mac. Kiểm tra OpenAI Status, đọc hồ sơ X công khai của Tibo và truy vấn Codex Reset không gửi credential, định danh tài khoản, phiên đã lưu hay dữ liệu quota. Giá trị 24h/48h là điểm dự báo từ tín hiệu công khai, không phải xác suất thống kê: thời điểm giao rõ ràng sẽ neo tín hiệu hẹn trước, tín hiệu mơ hồ giảm theo độ mới, còn reset đã xác nhận được hiển thị như mốc hoàn tất gần nhất. Bài đăng reset công khai chỉ là tín hiệu tham khảo; quota có xác thực do Codex trả về cho từng tài khoản vẫn là nguồn xác nhận cuối cùng. Xem [tài liệu pricing và usage chính thức của ChatGPT/Codex](https://learn.chatgpt.com/docs/pricing) để biết chính sách gói và quota mới nhất.

Codex Roster dùng giấy phép MIT, được duy trì bởi [LE AN (@anlvdt)](https://github.com/anlvdt). Xem [AUTHORS.md](AUTHORS.md) và [CREDITS.md](CREDITS.md) để biết ghi nhận tác giả, nguồn tham khảo và ranh giới giấy phép.
