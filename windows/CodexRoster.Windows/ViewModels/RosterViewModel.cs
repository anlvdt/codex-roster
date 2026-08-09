using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using CodexRoster.Windows.Models;
using CodexRoster.Windows.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace CodexRoster.Windows.ViewModels;

public sealed class RosterViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly CodexRosterCli _cli = new();
    private readonly GitHubUpdater _updater = new();
    private readonly ResetNotifier _resetNotifier = new();
    private readonly DispatcherQueue? _dispatcher;
    private readonly DispatcherQueueTimer? _quotaTimer;
    private readonly DispatcherQueueTimer? _updateTimer;
    private readonly DispatcherQueueTimer? _resetTimer;
    private List<AccountDto> _lastAccounts = [];
    private int _accountSortMode;
    private bool _isBusy;
    private bool _autoQuotaRefresh;
    private bool _autoSwitchWhenExhausted;
    private bool _launchAtLogin;
    private bool _isCheckingAutoSwitch;
    private bool _autoSwitchAllExhaustedNotified;
    private bool _isRefreshingInsights;
    private bool _isCheckingUpdate;
    private bool _isShowingDemoData;
    private bool _settingsLoaded;
    private CancellationTokenSource? _loginWatchCancellation;
    private IdentityDto? _pendingLoginIdentity;
    private string? _expectedLoginEmail;
    private bool _isAddAccountSession;
    private string _errorMessage = string.Empty;
    private string _errorTitle = "Không thể hoàn tất";
    private string _currentAccountLabel = "Chưa đăng nhập";
    private string _currentAccountDetail = "quota và reset được cập nhật qua OpenAI";
    private string _quotaRefreshStatus = "Tắt";
    private string _autoSwitchStatus = "Tắt";
    private string _loginStatus = "Đăng nhập một tài khoản mới, rồi Roster sẽ nhận diện phiên để bạn lưu an toàn.";
    private string _processSafetyStatus = "Sẵn sàng chuyển tài khoản";
    private string _tokenUsageToday = "—";
    private string _tokenUsageLast7Days = "—";
    private string _tokenUsageLast30Days = "—";
    private string _tokenUsageLast365Days = "—";
    private string _openAiStatusSummary = "Chưa cập nhật trạng thái OpenAI.";
    private string _resetOutlookSummary = "Chưa cập nhật dự báo reset.";
    private string _updateStatus = "Chưa kiểm tra bản cập nhật.";
    private GitHubUpdater.Update? _availableUpdate;

    public ObservableCollection<AccountItem> Accounts { get; } = [];
    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? ReloginCompleted;

    public int SavedAccountCount => Accounts.Count(account => !account.IsArchived);
    public int ReadyAccountCount => Accounts.Count(account => account.IsReady);
    public string CurrentAccountLabel { get => _currentAccountLabel; private set => Set(ref _currentAccountLabel, value); }
    public string CurrentAccountDetail { get => _currentAccountDetail; private set => Set(ref _currentAccountDetail, value); }
    public string ErrorTitle { get => _errorTitle; private set => Set(ref _errorTitle, value); }
    public string ErrorMessage { get => _errorMessage; private set { Set(ref _errorMessage, value); OnPropertyChanged(nameof(HasError)); } }
    public bool HasError => !string.IsNullOrWhiteSpace(ErrorMessage);
    public bool IsBusy { get => _isBusy; private set { Set(ref _isBusy, value); OnPropertyChanged(nameof(BusyVisibility)); OnPropertyChanged(nameof(CanChangeAutoSwitch)); } }
    public Visibility BusyVisibility => IsBusy ? Visibility.Visible : Visibility.Collapsed;
    public Visibility EmptyAccountsVisibility => Accounts.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility AccountsListVisibility => Accounts.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    public bool IsPendingLogin => _isAddAccountSession;
    public Visibility PendingLoginVisibility => _isAddAccountSession ? Visibility.Visible : Visibility.Collapsed;
    public bool AutoQuotaRefresh { get => _autoQuotaRefresh; set => Set(ref _autoQuotaRefresh, value); }
    public bool AutoSwitchWhenExhausted
    {
        get => _autoSwitchWhenExhausted;
        set
        {
            if (_autoSwitchWhenExhausted == value) return;
            _autoSwitchWhenExhausted = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(AutoSwitchActionsVisibility));
            OnPropertyChanged(nameof(CanChangeAutoSwitch));
        }
    }
    public bool LaunchAtLogin { get => _launchAtLogin; set => Set(ref _launchAtLogin, value); }
    public string QuotaRefreshStatus { get => _quotaRefreshStatus; private set => Set(ref _quotaRefreshStatus, value); }
    public string AutoSwitchStatus { get => _autoSwitchStatus; private set => Set(ref _autoSwitchStatus, value); }
    public Visibility AutoSwitchActionsVisibility => AutoSwitchWhenExhausted ? Visibility.Visible : Visibility.Collapsed;
    public bool CanChangeAutoSwitch => _settingsLoaded && !IsBusy && !_isCheckingAutoSwitch;
    public string LoginStatus { get => _loginStatus; private set { Set(ref _loginStatus, value); OnPropertyChanged(nameof(CanSaveDetectedLogin)); } }
    public bool CanSaveDetectedLogin => _pendingLoginIdentity is not null;
    public string ProcessSafetyStatus { get => _processSafetyStatus; private set => Set(ref _processSafetyStatus, value); }
    public string TokenUsageToday { get => _tokenUsageToday; private set => Set(ref _tokenUsageToday, value); }
    public string TokenUsageLast7Days { get => _tokenUsageLast7Days; private set => Set(ref _tokenUsageLast7Days, value); }
    public string TokenUsageLast30Days { get => _tokenUsageLast30Days; private set => Set(ref _tokenUsageLast30Days, value); }
    public string TokenUsageLast365Days { get => _tokenUsageLast365Days; private set => Set(ref _tokenUsageLast365Days, value); }
    public string OpenAiStatusSummary { get => _openAiStatusSummary; private set => Set(ref _openAiStatusSummary, value); }
    public string ResetOutlookSummary { get => _resetOutlookSummary; private set => Set(ref _resetOutlookSummary, value); }
    public string UpdateStatus { get => _updateStatus; private set => Set(ref _updateStatus, value); }
    public string UpdateActionLabel => _availableUpdate is null ? "Kiểm tra cập nhật" : $"Cài v{_availableUpdate.Version}";
    public bool IsShowingDemoData { get => _isShowingDemoData; private set => Set(ref _isShowingDemoData, value); }

    public RosterViewModel()
    {
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        _quotaTimer = _dispatcher?.CreateTimer();
        if (_quotaTimer is not null)
        {
            _quotaTimer.Interval = TimeSpan.FromMinutes(1);
            _quotaTimer.Tick += async (_, _) => await RunQuotaTimerAsync();
        }
        _updateTimer = _dispatcher?.CreateTimer();
        if (_updateTimer is not null)
        {
            _updateTimer.Interval = TimeSpan.FromHours(6);
            _updateTimer.Tick += async (_, _) => await CheckForUpdatesAsync(silent: true);
        }
        _resetTimer = _dispatcher?.CreateTimer();
        if (_resetTimer is not null)
        {
            _resetTimer.Interval = TimeSpan.FromMinutes(1);
            _resetTimer.Tick += async (_, _) => await CheckForResetNotificationsAsync();
        }
    }

    public async Task InitializeAsync()
    {
        try
        {
            var addAccount = await _cli.ReadAsync<AddAccountStatusResponse>("add-account-status");
            _isAddAccountSession = addAccount.Active;
            NotifyPendingLoginChanged();
            if (addAccount.Active)
            {
                LoginStatus = "Đang chờ Codex ghi credential mới. Hoàn tất đăng nhập hoặc hủy để khôi phục phiên trước.";
                IdentityDto? current = null;
                try { current = (await _cli.ReadAsync<StatusResponse>("status")).CurrentAccount; }
                catch { /* watcher below will retry */ }
                if (addAccount.AuthChanged && current is not null)
                {
                    _pendingLoginIdentity = current;
                    LoginStatus = $"Đã nhận diện {current.Email}. Roster đang tự động lưu phiên.";
                    NotifyPendingLoginChanged();
                }
                WatchForNewLoginAsync(null);
            }
        }
        catch
        {
            // The session-state check is advisory; do not block startup if unavailable.
        }
        try
        {
            var recovery = await _cli.ReadAsync<LegacyRecoveryResponse>("recover-legacy-snapshots");
            var restored = recovery.RecoveredAccounts + recovery.ImportedAccounts;
            if (restored > 0) QuotaRefreshStatus = $"Đã nhập {restored} phiên từ bản legacy.";
        }
        catch
        {
            // Legacy data is optional; current sessions remain usable without it.
        }
        await RefreshAsync();
        try
        {
            var settings = await _cli.ReadAsync<AutoQuotaSettings>("auto-start-usage-windows");
            var autoSwitch = await _cli.ReadAsync<AutoSwitchOutput>("auto-switch", "--status");
            AutoQuotaRefresh = settings.Enabled;
            AutoSwitchWhenExhausted = autoSwitch.Enabled;
            LaunchAtLogin = WindowsStartup.IsEnabled;
            AutoSwitchStatus = autoSwitch.Enabled
                ? "Đã bật — Roster sẽ chuyển khi tài khoản hiện tại hết quota."
                : "Tắt";
            UpdateQuotaTimer();
            _settingsLoaded = true;
            OnPropertyChanged(nameof(CanChangeAutoSwitch));
            if (AutoQuotaRefresh) await RefreshActiveQuotaAsync(silent: true);
            if (AutoSwitchWhenExhausted) await CheckAutoSwitchAsync(silent: true);
        }
        catch
        {
            // The roster remains usable if the legacy preference has not been created yet.
        }
        if (_pendingLoginIdentity is not null)
        {
            await SaveCurrentAccountAsync();
        }
        _ = CreateAutomaticBackupAsync();
        _ = RefreshInsightsAsync(silent: true);
        _ = CheckForUpdatesAsync(silent: true);
        _resetNotifier.Register();
        await CheckForResetNotificationsAsync();
        _resetTimer?.Start();
        _updateTimer?.Start();
    }

    public async Task RefreshAsync()
    {
        IsShowingDemoData = false;
        await RunAsync(async () =>
        {
            var listTask = _cli.ReadAsync<AccountListResponse>("list");
            var statusTask = _cli.ReadAsync<StatusResponse>("status");
            await Task.WhenAll(listTask, statusTask);
            ReplaceAccounts(listTask.Result.Accounts);
            CurrentAccountLabel = statusTask.Result.CurrentAccount?.Email
                ?? Accounts.FirstOrDefault(account => account.IsActive)?.Email
                ?? "Chưa đăng nhập";
            ProcessSafetyStatus = statusTask.Result.ProcessWarnings.Count == 0
                ? "Sẵn sàng chuyển tài khoản"
                : $"Phát hiện {statusTask.Result.ProcessWarnings.Count} tiến trình Codex đang chạy";
        });
    }

    public async Task RefreshAllQuotaAsync()
    {
        await RunAsync(async () =>
        {
            var targets = Accounts.Where(account => !account.IsArchived).ToList();
            var failures = 0;
            foreach (var account in targets)
            {
                try
                {
                    if (account.IsActive)
                    {
                        await _cli.RunCommandAsync("usage");
                    }
                    else
                    {
                        await _cli.RunCommandAsync("usage", account.Id.ToString());
                    }
                }
                catch
                {
                    failures++;
                }
            }

            await RefreshRosterDataAsync();
            if (failures == 0)
            {
                QuotaRefreshStatus = $"Đã kiểm tra toàn bộ lúc {DateTime.Now:t}";
                return;
            }

            ErrorTitle = "Quota chưa đủ";
            ErrorMessage = failures == targets.Count
                ? "Không thể xác minh quota lúc này. Roster vẫn giữ dữ liệu tốt gần nhất; chỉ đăng nhập lại account có nhãn Cần đăng nhập."
                : $"Đã cập nhật một phần: {targets.Count - failures}/{targets.Count} tài khoản. Dữ liệu tốt gần nhất được giữ cho phần còn lại.";
            QuotaRefreshStatus = $"Đã kiểm tra một phần lúc {DateTime.Now:t}";
        });
    }

    public void ClearError()
    {
        ErrorMessage = string.Empty;
        ErrorTitle = "Không thể hoàn tất";
    }

    public void SetAccountSortMode(int selectedIndex)
    {
        if (selectedIndex is < 0 or > 3 || _accountSortMode == selectedIndex) return;
        _accountSortMode = selectedIndex;
        ReplaceAccounts(_lastAccounts);
    }

    public void LoadDemoData()
    {
        var now = DateTimeOffset.Now;
        ReplaceAccounts([
            new AccountDto
            {
                Id = Guid.Parse("91ed4457-534e-4da7-b6a0-573aaea78902"),
                Email = "mai.nguyen@example.com",
                Name = "Mai Nguyen",
                CustomLabel = "Pro · cá nhân",
                PlanLabel = "Pro",
                IsActive = true,
                Usage = new AccountUsageDto
                {
                    FiveHour = new UsageWindowDto { RemainingPercent = 72, ResetAt = now.AddHours(2.5) },
                    Weekly = new UsageWindowDto { RemainingPercent = 64, ResetAt = now.AddDays(3).AddHours(4) },
                },
            },
            new AccountDto
            {
                Id = Guid.Parse("98dc73c1-821c-498e-a113-1ba51c36b137"),
                Email = "team@example.com",
                Name = "OpenAI Team",
                CustomLabel = "Plus · công việc",
                PlanLabel = "Plus",
                Usage = new AccountUsageDto
                {
                    FiveHour = new UsageWindowDto { RemainingPercent = 38, ResetAt = now.AddHours(4) },
                    Weekly = new UsageWindowDto { RemainingPercent = 41, ResetAt = now.AddDays(2).AddHours(8) },
                },
            },
            new AccountDto
            {
                Id = Guid.Parse("4aef9af1-bcf1-4a3e-aa39-724f2d2a29ce"),
                Email = "archive@example.com",
                Name = "Tài khoản cần xử lý",
                PlanLabel = "Free",
                UsageError = "Session expired",
            },
        ]);
        CurrentAccountLabel = "mai.nguyen@example.com";
        CurrentAccountDetail = "Dữ liệu mẫu · 64% quota theo chu kỳ, reset lúc " + now.AddDays(3).AddHours(4).ToLocalTime().ToString("HH:mm · dd/MM");
        ProcessSafetyStatus = "Dữ liệu mẫu chỉ dùng để xem giao diện";
        IsShowingDemoData = true;
    }

    public async Task StartDeviceLoginAsync()
    {
        await StartLoginAsync(expectedEmail: null);
    }

    public async Task StartReloginAsync(AccountItem account)
    {
        await StartLoginAsync(account.Email);
    }

    private async Task StartLoginAsync(string? expectedEmail)
    {
        await RunAsync(async () =>
        {
            // Login is explicit and keeps Desktop open. Roster pauses automatic
            // switching and quota work until the new credential is verified.
            var addStatus = await _cli.ReadAsync<AddAccountStatusResponse>("add-account-status");
            if (addStatus.Active || _isAddAccountSession)
            {
                await ResumePendingLoginAsync(expectedEmail);
                return;
            }

            var status = await _cli.ReadAsync<StatusResponse>("status");
            var began = false;
            try
            {
                await _cli.RunCommandAsync("begin-add-account");
                began = true;
                CodexLoginLauncher.Start();
                _isAddAccountSession = true;
                _pendingLoginIdentity = null;
                _expectedLoginEmail = expectedEmail;
                NotifyPendingLoginChanged();
                LoginStatus = expectedEmail is null
                    ? "Phiên cũ đã được bảo toàn. Hoàn tất đăng nhập; Roster sẽ tự nhận diện và lưu phiên mới."
                    : $"Phiên cũ đã được bảo toàn. Đăng nhập đúng {expectedEmail}; Roster sẽ tự xác minh và lưu.";
                WatchForNewLoginAsync(status.CurrentAccount);
            }
            catch
            {
                if (began)
                {
                    try { await _cli.RunCommandAsync("cancel-add-account"); }
                    catch { /* best-effort rollback so the next Add is not stuck */ }
                    _isAddAccountSession = false;
                    _pendingLoginIdentity = null;
                    _expectedLoginEmail = null;
                    _loginWatchCancellation?.Cancel();
                    NotifyPendingLoginChanged();
                }
                throw;
            }
        });
    }

    private async Task ResumePendingLoginAsync(string? expectedEmail)
    {
        IdentityDto? previous = null;
        try { previous = (await _cli.ReadAsync<StatusResponse>("status")).CurrentAccount; }
        catch { /* watcher will retry */ }
        CodexLoginLauncher.Start();
        _isAddAccountSession = true;
        _expectedLoginEmail = expectedEmail;
        NotifyPendingLoginChanged();
        LoginStatus = expectedEmail is null
            ? "Phiên thêm tài khoản vẫn đang mở. Hoàn tất đăng nhập; Roster sẽ tự lưu, hoặc chọn Hủy để khôi phục phiên trước."
            : $"Phiên đăng nhập lại vẫn đang mở. Đăng nhập đúng {expectedEmail}; Roster sẽ tự lưu, hoặc chọn Hủy.";
        WatchForNewLoginAsync(previous);
    }

    public async Task SaveCurrentAccountAsync()
    {
        var expectedReloginEmail = _expectedLoginEmail;
        var completedRelogin = expectedReloginEmail is not null;
        await RunAsync(async () =>
        {
            var current = await _cli.ReadAsync<StatusResponse>("status");
            if (_isAddAccountSession)
            {
                if (_pendingLoginIdentity is null || current.CurrentAccount is null)
                {
                    throw new InvalidOperationException("Roster chưa nhận diện phiên đăng nhập mới. Hoàn tất đăng nhập OpenAI rồi chờ nhận diện trước khi lưu.");
                }
                if (!SameIdentity(current.CurrentAccount, _pendingLoginIdentity))
                {
                    throw new InvalidOperationException("Phiên Codex đã thay đổi. Hãy để Roster nhận diện lại tài khoản mới trước khi lưu.");
                }
            }
            else if (_pendingLoginIdentity is not null)
            {
                if (current.CurrentAccount is null || !SameIdentity(current.CurrentAccount, _pendingLoginIdentity))
                {
                    throw new InvalidOperationException("Phiên Codex đã thay đổi. Hãy để Roster nhận diện lại tài khoản mới trước khi lưu.");
                }
            }
            if (_expectedLoginEmail is not null)
            {
                if (current.CurrentAccount is null || !string.Equals(current.CurrentAccount.Email, _expectedLoginEmail, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException($"Phiên hiện tại không phải {_expectedLoginEmail}. Hãy đăng nhập đúng tài khoản rồi thử lại.");
                }
            }
            var savedLocally = false;
            try
            {
                var saved = await _cli.ReadAsync<SaveAccountResponse>(
                    _isAddAccountSession ? "save-added-account" : "save");
                savedLocally = true;
                // Saving is only local evidence. Require a successful server
                // request for both new accounts and relogins.
                await _cli.RunCommandAsync("usage", saved.Account.Id.ToString());
            }
            catch
            {
                if (savedLocally && _isAddAccountSession)
                {
                    CodexLoginLauncher.Stop();
                    _isAddAccountSession = false;
                    _pendingLoginIdentity = null;
                    _expectedLoginEmail = null;
                    _loginWatchCancellation?.Cancel();
                    NotifyPendingLoginChanged();
                    try { await RefreshRosterDataAsync(); }
                    catch { /* the original verification error is authoritative */ }
                }
                throw;
            }
            if (_isAddAccountSession)
            {
                CodexLoginLauncher.Stop();
                _isAddAccountSession = false;
            }
            _pendingLoginIdentity = null;
            _expectedLoginEmail = null;
            _loginWatchCancellation?.Cancel();
            NotifyPendingLoginChanged();
            LoginStatus = "Đã lưu phiên Codex hiện tại.";
            await RefreshRosterDataAsync();
        });
        if (completedRelogin && !IsPendingLogin && !HasError)
        {
            ReloginCompleted?.Invoke(this, EventArgs.Empty);
        }
    }

    public async Task CancelPendingLoginAsync()
    {
        await RunAsync(async () =>
        {
            CodexLoginLauncher.Stop();
            await _cli.RunCommandAsync("cancel-add-account");
            _isAddAccountSession = false;
            _pendingLoginIdentity = null;
            _expectedLoginEmail = null;
            _loginWatchCancellation?.Cancel();
            NotifyPendingLoginChanged();
            LoginStatus = "Đã khôi phục phiên Codex trước khi thêm tài khoản.";
            await RefreshRosterDataAsync();
        });
    }

    public async Task SetCustomLabelAsync(AccountItem account, string label)
    {
        await RunAsync(async () =>
        {
            await _cli.RunCommandAsync("set-label", account.Id.ToString(), label.Trim());
            await RefreshRosterDataAsync();
        });
    }

    public async Task DeleteAsync(AccountItem account)
    {
        await RunAsync(async () =>
        {
            await _cli.RunCommandAsync("delete", account.Id.ToString());
            await RefreshRosterDataAsync();
        });
    }

    public async Task DeleteAsync(IReadOnlyList<AccountItem> accounts)
    {
        var targets = accounts.Where(account => !account.IsActive).ToList();
        if (targets.Count == 0) return;
        await RunAsync(async () =>
        {
            var failures = 0;
            foreach (var account in targets)
            {
                try { await _cli.RunCommandAsync("delete", account.Id.ToString()); }
                catch { failures++; }
            }
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = failures == 0
                ? $"Đã xóa {targets.Count} tài khoản khỏi Roster."
                : $"Đã xóa {targets.Count - failures}/{targets.Count} tài khoản.";
        });
    }

    public async Task RefreshAccountsQuotaAsync(IReadOnlyList<AccountItem> accounts)
    {
        var targets = accounts.Where(account =>
            !account.IsArchived && !account.NeedsRelogin && !account.NeedsLocalRecovery).ToList();
        if (targets.Count == 0) return;
        await RunAsync(async () =>
        {
            var failures = 0;
            foreach (var account in targets)
            {
                try
                {
                    await _cli.RunCommandAsync("usage", account.Id.ToString());
                }
                catch
                {
                    failures++;
                }
            }
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = failures == 0
                ? $"Đã xác minh {targets.Count} tài khoản lúc {DateTime.Now:t}."
                : $"Đã xác minh {targets.Count - failures}/{targets.Count}; giữ dữ liệu tốt gần nhất cho phần còn lại.";
        });
    }

    public async Task ExportBackupAsync(string path, string password)
    {
        await RunAsync(async () =>
        {
            await _cli.RunCommandWithInputAsync(password + Environment.NewLine, "export", path, "--password-stdin");
            QuotaRefreshStatus = "Đã xuất bản sao lưu mã hóa.";
        });
    }

    public async Task ImportAccountsFromJsonAsync(string path, string? label)
    {
        await RunAsync(async () =>
        {
            var args = new List<string> { "import-json", path };
            if (!string.IsNullOrWhiteSpace(label))
            {
                args.Add("--label");
                args.Add(label.Trim());
            }
            var result = await _cli.ReadAsync<ImportJsonResponse>(args.ToArray());
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = result.Created + result.Updated == 1
                ? $"Đã nhập {result.Accounts.FirstOrDefault()?.Email ?? "tài khoản"} từ JSON ({result.Format})."
                : $"Đã nhập {result.Created + result.Updated} tài khoản từ JSON ({result.Format}).";
        });
    }

    public async Task ImportBackupAsync(string path, string password)
    {
        await RunAsync(async () =>
        {
            await _cli.RunCommandWithInputAsync(password + Environment.NewLine, "import", path, "--password-stdin");
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = "Đã nhập bản sao lưu mã hóa.";
        });
    }

    public async Task RefreshInsightsAsync(bool silent = false)
    {
        if (_isRefreshingInsights) return;
        _isRefreshingInsights = true;
        try
        {
            var tokenTask = _cli.ReadAsync<TokenUsageSummaryDto>("token-usage");
            var outlookTask = _cli.ReadAsync<ResetOutlookDto>("reset-outlook");
            var statusTask = _cli.ReadAsync<OpenAiStatusDto>("open-ai-status");
            await Task.WhenAll(tokenTask, outlookTask, statusTask);
            var tokens = tokenTask.Result;
            TokenUsageToday = FormatTokens(tokens.Today);
            TokenUsageLast7Days = FormatTokens(tokens.Last7Days);
            TokenUsageLast30Days = FormatTokens(tokens.Last30Days);
            TokenUsageLast365Days = FormatTokens(tokens.Last365Days);
            var outlook = outlookTask.Result;
            ResetOutlookSummary = $"{outlook.Chance24Hours}% trong 24 giờ · {outlook.Chance48Hours}% trong 48 giờ · {outlook.WindowLabel}";
            var openAi = statusTask.Result;
            OpenAiStatusSummary = string.IsNullOrWhiteSpace(openAi.Description)
                ? "Trạng thái OpenAI chưa có mô tả."
                : openAi.Description;
        }
        catch when (silent)
        {
            // Public status services are optional; retain the last successful data.
        }
        catch
        {
            ErrorMessage = "Không thể cập nhật thống kê token hoặc trạng thái dịch vụ.";
        }
        finally
        {
            _isRefreshingInsights = false;
        }
    }

    public async Task CheckForUpdatesAsync(bool silent = false)
    {
        if (_isCheckingUpdate) return;
        _isCheckingUpdate = true;
        try
        {
            UpdateStatus = "Đang kiểm tra GitHub Release…";
            var update = await _updater.CheckAsync(CurrentVersion);
            _availableUpdate = update;
            UpdateStatus = update is null
                ? $"Bạn đang dùng phiên bản mới nhất (v{CurrentVersion})."
                : $"Đã có Codex Roster v{update.Version}. SHA-256 sẽ được xác thực trước khi cài.";
            OnPropertyChanged(nameof(UpdateActionLabel));
        }
        catch when (silent)
        {
            UpdateStatus = "Không thể kiểm tra cập nhật lúc này.";
        }
        catch
        {
            UpdateStatus = "Không thể cập nhật. Phiên bản hiện tại vẫn không thay đổi.";
            ErrorMessage = "Không thể kiểm tra hoặc cài bản cập nhật từ GitHub.";
        }
        finally
        {
            _isCheckingUpdate = false;
        }
    }

    public async Task InstallAvailableUpdateAsync()
    {
        if (_availableUpdate is null)
        {
            await CheckForUpdatesAsync();
            return;
        }
        if (_isCheckingUpdate) return;
        _isCheckingUpdate = true;
        try
        {
            UpdateStatus = $"Đang tải Codex Roster v{_availableUpdate.Version}…";
            var stage = await _updater.DownloadAndStageAsync(_availableUpdate);
            UpdateStatus = "Đang dừng companion nền và cài bản cập nhật…";
            _updater.ScheduleInstall(stage);
            UpdateStatus = "Đang cài bản cập nhật và mở lại Codex Roster…";
            Microsoft.UI.Xaml.Application.Current.Exit();
        }
        catch (Exception exception)
        {
            UpdateStatus = "Không thể cài cập nhật. Phiên bản hiện tại vẫn không thay đổi.";
            ErrorMessage = string.IsNullOrWhiteSpace(exception.Message)
                ? "Không thể tải hoặc cài bản cập nhật từ GitHub."
                : exception.Message;
        }
        finally
        {
            _isCheckingUpdate = false;
        }
    }

    public async Task RestoreLatestFullBackupAsync()
    {
        await RunAsync(async () =>
        {
            await _cli.RunCommandAsync("restore-full-backup");
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = "Đã khôi phục phiên từ bản sao lưu tự động đầy nhất.";
        });
    }

    public async Task RestoreLatestAccountListBackupAsync()
    {
        await RunAsync(async () =>
        {
            await _cli.RunCommandAsync("restore-account-list-backup");
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = "Đã khôi phục danh sách từ bản sao lưu metadata gần nhất.";
        });
    }

    public async Task ActivateAsync(AccountItem account, bool restartDesktop)
    {
        await RunAsync(async () =>
        {
            var relaunch = restartDesktop
                ? await CodexDesktopLifecycle.CloseForAccountSwitchAsync()
                : new CodexDesktopRestartPlan([]);
            ActivateOutput activated;
            try
            {
                // Never force through a surviving Desktop helper or independent
                // Codex CLI process. Core preflight leaves the current auth intact.
                activated = await _cli.ReadAsync<ActivateOutput>("activate", account.Id.ToString());
            }
            catch
            {
                relaunch.Restart();
                throw;
            }
            relaunch.Restart();
            if (relaunch.HasDesktop && !await WaitForDesktopAcceptanceAsync(account.Id))
            {
                try
                {
                    await RollbackRejectedTargetAsync(
                        account.Id,
                        activated.PreviousAccountId,
                        relaunch);
                    await RefreshRosterDataAsync();
                }
                catch (Exception rollbackError)
                {
                    throw new InvalidOperationException(
                        $"Codex Desktop từ chối tài khoản đích và không thể tự khôi phục phiên trước: {rollbackError.Message}",
                        rollbackError);
                }
                throw new InvalidOperationException(
                    "Codex Desktop từ chối tài khoản đích; phiên trước đã được khôi phục an toàn.");
            }
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = relaunch.HasDesktop
                ? "Đã chuyển phiên và mở lại Codex Desktop với session mới."
                : "Đã chuyển phiên Codex.";
        });
    }

    public bool IsCodexDesktopRunning() => CodexDesktopLifecycle.IsRunning();

    public async Task<IReadOnlyList<RunningProcessDto>> GetProcessWarningsAsync()
    {
        var status = await _cli.ReadAsync<StatusResponse>("status");
        return status.ProcessWarnings;
    }

    public async Task ToggleArchiveAsync(AccountItem account)
    {
        await RunAsync(async () =>
        {
            if (account.IsArchived)
            {
                await _cli.RunCommandAsync("archive", account.Id.ToString(), "--restore");
            }
            else
            {
                await _cli.RunCommandAsync("archive", account.Id.ToString());
            }
            await RefreshRosterDataAsync();
        });
    }

    public async Task SetArchivedAsync(IReadOnlyList<AccountItem> accounts, bool archived)
    {
        var targets = accounts.Where(account =>
            account.IsArchived != archived && !account.IsActive).ToList();
        if (targets.Count == 0) return;
        await RunAsync(async () =>
        {
            var failures = 0;
            foreach (var account in targets)
            {
                try
                {
                    if (archived)
                    {
                        await _cli.RunCommandAsync("archive", account.Id.ToString());
                    }
                    else
                    {
                        await _cli.RunCommandAsync("archive", account.Id.ToString(), "--restore");
                    }
                }
                catch
                {
                    failures++;
                }
            }
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = failures == 0
                ? $"Đã {(archived ? "lưu trữ" : "khôi phục")} {targets.Count} tài khoản."
                : $"Đã xử lý {targets.Count - failures}/{targets.Count} tài khoản.";
        });
    }

    public async Task SetAutoQuotaRefreshAsync()
    {
        if (!_settingsLoaded) return;
        await RunAsync(async () =>
        {
            await _cli.RunCommandAsync("auto-start-usage-windows", AutoQuotaRefresh ? "--enable" : "--disable");
            UpdateQuotaTimer();
            if (AutoQuotaRefresh) await RefreshActiveQuotaAsync(silent: true);
        });
    }

    public async Task SetAutoSwitchWhenExhaustedAsync()
    {
        if (!_settingsLoaded) return;
        await RunAsync(async () =>
        {
            await _cli.RunCommandAsync("auto-switch", AutoSwitchWhenExhausted ? "--enable" : "--disable");
            _autoSwitchAllExhaustedNotified = false;
            UpdateQuotaTimer();
            if (AutoSwitchWhenExhausted)
            {
                AutoSwitchStatus = "Đã bật — đang kiểm tra điều kiện chuyển…";
                await CheckAutoSwitchAsync(silent: true);
            }
            else
            {
                AutoSwitchStatus = "Tắt";
            }
        });
    }

    public async Task RunAutoSwitchCheckAsync()
    {
        if (!AutoSwitchWhenExhausted || !_settingsLoaded) return;
        await CheckAutoSwitchAsync(silent: false);
    }

    public async Task SetLaunchAtLoginAsync()
    {
        if (!_settingsLoaded) return;
        try
        {
            WindowsStartup.SetEnabled(LaunchAtLogin);
        }
        catch
        {
            LaunchAtLogin = WindowsStartup.IsEnabled;
            ErrorMessage = "Không thể cập nhật cài đặt mở Codex Roster khi đăng nhập Windows.";
        }
        await Task.CompletedTask;
    }

    private async Task RefreshActiveQuotaAsync(bool silent)
    {
        if (!AutoQuotaRefresh || IsBusy || _isAddAccountSession) return;
        var active = Accounts.FirstOrDefault(account => account.IsActive && !account.IsArchived);
        if (active is null) return;
        try
        {
            await _cli.RunCommandAsync("usage");
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = $"Đã cập nhật lúc {DateTime.Now:t}";
        }
        catch when (silent)
        {
            QuotaRefreshStatus = "Đang giữ quota đã xác minh gần nhất.";
        }
        catch
        {
            ErrorMessage = "Không thể cập nhật quota tài khoản hiện tại.";
        }
    }

    private async Task RefreshRosterQuotaAsync(bool silent)
    {
        if (IsBusy || _isAddAccountSession) return;
        try
        {
            // Re-query the active account plus any stale saved account so an
            // off-schedule ChatGPT reset surfaces across the whole roster.
            await _cli.RunCommandAsync("refresh-usage");
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = $"Đã cập nhật lúc {DateTime.Now:t}";
        }
        catch when (silent)
        {
            QuotaRefreshStatus = "Đang giữ quota đã xác minh gần nhất.";
        }
        catch
        {
            ErrorMessage = "Không thể cập nhật quota.";
        }
    }

    private async Task RunQuotaTimerAsync()
    {
        if (IsBusy) return;
        if (AutoQuotaRefresh) await RefreshRosterQuotaAsync(silent: true);
        if (AutoSwitchWhenExhausted) await CheckAutoSwitchAsync(silent: true);
    }

    private async Task CheckForResetNotificationsAsync()
    {
        if (!_resetNotifier.IsAvailable) return;
        try
        {
            var resets = await _cli.ReadAsync<List<GlobalResetEventDto>>("reset-events");
            foreach (var reset in resets) _resetNotifier.Show(reset);
        }
        catch
        {
            // Community reset tracking is advisory and retries on the next poll.
        }
    }

    private async Task CheckAutoSwitchAsync(bool silent)
    {
        if (!AutoSwitchWhenExhausted || IsBusy || _isCheckingAutoSwitch) return;
        if (_isAddAccountSession)
        {
            AutoSwitchStatus = "Đang chờ hoàn tất đăng nhập — tạm hoãn tự động chuyển.";
            return;
        }

        _isCheckingAutoSwitch = true;
        OnPropertyChanged(nameof(CanChangeAutoSwitch));
        try
        {
            var decision = await _cli.ReadAsync<AutoSwitchOutput>("auto-switch");
            if (decision.Status == "active_has_quota")
            {
                _autoSwitchAllExhaustedNotified = false;
                AutoSwitchStatus = "Tài khoản hiện tại còn quota — chưa cần chuyển.";
                return;
            }
            if (decision.Status == "waiting_for_login")
            {
                AutoSwitchStatus = "Chưa có phiên Codex đang đăng nhập để tự động chuyển.";
                return;
            }
            if (decision.Status == "all_accounts_exhausted")
            {
                if (!_autoSwitchAllExhaustedNotified || !silent)
                {
                    AutoSwitchStatus = "Tất cả tài khoản đã hết quota; tự động chuyển sẽ thử lại sau.";
                    _autoSwitchAllExhaustedNotified = true;
                }
                return;
            }
            if (decision.Status == "disabled")
            {
                AutoSwitchWhenExhausted = false;
                AutoSwitchStatus = "Tắt";
                UpdateQuotaTimer();
                return;
            }
            if (decision.Status != "ready")
            {
                AutoSwitchStatus = "Tự động chuyển đang chờ phiên Codex an toàn.";
                return;
            }

            var applyArgs = new List<string> { "auto-switch", "--apply" };
            if (decision.CandidateAccountId is Guid candidateId)
            {
                applyArgs.Add("--account-id");
                applyArgs.Add(candidateId.ToString());
            }

            var relaunch = new CodexDesktopRestartPlan([]);
            var closedDesktop = false;
            if (CodexDesktopLifecycle.IsRunning())
            {
                AutoSwitchStatus = "Đang đóng Codex Desktop trước khi tự động chuyển…";
                relaunch = await CodexDesktopLifecycle.CloseForAccountSwitchAsync();
                closedDesktop = true;
                // A lingering helper or independent CLI must keep blocking the
                // swap; forcing through it can rewrite the newly restored auth.
            }

            AutoSwitchOutput applied;
            try
            {
                AutoSwitchStatus = $"Đang chuyển sang {decision.CandidateDisplayName ?? "tài khoản khác"}…";
                applied = await _cli.ReadAsync<AutoSwitchOutput>(applyArgs.ToArray());
                if (applied.Status == "waiting_for_processes" && closedDesktop && !CodexDesktopLifecycle.IsRunning())
                {
                    for (var attempt = 0; attempt < 3 && applied.Status == "waiting_for_processes"; attempt++)
                    {
                        await Task.Delay(150);
                        applied = await _cli.ReadAsync<AutoSwitchOutput>(applyArgs.ToArray());
                    }
                }
            }
            catch
            {
                relaunch.Restart();
                throw;
            }

            if (applied.Status == "switched")
            {
                relaunch.Restart();
                var accepted = !relaunch.HasDesktop;
                if (relaunch.HasDesktop && applied.CandidateAccountId is Guid switchedAccountId)
                {
                    accepted = await WaitForDesktopAcceptanceAsync(switchedAccountId);
                }
                if (!accepted)
                {
                    try
                    {
                        await RollbackRejectedTargetAsync(
                            applied.CandidateAccountId,
                            applied.ActiveAccountId ?? decision.ActiveAccountId,
                            relaunch);
                        await RefreshRosterDataAsync();
                        AutoSwitchStatus = "Codex Desktop từ chối tài khoản tự động chọn; phiên trước đã được khôi phục.";
                        ErrorTitle = "Tự động chuyển";
                        ErrorMessage = AutoSwitchStatus;
                    }
                    catch (Exception rollbackError)
                    {
                        AutoSwitchStatus = "Tài khoản đích bị từ chối và rollback thất bại.";
                        ErrorTitle = "Tự động chuyển";
                        ErrorMessage = $"{AutoSwitchStatus} {rollbackError.Message}";
                    }
                    return;
                }
                await RefreshRosterDataAsync();
                _autoSwitchAllExhaustedNotified = false;
                AutoSwitchStatus = relaunch.HasDesktop
                    ? $"Đã tự động chuyển sang {applied.CandidateDisplayName ?? "tài khoản khác"} và mở lại Codex Desktop."
                    : $"Đã tự động chuyển sang {applied.CandidateDisplayName ?? "tài khoản khác"}.";
                QuotaRefreshStatus = AutoSwitchStatus;
            }
            else if (applied.Status == "waiting_for_processes")
            {
                relaunch.Restart();
                AutoSwitchStatus = "Codex CLI đang chạy — đóng tác vụ CLI rồi để Roster chuyển tự động.";
            }
            else if (applied.Status == "active_has_quota")
            {
                relaunch.Restart();
                AutoSwitchStatus = "Tài khoản hiện tại đã có lại quota trước khi chuyển.";
            }
            else
            {
                relaunch.Restart();
                AutoSwitchStatus = "Không thể tự động chuyển lúc này — sẽ thử lại theo chu kỳ.";
            }
        }
        catch when (silent)
        {
            AutoSwitchStatus = "Tự động chuyển sẽ thử lại sau.";
        }
        catch (Exception exception)
        {
            AutoSwitchStatus = "Kiểm tra tự động chuyển chưa hoàn tất.";
            ErrorTitle = "Tự động chuyển";
            ErrorMessage = string.IsNullOrWhiteSpace(exception.Message)
                ? "Không thể kiểm tra điều kiện tự động chuyển tài khoản."
                : exception.Message;
        }
        finally
        {
            _isCheckingAutoSwitch = false;
            OnPropertyChanged(nameof(CanChangeAutoSwitch));
        }
    }

    private async Task<bool> WaitForDesktopAcceptanceAsync(Guid accountId)
    {
        var launchDeadline = DateTimeOffset.UtcNow.AddSeconds(6);
        while (!CodexDesktopLifecycle.IsRunning() && DateTimeOffset.UtcNow < launchDeadline)
        {
            await Task.Delay(250);
        }
        if (!CodexDesktopLifecycle.IsRunning()) return false;

        // Let the official Desktop auth manager own refresh first. Roster only
        // probes the current access token and never rotates the refresh token.
        await Task.Delay(TimeSpan.FromSeconds(2));
        var acceptanceDeadline = DateTimeOffset.UtcNow.AddSeconds(12);
        while (DateTimeOffset.UtcNow < acceptanceDeadline)
        {
            try
            {
                await _cli.RunCommandAsync("usage", accountId.ToString());
                return true;
            }
            catch
            {
                await Task.Delay(500);
            }
        }
        return false;
    }

    private async Task RollbackRejectedTargetAsync(
        Guid? rejectedAccountId,
        Guid? previousAccountId,
        CodexDesktopRestartPlan fallbackRelaunch)
    {
        if (previousAccountId is not Guid previousId || previousId == rejectedAccountId)
        {
            throw new InvalidOperationException("Không tìm thấy điểm khôi phục của phiên trước.");
        }
        var relaunch = CodexDesktopLifecycle.IsRunning()
            ? await CodexDesktopLifecycle.CloseForAccountSwitchAsync()
            : fallbackRelaunch;
        await _cli.RunCommandAsync("activate", previousId.ToString());
        relaunch.Restart();
    }

    private async Task RefreshRosterDataAsync()
    {
        IsShowingDemoData = false;
        var listTask = _cli.ReadAsync<AccountListResponse>("list");
        var statusTask = _cli.ReadAsync<StatusResponse>("status");
        await Task.WhenAll(listTask, statusTask);
        ReplaceAccounts(listTask.Result.Accounts);
        CurrentAccountLabel = statusTask.Result.CurrentAccount?.Email
            ?? Accounts.FirstOrDefault(account => account.IsActive)?.Email
            ?? "Chưa đăng nhập";
        ProcessSafetyStatus = statusTask.Result.ProcessWarnings.Count == 0
            ? "Sẵn sàng chuyển tài khoản"
            : $"Phát hiện {statusTask.Result.ProcessWarnings.Count} tiến trình Codex đang chạy";
    }

    private void ReplaceAccounts(IEnumerable<AccountDto> accounts)
    {
        _lastAccounts = accounts.ToList();
        Accounts.Clear();
        IOrderedEnumerable<AccountDto> sorted = _lastAccounts.OrderBy(account => account.Archived);
        sorted = _accountSortMode switch
        {
            1 => sorted
                .ThenByDescending(QuotaScore)
                .ThenBy(account => PlanSortRank(account.PlanLabel))
                .ThenBy(account => DisplayName(account), StringComparer.OrdinalIgnoreCase),
            2 => sorted.ThenBy(account => DisplayName(account), StringComparer.OrdinalIgnoreCase),
            3 => sorted.ThenBy(account => account.Email, StringComparer.OrdinalIgnoreCase),
            _ => sorted
                .ThenBy(account => PlanSortRank(account.PlanLabel))
                .ThenByDescending(QuotaScore)
                .ThenBy(account => DisplayName(account), StringComparer.OrdinalIgnoreCase),
        };
        foreach (var account in sorted)
        {
            Accounts.Add(new AccountItem(account));
        }
        OnPropertyChanged(nameof(SavedAccountCount));
        OnPropertyChanged(nameof(ReadyAccountCount));
        OnPropertyChanged(nameof(EmptyAccountsVisibility));
        OnPropertyChanged(nameof(AccountsListVisibility));
        UpdateCurrentAccountDetail();
        ApplyQuotaTimerInterval();
    }

    private void UpdateCurrentAccountDetail()
    {
        var active = Accounts.FirstOrDefault(account => account.IsActive && !account.IsArchived);
        if (active is null)
        {
            CurrentAccountDetail = "chưa có phiên Codex đang gắn với Roster";
            return;
        }

        if (active.NeedsRelogin)
        {
            CurrentAccountDetail = "cần đăng nhập lại để xác minh quota";
            return;
        }

        if (!active.HasQuota)
        {
            CurrentAccountDetail = "chưa có quota đã xác minh — bấm Quota để kiểm tra";
            return;
        }

        CurrentAccountDetail = string.IsNullOrWhiteSpace(active.SecondaryQuotaLabel)
            ? $"còn {active.QuotaPercent}% · {active.ResetLabel}"
            : $"còn {active.QuotaPercent}% · {active.SecondaryQuotaLabel} · {active.ResetLabel}";
    }

    private static int PlanSortRank(string? planLabel)
    {
        var plan = (planLabel ?? string.Empty).ToLowerInvariant();
        if (plan.Contains("pro")) return 0;
        if (plan.Contains("plus")) return 1;
        if (plan.Contains("team") || plan.Contains("business") || plan.Contains("enterprise")) return 2;
        if (plan.Contains("free") || plan.Contains("go")) return 3;
        if (string.IsNullOrWhiteSpace(plan)) return 5;
        return 4;
    }

    private static int QuotaScore(AccountDto account) =>
        account.Usage?.Weekly?.RemainingPercent
        ?? account.Usage?.FiveHour?.RemainingPercent
        ?? -1;

    private static string DisplayName(AccountDto account) => account.CustomLabel ?? account.Name ?? account.Email;

    private void UpdateQuotaTimer()
    {
        if (_quotaTimer is null) return;
        if (AutoQuotaRefresh || AutoSwitchWhenExhausted)
        {
            ApplyQuotaTimerInterval();
            _quotaTimer.Start();
            QuotaRefreshStatus = DescribeQuotaTimerStatus();
            if (AutoSwitchWhenExhausted && AutoSwitchStatus is "Tắt" or "")
            {
                AutoSwitchStatus = "Đã bật — Roster sẽ chuyển khi tài khoản hiện tại hết quota.";
            }
        }
        else
        {
            _quotaTimer.Stop();
            QuotaRefreshStatus = "Tắt";
        }
    }

    private void ApplyQuotaTimerInterval()
    {
        if (_quotaTimer is null || (!AutoQuotaRefresh && !AutoSwitchWhenExhausted)) return;
        var active = _lastAccounts.FirstOrDefault(account => account.IsActive && !account.Archived);
        var remaining = active?.Usage?.Weekly?.RemainingPercent
            ?? active?.Usage?.FiveHour?.RemainingPercent;
        _quotaTimer.Interval = remaining switch
        {
            null => TimeSpan.FromMinutes(1),
            <= 5 => TimeSpan.FromSeconds(10),
            <= 20 => TimeSpan.FromSeconds(30),
            _ => TimeSpan.FromMinutes(1),
        };
    }

    private string DescribeQuotaTimerStatus()
    {
        if (!AutoQuotaRefresh && AutoSwitchWhenExhausted) return "Theo dõi hết quota theo chu kỳ thích ứng";
        if (!AutoQuotaRefresh) return "Tắt";
        var active = _lastAccounts.FirstOrDefault(account => account.IsActive && !account.Archived);
        var remaining = active?.Usage?.Weekly?.RemainingPercent
            ?? active?.Usage?.FiveHour?.RemainingPercent;
        return remaining switch
        {
            null => "Tự động kiểm tra mỗi phút",
            <= 5 => "Quota thấp — kiểm tra mỗi 10 giây",
            <= 20 => "Quota đang giảm — kiểm tra mỗi 30 giây",
            _ => "Tự động kiểm tra mỗi phút",
        };
    }

    private void NotifyPendingLoginChanged()
    {
        OnPropertyChanged(nameof(IsPendingLogin));
        OnPropertyChanged(nameof(PendingLoginVisibility));
        OnPropertyChanged(nameof(CanSaveDetectedLogin));
    }

    public void Dispose()
    {
        _loginWatchCancellation?.Cancel();
        CodexLoginLauncher.Stop();
        _cli.Dispose();
        _quotaTimer?.Stop();
        _updateTimer?.Stop();
        _resetTimer?.Stop();
        _resetNotifier.Dispose();
    }

    private async Task RunAsync(Func<Task> operation)
    {
        if (IsBusy) return;
        IsBusy = true;
        ErrorMessage = string.Empty;
        ErrorTitle = "Không thể hoàn tất";
        try
        {
            await operation();
        }
        catch (Exception exception)
        {
            ErrorTitle = "Không thể hoàn tất";
            ErrorMessage = string.IsNullOrWhiteSpace(exception.Message)
                ? "Thao tác không hoàn tất. Hãy kiểm tra phiên Codex rồi thử lại."
                : exception.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task CreateAutomaticBackupAsync()
    {
        try
        {
            await _cli.RunCommandAsync("create-automatic-full-backup");
        }
        catch
        {
            // Backups are a safety net and must never prevent the dashboard from opening.
        }
    }

    private void WatchForNewLoginAsync(IdentityDto? previousIdentity)
    {
        _loginWatchCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _loginWatchCancellation = cancellation;
        _ = Task.Run(async () =>
        {
            while (!cancellation.IsCancellationRequested)
            {
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(1), cancellation.Token);
                    var addStatus = await _cli.ReadAsync<AddAccountStatusResponse>("add-account-status");
                    if (!addStatus.Active || !addStatus.AuthChanged) continue;
                    var status = await _cli.ReadAsync<StatusResponse>("status");
                    if (status.CurrentAccount is null) continue;
                    if (_expectedLoginEmail is not null
                        && !string.Equals(status.CurrentAccount.Email, _expectedLoginEmail, StringComparison.OrdinalIgnoreCase))
                    {
                        _dispatcher?.TryEnqueue(() => LoginStatus = $"Đã nhận diện {status.CurrentAccount.Email}; hãy đăng nhập lại đúng tài khoản {_expectedLoginEmail}.");
                        continue;
                    }
                    var detectedIdentity = status.CurrentAccount;
                    _dispatcher?.TryEnqueue(() =>
                    {
                        if (cancellation.IsCancellationRequested) return;
                        _pendingLoginIdentity = detectedIdentity;
                        LoginStatus = $"Đã nhận diện {detectedIdentity.Email}. Roster đang tự động lưu phiên.";
                        NotifyPendingLoginChanged();
                        _ = SaveCurrentAccountAsync();
                    });
                    return;
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch
                {
                    // Device login can transiently replace auth files. Keep polling until cancelled.
                }
            }
        }, cancellation.Token);
    }

    private static bool SameIdentity(IdentityDto? left, IdentityDto? right)
    {
        if (left is null || right is null) return false;
        if (!string.IsNullOrWhiteSpace(left.Subject) && !string.IsNullOrWhiteSpace(right.Subject))
        {
            return string.Equals(left.Subject, right.Subject, StringComparison.Ordinal);
        }
        return string.Equals(left.Email, right.Email, StringComparison.OrdinalIgnoreCase);
    }

    private static string FormatTokens(ulong value)
    {
        if (value >= 1_000_000_000) return $"{value / 1_000_000_000d:0.#}B";
        if (value >= 1_000_000) return $"{value / 1_000_000d:0.#}M";
        if (value >= 1_000) return $"{value / 1_000d:0.#}K";
        return value.ToString("N0");
    }

    private static string CurrentVersion => typeof(RosterViewModel).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    private void Set<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        OnPropertyChanged(propertyName);
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

public sealed class AutoQuotaSettings
{
    public bool Enabled { get; init; }
}
