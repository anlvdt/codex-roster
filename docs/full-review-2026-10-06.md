# Review toàn bộ AgentDock / codex-roster — 2026-10-06

Các 35 Important ban đầu và các khoảng trống phát hiện khi review bản sửa đã được xử lý trong working tree. Review độc lập cuối không còn blocker trong các phần được sửa. Rust **377 passed, 1 ignored**; Swift **94 functions / 115 cases passed**. Còn ba Minor provider được liệt kê bên dưới. Chưa commit, push, merge hay deploy.

## Phạm vi và cách kiểm tra

Yêu cầu: `/superpowers:requesting-code-review toàn bộ ứng dụng từ lúc mới bắt đầu phát triển đến hiện tại`.

- Commit đầu: `309fccefd7a233b12c292fad4fd92aec6f4b2be2`, 2026-04-11, Initial codex account switcher release.
- HEAD được review: `8b87a0296ca125387ebf25d979d639edd9a32e4d`, 2026-10-03, dual-agent notch (#38).
- Lịch sử đến HEAD có 295 commit. Review đọc toàn bộ các nhóm mã production/config hiện tại được phân công, đối chiếu phiên bản đầu và các commit liên quan đến chức năng/lỗi. Không có tuyên bố đã đọc từng dòng của cả 295 diff lịch sử.
- Phạm vi ban đầu khoảng 43.200 dòng trong 79 file production/config: Rust CLI, repository/backup/settings, account switch/resume, các provider, Claude Desktop/quota bridge, Swift domain/UI/notch, updater, CI/build/release. Các tài liệu audit trước được dùng để đối chiếu, không được coi là bằng chứng tự thân.
- Reviewer độc lập nhận yêu cầu, SHA, file và tiêu chí cụ thể, không nhận toàn bộ lịch sử hội thoại. Sáu nhóm review ban đầu; các bản sửa được review lại theo nhóm và có kiểm tra tích hợp chung.
- Working tree đã có bản sửa notch trước khi review: quota 5h bằng 0 vẫn hợp lệ, bỏ companion khi thiếu 5h, khởi động monitoring Claude, và sửa chiều rộng/clearance trên màn hình không notch. Các thay đổi này được giữ lại, không tính thành phát hiện mới.

Các mốc lịch sử dùng để định hướng phạm vi: release đầu 2026-04-11; v0.2.0/native packaging 2026-07-30 (`e374c8d`, `424f5a4`); quota UI chuyển sang notch 2026-08-30 (`20772f2`); multi-provider 2026-09-06 (`585594e`); v0.3/v0.4 2026-09-07; restore guards/provider hardening và dual-agent notch ở các commit cuối tháng 9/đầu tháng 10. Lịch sử liên quan được đối chiếu với source hiện tại, không phải chứng nhận từng release cũ vẫn chạy được.

## Kết quả ban đầu

Không xác lập lỗi Critical. Có **35 lỗi Important riêng biệt** sau khi gộp phát hiện trùng; ba Minor ở provider còn để lại. Hai lỗi P1 rõ nhất là bỏ sót tiến trình Codex đang chạy và tự khóa khi bật Luna cho account chưa active.

Các bảng dưới ghi trigger ban đầu và hướng sửa. “Đã sửa” không đồng nghĩa chứng nhận mọi hành vi trên account thật; giới hạn chạy thực tế được ghi riêng ở cuối.

### Storage, backup và cấu hình — 9 Important

| ID | Trigger / ảnh hưởng trước sửa | Bản sửa / bằng chứng |
|---|---|---|
| S1 | Metadata mất/hỏng khiến không thể phục hồi từ full backup hợp lệ. | Explicit restore đọc backup độc lập, giữ metadata hỏng để recovery; fixture missing/corrupt index. `src/repository/index_store.rs`, `src/repository.rs`. |
| S2 | Import/restore hỗn hợp đã ghi Codex trước khi provider lỗi. | Prepare provider trong thư mục riêng; commit phối hợp và rollback cả hai store khi thất bại; fixture lỗi prepare, snapshot write, metadata save. `src/repository.rs`. |
| S3 | Lỗi đọc legacy ở account sau thoát sớm, để nguyên các secret đã ghi trước. | Undo bao phủ lỗi đọc muộn; fixture preimage account đã tồn tại và account mới. `src/repository.rs`. |
| S4 | Delete secret thành công một phần rồi lỗi: account còn trong index nhưng thiếu secret. | Giữ preimage, phục hồi khi delete thất bại; giữ bản encrypted recovery nếu rollback cũng lỗi. `src/repository.rs`. |
| S5 | “Latest” backup ưu tiên roster cũ lớn hơn roster mới. | Chọn backup hợp lệ có thời gian export mới nhất; bỏ backup hỏng và identity trùng. Fixture mới/ít account và mới nhưng invalid. `src/repository.rs`, `src/repository/index_store.rs`. |
| S6 | Export truncate file đích trước khi encryption hoàn tất. | Ghi sibling temporary, flush/sync rồi rename; fixture thất bại giữ nguyên file cũ. `src/backup.rs`. |
| S7 | Cancel login khi auth ban đầu không tồn tại vẫn để auth mới trên đĩa. | Marker ghi nhận sự vắng mặt của từng file, cancel khôi phục đúng trạng thái; marker hỏng hoặc thiếu preimage dừng trước khi đổi live file. `src/codex.rs`. |
| S8 | Settings canonical bị mất trong lúc ghi: bỏ qua recovery và bật default auto-resume. | Chọn recovery hợp lệ trước defaults; canonical hợp lệ vẫn ưu tiên. `src/settings.rs`. |
| S9 | Đọc/ghi model theo dòng đụng model trong profile hoặc multiline TOML. | Parse TOML, chỉ thay span của root model; giữ comment/profile/format, invalid config fail closed. Thêm direct dependency TOML 0.5.11 đã có trong lockfile, không đổi resolved version. `src/codex.rs`, `Cargo.toml`. |

Review bổ sung cũng sửa full restore để thay đúng roster provider của environment được chọn, giữ environment khác; staging private và từ chối symlink. Recovery ưu tiên account-list backup hợp lệ trước empty fallback, giữ generation tăng dần, và explicit provider restore rebuild metadata hỏng trong staging nhưng vẫn lưu bytes gốc. Restore publish automatic list backup của roster mới; nếu thư mục backup không ghi được, list restore từ chối candidate có generation cũ hơn metadata hiện tại trước mọi mutation. Fixture directory `0500` xác nhận account bị bỏ không trở lại. Staging giữ timestamp gốc để recovery không xếp candidate theo thứ tự copy. Ordinary import vẫn từ chối provider index hỏng. Giao dịch này có rollback khi hàm trả lỗi, không tuyên bố bảo đảm atomic xuyên qua mất điện ở mọi bước.

### Rust: process, Luna, token context, TUI, reset — 5 Important

| ID | Trigger / ảnh hưởng trước sửa | Bản sửa / bằng chứng |
|---|---|---|
| R1 / P1 | Bất kỳ argument chứa `codex-roster` đều có thể che tiến trình Codex, cho phép switch khi đang chạy. | Nhận diện executable và wrapped CLI; prompt, flag value và bundled CLI không còn bypass guard. Fixture process classification và force activation. `src/process.rs`. |
| R2 / P1 | Bật Luna cho account chưa active gọi activation trong lúc đang giữ AuthLock, tự chờ timeout. | Activate trước lock ngoài, sau đó recheck identity trước khi đổi model; fixture account active/inactive và activation failure. `src/app/service.rs`. |
| R3 | Metadata fallback ghi đè model/cwd mới nhất trong token context. | Fallback chỉ bổ sung ancestry, giữ context mới; tăng cache version để bỏ cache cũ. `src/token_usage.rs`. |
| R4 | Dòng TUI wrap làm cursor physical/logical lệch; viewport không giữ selection khi terminal thấp. | Clip theo width, redraw khi resize, viewport theo height giữ selection; fixture narrow/short terminal. `src/app/tui.rs`. |
| R5 | Cả hai reset feed lỗi vẫn khởi tạo empty state, bỏ replay khi feed phục hồi. | Không đổi state khi không có feed thành công; giữ partial success và replay sau recovery. `src/reset_tracker.rs`. |

### Provider và quota — 5 Important

| ID | Trigger / ảnh hưởng trước sửa | Bản sửa / bằng chứng |
|---|---|---|
| P1 | Có `CLAUDE_CONFIG_DIR` nhưng fallback sang config default của account khác. | Explicit scope là authoritative cho read/write kể cả scoped config chưa có; fixture default config không bị sửa. `src/provider/claude.rs`. |
| P2 | Đọc preimage Keychain lỗi bị coi là slot vắng mặt; rollback có thể xóa credential cũ. | Stage giữ `Result<Option<_>>`, abort trước mutation khi đọc lỗi; injected adapter fixture, không truy cập Keychain thật. `src/provider/claude.rs`. |
| P3 | Retry sau 401 dùng live account B rồi lưu quota dưới record A. | Chặn retry đổi identity trước fetch/persist, vẫn cho phép token rotation cùng identity. `src/app/providers.rs`. |
| P4 | OAuth quota thiếu weekly/5h hoặc bỏ model cap đã biết vẫn đủ điều kiện auto-switch. | Require đủ aggregate window; partial quota không eligible; không thay cache complete bằng dữ liệu bỏ known cap. Fixture missing/null/invalid/reset caps. `src/provider/claude.rs`, `src/app/providers.rs`, `src/app/provider_auto_switch.rs`. |
| P5 | Xóa Desktop vault trước khi xóa index provider; lỗi index để account còn nhưng mất Desktop snapshot. | Chỉ xóa Desktop snapshot sau khi store removal thành công; fixture failed/successful index write. `src/app/providers.rs`. |

### Swift domain và continuity — 7 Important

| ID | Trigger / ảnh hưởng trước sửa | Bản sửa / bằng chứng |
|---|---|---|
| D1 | Codex auto-switch lỗi sau khi đóng Desktop bỏ qua relaunch. | Catch và retry paths khôi phục Desktop bằng relaunch plan đã giữ. `AccountStore.swift`. |
| D2 | CLI login thoát lỗi hoặc thoát không có auth: watcher chờ vô hạn, flags/Desktop bị kẹt. | Watchdog xử lý exit lỗi, grace period cho exit 0 chưa có auth và deadline cho login bỏ dở; fail path cancel/clear flags/relaunch. Pure watchdog fixture. `AccountStore.swift`. |
| D3 | Claude preflight chọn B nhưng apply tự quyết lại C. | CLI `--preferred-account-id` bắt buộc apply, reject candidate đổi trước mutation; Swift truyền ID đã preflight. CLI parser fixtures. `src/cli.rs`, `AccountStore.swift`. |
| D4 | Native Claude roster rỗng khiến expected email nil, bỏ identity/override verification. | Lấy identity authoritative từ CLI; automatic continuation bắt buộc identity, chặn credential/provider overrides. Shell fixtures wrong account, missing identity, gateway, credential. |
| D5 | Transcript đổi sau await nhưng interruption cũ vẫn được resume. | Recheck exact event bằng path/size/tail digest và freshness trước launch và sau auth script; fixture đổi nội dung trong auth. `ClaudeSessionContinuity.swift`. |
| D6 | Ghi UUID “đã resume” khi chỉ giao Terminal, lỗi launch/auth không thể retry. | Pending claim riêng từng interruption, success receipt chỉ sau verified resume exit 0; lỗi trả claim cho retry. Claim expiry/token ownership và fixture auth/resume failure. |
| D7 | Discovery hardcode `~/.claude/projects`, không theo credential scope. | Discovery, validation và script dùng cùng `CLAUDE_CONFIG_DIR`; default scope được unset rõ trong script. Custom-scope fixture. |

Review sau sửa phát hiện thêm cần serialise expiry/adoption/release giữa Swift và script; recheck tuổi transcript sau auth; không để cửa sổ lỗi chờ Enter giữ claim; old EXIT không được xóa claim mới. Khóa POSIX chung giữ stable inode, thêm mutex giữa thread trong cùng process; main actor fail-fast khi foreign lock đang giữ. Fixture 12 thread bắt thêm lỗi nhiều claim cùng nhận thành công: đã đổi sang đọc metadata mới dưới khóa, lỗi/thiếu timestamp dừng và chỉ xóa launching claim khi có bằng chứng tuổi ít nhất 60 giây. Các tình huống này thuộc cùng luồng D5/D6. Watcher cũng recheck cancellation và trạng thái waiting sau mỗi CLI await để không publish kết quả cũ.

### UI / notch — 6 Important

| ID | Trigger / ảnh hưởng trước sửa | Bản sửa / bằng chứng |
|---|---|---|
| U1 | Tắt notch trong accessory app khiến không mở lại giao diện được. | Launcher/hotkey/reopen route tới Settings khi notch disabled. Pure routing fixture. `NextAccountApp.swift`. |
| U2 | Host height tính nonarchived nhưng deck “All” hiện cả archived, bị clip. | Dùng chung displayed roster/filter để tính section count và chiều cao; fixture archived/empty/triage. `PrismQuickSwitchDeck.swift`, `NotchWindow.swift`. |
| U3 | Sign-in all gửi nhiều presentation lên cùng một sheet, thay account đang login. | Queue UUID dedup, giữ active đến dismissal, bỏ deleted IDs, cancel pending; busy không lấy ID ra queue. Add/Edit không cạnh tranh sheet, panel giữ mở đến dismiss. Queue/arbitration fixtures. |
| U4 | Có archive API nhưng không có UI action để archive/restore. | Card/menu có archive và restore theo ID được capture; archived filter hiển thị account để khôi phục. `PrismQuickSwitchDeck.swift`. |
| U5 | Compact Claude quota mất trạng thái cached/unverified sau 429/expired statusline. | Snapshot giữ verification, caption và accessibility; cập nhật theo clock. Fixtures fresh/429/expired/unavailable. `NotchQuotaSnapshot.swift`, `NotchWindow.swift`. |
| U6 | Click details trong Operations chỉ đổi selection không được consume. | Sheet detail nhận account được chọn. `OperationsView.swift`. |

Hai Minor UI cũng được sửa: Escape chỉ xử lý cửa sổ notch qua local monitor; trạng thái OpenAI chưa biết hiển thị unknown thay vì xanh “OK”. Relogin completion đợi store idle hoặc trả lỗi, không coi busy early-return là thành công.

### Updater và CI — 3 Important

| ID | Trigger / ảnh hưởng trước sửa | Bản sửa / bằng chứng |
|---|---|---|
| B1 | Hash/copy/extract/wait chạy trên main actor làm treo UI trong update. | Chuyển archive preparation, staging/helper I/O và cleanup sang utility worker; state UI/terminate ở main. Fixture real `ditto`, digest/size/version/signature failures, private staging và cleanup. `GitHubUpdater.swift`. |
| B2 | Menu cũ bị bỏ khiến kết quả check/install không có đường thao tác. | Menu theo state: check/install/busy/status/error; fixture available mới hiện install. `NextAccountApp.swift`, `PrismQuickSwitchDeck.swift`. |
| B3 | Bốn Swift tests thiếu actor isolation; CI chỉ build app nên không phát hiện lỗi test compile. | Sửa annotation, thêm `swift test --package-path macos/NextAccount` vào CI. Chạy Swift Testing thực tế với CLT framework/rpaths ở máy local. |

## Minor còn lại

1. `src/provider/claude.rs`: local `FileRestoreGuard` chưa stage credentials file khi target Keychain-only có thể xóa file đó. Outer restore của snapshot trước có thể phục hồi; local guard chưa bao phủ đầy đủ. Theo reviewer đây là Minor, không phải khẳng định mất credential vô điều kiện.
2. `src/claude_quota_bridge.rs`: lấy 1.000 directory entries đầu trước khi lọc có thể bỏ observation mới ở thư mục lớn. Fallback OAuth vẫn hoạt động; nên index/lọc trước khi giới hạn và giữ session-account binding.
3. `src/app/claude_desktop.rs`: same-account restore capture live material trước, nên live cookie/cache thiếu cấu trúc có thể chặn phục hồi từ saved snapshot hợp lệ. Cần fallback có kiểm tra; không cam kết khôi phục session hết hạn mà không login lại.

Dependency audit local không thấy advisory vulnerability trong lockfile; còn warning **proc-macro-error2 2.0.1 unmaintained**, `RUSTSEC-2026-0173`, dependency gián tiếp qua age. Database local ở commit ngày 2026-10-03; chưa fetch database mới và chưa kiểm tra yanked crate trong lần audit offline này.

## Kiểm tra bản sửa

| Kiểm tra | Kết quả |
|---|---|
| `cargo test --all --locked --offline` | 377 passed, 0 failed, 1 ignored (test Keychain thật); 19,99 giây. Binary và doc tests không lỗi. |
| `cargo clippy --all-targets --all-features --locked --offline -- -D warnings` | Passed. |
| `cargo fmt --all -- --check` | Passed. |
| `bash scripts/check-auth-switch-safety.sh` | Passed. |
| Swift Testing đầy đủ | 94 functions / 115 cases trong 1 suite passed, 0 failed; 4,367 giây. Bao gồm real shell fake-CLI handoff, 12 thread claim, Swift/shell record-lock race và foreign-lock fail-fast. |
| `cargo audit --no-fetch --no-yanked --json` | 0 vulnerability, 1 unmaintained warning với DB local nêu trên. |
| Shell syntax / Info.plist / whitespace | `bash -n`, `plutil -lint`, `git diff --check` passed. |
| GitNexus sau sửa | Index thành công; `detect-changes --scope all` và `--scope compare --base-ref main`: 28 tracked files, 376 changed symbols, 280 affected flows. Graph risk critical do các shared storage/login paths; đây không phải Critical finding. |

Các test mới dùng in-memory/temp fixtures và injected failures. Các file Swift regression mới: `AccountContinuityRegressionTests.swift`, `UIReviewRegressionTests.swift`, `UpdaterPreparationTests.swift`; test notch companion có sẵn trước review được giữ lại.

Lần tích hợp Swift đầu của fixture concurrency bị starvation và SIGPIPE, sau đó test 12 thread bắt được lỗi claim nói trên. Fixture đã dùng thread riêng, serialise các test cố ý giữ cùng mutex và `F_SETNOSIGPIPE` trên writer; kết quả 94 passed là lần chạy đầy đủ cuối sau tất cả các sửa này.

Local Swift command:

```sh
swift test --package-path macos/NextAccount \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

Các flag bổ sung dùng cho Swift Testing từ Command Line Tools trên máy này. CI có bước Swift test chuẩn; chưa xác nhận CI chạy thành công trên remote runner. Detect-changes không liệt kê bốn file test mới và báo cáo còn untracked; các file đó đã được kiểm tra bằng test runner và đọc riêng. Git status chỉ chứa nhóm mã được sửa ở trên, test và báo cáo; không thay instruction files, branch hay HEAD.

## Giới hạn và bàn giao

- Không chạy login/account switch bằng account thật, Keychain thật, live quota API, Desktop restore thật, Terminal/GUI tương tác thật, installer/self-update thật hoặc Windows. Fixture shell chỉ gọi fake `claude` trong private temp tree.
- Không chạy packaging script vì nó thay app bundle build hiện có. Swift build/test, shell syntax, plist và source review thay thế phần kiểm tra an toàn có thể thực hiện ở checkout này; chưa xác nhận gói release mới chạy được.
- Không chứng nhận kill/power-loss crash recovery, mọi cross-process store race hoặc mọi kích thước terminal ngoài fixtures. CI mới chưa chạy trên GitHub runner trong task này.
- Source là bằng chứng chính khi graph có symbol chưa index hoặc thiếu quan hệ. Impact HIGH/CRITICAL của shared login/store paths đã được thông báo trước sửa; không coi kết quả graph rỗng là chứng minh không có callers. Analyzer có cảnh báo giới hạn extraction/flow traversal; graph counts là phạm vi đo được, không phải chứng minh mọi flow đều đã được map.
- Mọi bản sửa ở working tree, chưa commit, push, merge hay deploy. Không đổi branch/HEAD hoặc credential thật.
