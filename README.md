# Codex Roster

Native macOS account roster, quota monitor, and safe switcher for OpenAI / Codex.

[English](#english) · [Tiếng Việt](#tiếng-việt)

> Codex Roster is a local-first, independent macOS app built for the Codex community. It is not affiliated with, endorsed by, or reviewed by OpenAI.

> “Codex”, “ChatGPT”, “OpenAI”, and related marks belong to OpenAI and are used only to describe compatibility. See the [OpenAI brand guidelines](https://openai.com/brand/).

> **Platform:** macOS only. Windows and Linux support has been removed.

## English

### What it does

- Save, label, archive, restore, and safely switch OpenAI / Codex account snapshots.
- Inspect, save, restore, switch, and monitor supported Claude Code, Cursor, and Grok Build accounts through the provider CLI. Provider snapshots are stored separately from the legacy OpenAI roster so identical emails cannot collide across providers.
- Show the active account's quota in the MacBook notch and switch accounts from the notch roster (Ready filter = usable quota; manual Switch still works for Free/exhausted).
- Launch the OpenAI browser sign-in flow without reading passwords, verification codes, or browser cookies.
- Close and relaunch ChatGPT/Codex Desktop after a confirmed account switch.
- Refresh local Codex token statistics, public OpenAI Status, and reset signals from [Tibo / @thsottiaux on X](https://x.com/thsottiaux), normalized through the independent [Codex Reset radar](https://codex-reset.com/) when X truncates long posts.
- Sync usage to [VibeCafe](https://vibecafe.ai/) via the optional [`@vibe-cafe/vibe-usage`](https://github.com/vibe-cafe/vibe-usage) collector; its token and estimated-cost statistics remain separate from OpenAI quota/banked-reset credits.
- When VibeCafe is configured, Roster automatically syncs every 30 minutes and shows the official 7-day API totals (tokens, estimated cost, sessions, and active time) in Status.
- Offer Vietnamese and English; Vietnamese is the default.

### Quota and automatic switching

`GPT Free`, `GPT Plus`, and `GPT Pro` identify the ChatGPT plan. They do not imply a fixed Codex quota. Codex Roster displays the quota/reset windows returned for the signed-in account.

Codex exposes two independent usage windows: `primary_window` is the rolling **5-hour** allowance and `secondary_window` is the **weekly** allowance. Roster labels and displays both instead of collapsing them into one percentage. An account is immediately usable only while every reported window still has quota; a healthy 5-hour window does not override an exhausted weekly limit, and vice versa.

**Auto-switch when quota is exhausted** is opt-in. It refreshes the active Codex account (`~/.codex`), prefers candidate quota cached within about 15 minutes, and revalidates the chosen candidate on apply (`--account-id`). It switches only when the active account is at `0%` and another saved account has usable quota in every reported window. On macOS, it waits while the active ChatGPT session is still writing Codex rollout events; once idle, it saves the live session, quits Desktop (graceful first), clears Desktop web-session cache, applies the new `~/.codex` session, then relaunches Desktop so the UI matches Roster. If every account is exhausted, it leaves the current session untouched.

A banked rate-limit reset is reported separately from immediately usable quota. Roster identifies the account and reset count instead of silently consuming an irreversible reset or switching to an account that is still at `0%`; redeem the reset explicitly in Codex, then the next background check can use the refreshed quota.

The notch roster groups every account into one of five states and leads with the single next action worth taking (switch, redeem a banked reset, sign in again, retry a quota read, or nothing at all):

| State | Meaning |
| --- | --- |
| **Needs action** | Sign-in expired, local recovery required, or a quota read failed. |
| **In use** | The current `~/.codex` session. |
| **Ready** | Session healthy and quota available — switchable right now (auto-switch / keyboard 1–9). |
| **Resting** | Out of quota, waiting to reset. Still manually switchable; banked resets remain visible. |
| **Archived** | Set aside and excluded from auto-switch. |

Notch filters, next-action captions, and account cards read from the same triage state. Accounts can be sorted by ChatGPT plan (Pro → Plus → Free), remaining quota, display name, or email.

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

The notch panel checks stable GitHub Releases at launch and every six hours. When an update is available, select **Update** there; the ZIP's GitHub SHA-256 digest is verified before the app replaces itself and reopens.

Build locally:

```sh
zsh scripts/build-macos-app.sh
open "build/Codex Roster.app"
```

### Platform

macOS only. Codex Roster is a native macOS app; the crate builds and ships for macOS (Apple Silicon and Intel). Windows and Linux support has been removed.

### CLI

The app bundles `codex-roster`. For development, set `CODEX_ROSTER_CLI_PATH` to another build.

The existing top-level commands continue to manage the OpenAI / Codex roster. Multi-provider commands live under `providers` and currently support `open_ai`/`openai`/`codex`, `claude`/`anthropic`, `cursor`, and `grok`/`xai` aliases. Claude Code and Cursor expose official usage windows when their local credentials are available. Grok Build reads its own local auth and reports Build credits separately from xAI API/team billing. Account switching is scoped to the selected provider; cross-provider automatic routing is not enabled.

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
codex-roster vibe-usage [init|sync|summary|status]
codex-roster reset-outlook [--json]
codex-roster open-ai-status [--json]

codex-roster providers status [--json]
codex-roster providers list [--provider PROVIDER] [--json]
codex-roster providers save PROVIDER [--json]
codex-roster providers activate ACCOUNT_ID [--json]
codex-roster providers usage PROVIDER [ACCOUNT_ID] [--json]
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
- Qua CLI provider, có thể kiểm tra, lưu, khôi phục, chuyển và theo dõi tài khoản Claude Code, Cursor và Grok Build. Snapshot của các provider này được lưu tách khỏi roster OpenAI cũ để cùng một email ở nhiều provider không bị đụng nhau.
- Hiển thị quota tài khoản đang dùng tại notch MacBook và chuyển tài khoản từ danh bạ notch (bộ lọc Ready = còn quota usable; Đổi thủ công vẫn dùng được với Free/hết quota).
- Mở luồng đăng nhập thiết bị OpenAI mà không đọc mật khẩu, mã xác thực hay cookie trình duyệt.
- Đóng rồi mở lại ChatGPT/Codex Desktop sau khi bạn xác nhận chuyển tài khoản.
- Theo dõi token Codex cục bộ, trạng thái công khai OpenAI và tín hiệu reset từ [Tibo / @thsottiaux trên X](https://x.com/thsottiaux); dùng radar độc lập [Codex Reset](https://codex-reset.com/) để chuẩn hóa khi X cắt ngắn bài đăng dài.
- Nếu đã cấu hình VibeCafe qua collector tùy chọn [`@vibe-cafe/vibe-usage`](https://github.com/vibe-cafe/vibe-usage), Roster tự đồng bộ mỗi 30 phút và hiển thị thống kê API chính thức trong Status: token, chi phí ước tính, số phiên và thời gian hoạt động trong 7 ngày; các thống kê này tách biệt với quota/banked reset credit của OpenAI.
- Hỗ trợ Tiếng Việt và English; mặc định là Tiếng Việt.

### Quota và tự động chuyển

`GPT Free`, `GPT Plus`, `GPT Pro` là nhãn gói ChatGPT, không phải quota Codex cố định. Codex Roster hiển thị quota/thời điểm reset thực tế được trả về cho tài khoản đang đăng nhập.

Codex trả về hai cửa sổ sử dụng độc lập: `primary_window` là quota cuốn chiếu **5 giờ**, còn `secondary_window` là quota **tuần**. Roster hiển thị và gắn nhãn riêng cho cả hai thay vì gộp thành một phần trăm. Tài khoản chỉ dùng được ngay khi mọi cửa sổ được trả về đều còn quota; quota 5 giờ còn không thể bù cho quota tuần đã hết và ngược lại.

Chế độ **Tự động chuyển khi hết quota** là tùy chọn. App theo dõi phiên Codex tại `~/.codex` (không đọc cookie đăng nhập riêng trong ChatGPT). Khi hết `0%`, app chờ nếu phiên ChatGPT đang ghi hoạt động Codex; sau khi phiên yên, macOS sẽ lưu phiên đang mở, đóng ChatGPT/Codex (ưu tiên thoát mềm), xóa cache web Desktop, chuyển phiên, rồi mở lại Desktop để khớp Roster. Nếu mọi tài khoản đều hết quota, phiên hiện tại không bị thay đổi.

Banked rate-limit reset được tách khỏi quota có thể dùng ngay. Roster sẽ nêu rõ account và số reset thay vì tự tiêu một reset không thể hoàn tác hoặc chuyển sang account vẫn `0%`; sau khi bạn redeem reset trong Codex, lần kiểm tra nền kế tiếp có thể dùng quota vừa được khôi phục.

Danh bạ notch chia mọi tài khoản vào một trong năm trạng thái và nêu sẵn việc nên làm tiếp theo (chuyển tài khoản, redeem banked reset, đăng nhập lại, thử lại quota, hoặc không cần làm gì):

| Trạng thái | Ý nghĩa |
| --- | --- |
| **Cần xử lý** | Phiên hết hạn, cần phục hồi cục bộ, hoặc không đọc được quota. |
| **Đang dùng** | Phiên `~/.codex` hiện tại. |
| **Sẵn sàng** | Phiên khỏe và còn quota — chuyển sang được ngay (tự chuyển / phím 1–9). |
| **Đang nghỉ** | Hết quota, đang chờ đặt lại. Vẫn Đổi thủ công được; banked reset vẫn hiện. |
| **Đã lưu trữ** | Đã cất đi, không tham gia tự động chuyển. |

Bộ lọc notch, caption next-action và thẻ tài khoản đều đọc từ cùng một nguồn triage. Tài khoản có thể sắp xếp theo gói ChatGPT (Pro → Plus → Free), quota còn lại, tên hiển thị hoặc email.

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

Bảng notch tự kiểm tra GitHub Releases ổn định khi khởi động và mỗi sáu giờ. Khi có bản mới, chọn **Cập nhật** tại đó; ứng dụng xác thực SHA-256 do GitHub công bố trước khi tự thay thế và mở lại.

Tự build:

```sh
zsh scripts/build-macos-app.sh
open "build/Codex Roster.app"
```

### Nền tảng

Chỉ macOS. Codex Roster là ứng dụng macOS native; crate build và phát hành cho macOS (Apple Silicon và Intel). Hỗ trợ Windows và Linux đã được gỡ bỏ.

### CLI đa provider

Các lệnh cấp cao hiện có vẫn quản lý roster OpenAI / Codex. Nhóm `providers` hỗ trợ alias `open_ai`/`openai`/`codex`, `claude`/`anthropic`, `cursor`, và `grok`/`xai`. Claude Code và Cursor đọc credential cục bộ do chính ứng dụng đó quản lý để lấy usage chính thức. Grok Build đọc auth riêng và hiển thị credit của Grok Build tách biệt với billing xAI API/team. Việc chuyển tài khoản chỉ diễn ra trong đúng provider; chưa bật tự động định tuyến chéo provider.

```text
codex-roster providers status [--json]
codex-roster providers list [--provider PROVIDER] [--json]
codex-roster providers save PROVIDER [--json]
codex-roster providers activate ACCOUNT_ID [--json]
codex-roster providers usage PROVIDER [ACCOUNT_ID] [--json]
```

### Riêng tư, trạng thái và ghi nhận

Dữ liệu tài khoản lưu trên máy Mac. Kiểm tra OpenAI Status, đọc hồ sơ X công khai của Tibo và truy vấn Codex Reset không gửi credential, định danh tài khoản, phiên đã lưu hay dữ liệu quota. Giá trị 24h/48h là điểm dự báo từ tín hiệu công khai, không phải xác suất thống kê: thời điểm giao rõ ràng sẽ neo tín hiệu hẹn trước, tín hiệu mơ hồ giảm theo độ mới, còn reset đã xác nhận được hiển thị như mốc hoàn tất gần nhất. Bài đăng reset công khai chỉ là tín hiệu tham khảo; quota có xác thực do Codex trả về cho từng tài khoản vẫn là nguồn xác nhận cuối cùng. Xem [tài liệu pricing và usage chính thức của ChatGPT/Codex](https://learn.chatgpt.com/docs/pricing) để biết chính sách gói và quota mới nhất.

Codex Roster dùng giấy phép MIT, được duy trì bởi [LE AN (@anlvdt)](https://github.com/anlvdt). Xem [AUTHORS.md](AUTHORS.md) và [CREDITS.md](CREDITS.md) để biết ghi nhận tác giả, nguồn tham khảo và ranh giới giấy phép.
