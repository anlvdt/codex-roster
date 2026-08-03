using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using CodexRoster.Windows.Models;
using CodexRoster.Windows.Services;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace CodexRoster.Windows.ViewModels;

public sealed class RosterViewModel : INotifyPropertyChanged
{
    private readonly CodexRosterCli _cli = new();
    private readonly GitHubUpdater _updater = new();
    private readonly DispatcherQueue? _dispatcher;
    private readonly DispatcherQueueTimer? _quotaTimer;
    private readonly DispatcherQueueTimer? _updateTimer;
    private List<AccountDto> _lastAccounts = [];
    private int _accountSortMode;
    private bool _isBusy;
    private bool _autoQuotaRefresh;
    private bool _autoSwitchWhenExhausted;
    private bool _launchAtLogin;
    private bool _isCheckingAutoSwitch;
    private bool _isRefreshingInsights;
    private bool _isCheckingUpdate;
    private bool _settingsLoaded;
    private CancellationTokenSource? _loginWatchCancellation;
    private IdentityDto? _pendingLoginIdentity;
    private string? _expectedLoginEmail;
    private string _errorMessage = string.Empty;
    private string _currentAccountLabel = "Chưa đăng nhập";
    private string _quotaRefreshStatus = "Tắt";
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

    public int SavedAccountCount => Accounts.Count;
    public int ReadyAccountCount => Accounts.Count(account => !account.IsArchived && account.QuotaPercent > 0 && account.ResetLabel != "Hãy đăng nhập lại");
    public string CurrentAccountLabel { get => _currentAccountLabel; private set => Set(ref _currentAccountLabel, value); }
    public string ErrorMessage { get => _errorMessage; private set { Set(ref _errorMessage, value); OnPropertyChanged(nameof(HasError)); } }
    public bool HasError => !string.IsNullOrWhiteSpace(ErrorMessage);
    public bool IsBusy { get => _isBusy; private set { Set(ref _isBusy, value); OnPropertyChanged(nameof(BusyVisibility)); } }
    public Visibility BusyVisibility => IsBusy ? Visibility.Visible : Visibility.Collapsed;
    public bool AutoQuotaRefresh { get => _autoQuotaRefresh; set => Set(ref _autoQuotaRefresh, value); }
    public bool AutoSwitchWhenExhausted { get => _autoSwitchWhenExhausted; set => Set(ref _autoSwitchWhenExhausted, value); }
    public bool LaunchAtLogin { get => _launchAtLogin; set => Set(ref _launchAtLogin, value); }
    public string QuotaRefreshStatus { get => _quotaRefreshStatus; private set => Set(ref _quotaRefreshStatus, value); }
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
    }

    public async Task InitializeAsync()
    {
        await RefreshAsync();
        try
        {
            var settings = await _cli.ReadAsync<AutoQuotaSettings>("auto-start-usage-windows");
            var autoSwitch = await _cli.ReadAsync<AutoSwitchOutput>("auto-switch", "--status");
            AutoQuotaRefresh = settings.Enabled;
            AutoSwitchWhenExhausted = autoSwitch.Enabled;
            LaunchAtLogin = WindowsStartup.IsEnabled;
            UpdateQuotaTimer();
            _settingsLoaded = true;
            if (AutoQuotaRefresh) await RefreshActiveQuotaAsync(silent: true);
        }
        catch
        {
            // The roster remains usable if the legacy preference has not been created yet.
        }
        _ = CreateAutomaticBackupAsync();
        _ = RefreshInsightsAsync(silent: true);
        _ = CheckForUpdatesAsync(silent: true);
        _updateTimer?.Start();
    }

    public async Task RefreshAsync()
    {
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
            foreach (var account in Accounts.Where(account => !account.IsArchived))
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
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = $"Đã kiểm tra toàn bộ lúc {DateTime.Now:t}";
        });
    }

    public void SetAccountSortMode(int selectedIndex)
    {
        if (selectedIndex is < 0 or > 3 || _accountSortMode == selectedIndex) return;
        _accountSortMode = selectedIndex;
        ReplaceAccounts(_lastAccounts);
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
            var status = await _cli.ReadAsync<StatusResponse>("status");
            if (status.CurrentAccount is not null)
            {
                await _cli.RunCommandAsync("save");
            }
            CodexLoginLauncher.Start();
            _pendingLoginIdentity = null;
            _expectedLoginEmail = expectedEmail;
            OnPropertyChanged(nameof(CanSaveDetectedLogin));
            LoginStatus = expectedEmail is null
                ? "Hoàn tất đăng nhập trong cửa sổ Codex đang mở. Roster sẽ tự nhận diện phiên mới."
                : $"Đăng nhập lại đúng tài khoản {expectedEmail}. Roster sẽ xác minh trước khi lưu.";
            WatchForNewLoginAsync(status.CurrentAccount);
        });
    }

    public async Task SaveCurrentAccountAsync()
    {
        await RunAsync(async () =>
        {
            if (_pendingLoginIdentity is not null)
            {
                var current = await _cli.ReadAsync<StatusResponse>("status");
                if (current.CurrentAccount is null || !SameIdentity(current.CurrentAccount, _pendingLoginIdentity))
                {
                    throw new InvalidOperationException("Phiên Codex đã thay đổi. Hãy để Roster nhận diện lại tài khoản mới trước khi lưu.");
                }
            }
            if (_expectedLoginEmail is not null)
            {
                var current = await _cli.ReadAsync<StatusResponse>("status");
                if (current.CurrentAccount is null || !string.Equals(current.CurrentAccount.Email, _expectedLoginEmail, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException($"Phiên hiện tại không phải {_expectedLoginEmail}. Hãy đăng nhập đúng tài khoản rồi thử lại.");
                }
            }
            await _cli.RunCommandAsync("save");
            _pendingLoginIdentity = null;
            _expectedLoginEmail = null;
            _loginWatchCancellation?.Cancel();
            OnPropertyChanged(nameof(CanSaveDetectedLogin));
            LoginStatus = "Đã lưu phiên Codex hiện tại.";
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

    public async Task ExportBackupAsync(string path, string password)
    {
        await RunAsync(async () =>
        {
            await _cli.RunCommandWithInputAsync(password + Environment.NewLine, "export", path, "--password-stdin");
            QuotaRefreshStatus = "Đã xuất bản sao lưu mã hóa.";
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
            _updater.ScheduleInstall(stage);
            UpdateStatus = "Đang cài bản cập nhật và mở lại Codex Roster…";
            Microsoft.UI.Xaml.Application.Current.Exit();
        }
        catch
        {
            UpdateStatus = "Không thể cài cập nhật. Phiên bản hiện tại vẫn không thay đổi.";
            ErrorMessage = "Không thể tải hoặc cài bản cập nhật từ GitHub.";
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

    public async Task ActivateAsync(AccountItem account)
    {
        await RunAsync(async () =>
        {
            await _cli.RunCommandAsync("activate", account.Id.ToString());
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = "Đã chuyển phiên. Windows Preview chưa tự khởi động lại app Codex.";
        });
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
            UpdateQuotaTimer();
        });
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
        if (!AutoQuotaRefresh || IsBusy) return;
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

    private async Task RunQuotaTimerAsync()
    {
        if (IsBusy) return;
        if (AutoQuotaRefresh) await RefreshActiveQuotaAsync(silent: true);
        if (AutoSwitchWhenExhausted) await CheckAutoSwitchAsync(silent: true);
    }

    private async Task CheckAutoSwitchAsync(bool silent)
    {
        if (!AutoSwitchWhenExhausted || IsBusy || _isCheckingAutoSwitch) return;
        _isCheckingAutoSwitch = true;
        try
        {
            var decision = await _cli.ReadAsync<AutoSwitchOutput>("auto-switch");
            if (decision.Status == "active_has_quota") return;
            if (decision.Status == "all_accounts_exhausted")
            {
                QuotaRefreshStatus = "Tất cả tài khoản đã hết quota.";
                return;
            }
            if (decision.Status != "ready")
            {
                QuotaRefreshStatus = "Tự động chuyển đang chờ phiên Codex an toàn.";
                return;
            }
            var applyArgs = new List<string> { "auto-switch", "--apply" };
            if (decision.CandidateAccountId is Guid candidateId)
            {
                applyArgs.Add("--account-id");
                applyArgs.Add(candidateId.ToString());
            }
            var applied = await _cli.ReadAsync<AutoSwitchOutput>(applyArgs.ToArray());
            if (applied.Status == "switched")
            {
                await RefreshRosterDataAsync();
                QuotaRefreshStatus = $"Đã tự động chuyển sang {applied.CandidateDisplayName ?? "tài khoản khác"}. Windows Preview chưa tự mở lại Codex — hãy mở lại app để khớp phiên.";
            }
            else if (applied.Status == "waiting_for_processes")
            {
                QuotaRefreshStatus = "Codex đang chạy — đóng Codex rồi để Roster chuyển (Windows Preview chưa tự đóng/mở lại).";
            }
        }
        catch when (silent)
        {
            QuotaRefreshStatus = "Tự động chuyển sẽ thử lại sau.";
        }
        catch
        {
            ErrorMessage = "Không thể kiểm tra điều kiện tự động chuyển tài khoản.";
        }
        finally
        {
            _isCheckingAutoSwitch = false;
        }
    }

    private async Task RefreshRosterDataAsync()
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
        QuotaRefreshStatus = (AutoQuotaRefresh || AutoSwitchWhenExhausted) ? "Tự động kiểm tra mỗi phút" : "Tắt";
        if (_quotaTimer is null) return;
        if (AutoQuotaRefresh || AutoSwitchWhenExhausted) _quotaTimer.Start(); else _quotaTimer.Stop();
    }

    private async Task RunAsync(Func<Task> operation)
    {
        if (IsBusy) return;
        IsBusy = true;
        ErrorMessage = string.Empty;
        try
        {
            await operation();
        }
        catch (Exception)
        {
            ErrorMessage = "Thao tác không hoàn tất. Hãy kiểm tra phiên Codex rồi thử lại.";
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
                    var status = await _cli.ReadAsync<StatusResponse>("status");
                    if (status.CurrentAccount is null) continue;
                    if (_expectedLoginEmail is null && SameIdentity(status.CurrentAccount, previousIdentity)) continue;
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
                        LoginStatus = $"Đã nhận diện {detectedIdentity.Email}. Chọn Lưu phiên hiện tại để thêm vào Roster.";
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

    private static bool SameIdentity(IdentityDto? left, IdentityDto? right) =>
        left is not null
        && right is not null
        && string.Equals(left.Email, right.Email, StringComparison.OrdinalIgnoreCase);

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
