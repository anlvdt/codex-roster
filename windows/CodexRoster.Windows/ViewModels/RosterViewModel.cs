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
    private readonly DispatcherQueueTimer? _quotaTimer;
    private bool _isBusy;
    private bool _autoQuotaRefresh;
    private bool _autoSwitchWhenExhausted;
    private bool _isCheckingAutoSwitch;
    private bool _settingsLoaded;
    private string _errorMessage = string.Empty;
    private string _currentAccountLabel = "Chưa đăng nhập";
    private string _quotaRefreshStatus = "Tắt";

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
    public string QuotaRefreshStatus { get => _quotaRefreshStatus; private set => Set(ref _quotaRefreshStatus, value); }

    public RosterViewModel()
    {
        _quotaTimer = DispatcherQueue.GetForCurrentThread()?.CreateTimer();
        if (_quotaTimer is not null)
        {
            _quotaTimer.Interval = TimeSpan.FromMinutes(1);
            _quotaTimer.Tick += async (_, _) => await RunQuotaTimerAsync();
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
            UpdateQuotaTimer();
            _settingsLoaded = true;
            if (AutoQuotaRefresh) await RefreshActiveQuotaAsync(silent: true);
        }
        catch
        {
            // The roster remains usable if the legacy preference has not been created yet.
        }
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
        });
    }

    public async Task RefreshAllQuotaAsync()
    {
        await RunAsync(async () =>
        {
            foreach (var account in Accounts.Where(account => !account.IsArchived))
            {
                await _cli.RunCommandAsync("usage", account.Id.ToString());
            }
            await RefreshRosterDataAsync();
            QuotaRefreshStatus = $"Đã kiểm tra toàn bộ lúc {DateTime.Now:t}";
        });
    }

    public async Task StartDeviceLoginAsync()
    {
        try
        {
            CodexLoginLauncher.Start();
            ErrorMessage = string.Empty;
            QuotaRefreshStatus = "Hoàn tất đăng nhập trong cửa sổ Codex, sau đó chọn Lưu phiên hiện tại.";
        }
        catch
        {
            ErrorMessage = "Không thể mở luồng đăng nhập OpenAI trên Windows.";
        }
        await Task.CompletedTask;
    }

    public async Task SaveCurrentAccountAsync()
    {
        await RunAsync(async () =>
        {
            await _cli.RunCommandAsync("save");
            await RefreshRosterDataAsync();
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

    private async Task RefreshActiveQuotaAsync(bool silent)
    {
        if (!AutoQuotaRefresh || IsBusy) return;
        var active = Accounts.FirstOrDefault(account => account.IsActive && !account.IsArchived);
        if (active is null) return;
        try
        {
            await _cli.RunCommandAsync("usage", active.Id.ToString());
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
            var applied = await _cli.ReadAsync<AutoSwitchOutput>("auto-switch", "--apply");
            if (applied.Status == "switched")
            {
                await RefreshRosterDataAsync();
                QuotaRefreshStatus = $"Đã tự động chuyển sang {applied.CandidateDisplayName ?? "tài khoản khác"}. Mở lại Codex để dùng phiên mới.";
            }
            else if (applied.Status == "waiting_for_processes")
            {
                QuotaRefreshStatus = "Đóng Codex trước khi tự động chuyển để bảo vệ công việc đang làm.";
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
        var list = await _cli.ReadAsync<AccountListResponse>("list");
        ReplaceAccounts(list.Accounts);
    }

    private void ReplaceAccounts(IEnumerable<AccountDto> accounts)
    {
        Accounts.Clear();
        foreach (var account in accounts.OrderBy(account => account.Archived).ThenByDescending(account => account.Usage?.Weekly?.RemainingPercent ?? -1))
        {
            Accounts.Add(new AccountItem(account));
        }
        OnPropertyChanged(nameof(SavedAccountCount));
        OnPropertyChanged(nameof(ReadyAccountCount));
    }

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
