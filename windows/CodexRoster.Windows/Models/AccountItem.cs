using Microsoft.UI.Xaml;

namespace CodexRoster.Windows.Models;

public sealed class AccountItem(AccountDto account)
{
    public Guid Id { get; } = account.Id;
    public string Email { get; } = account.Email;
    public bool IsActive { get; } = account.IsActive;
    public bool IsArchived { get; } = account.Archived;
    public string DisplayName { get; } = account.CustomLabel ?? account.Name ?? account.Email;
    public string PlanLabel { get; } = account.PlanLabel ?? "ChatGPT";
    public bool NeedsRelogin { get; } = RequiresLogin(account.UsageError);
    public bool NeedsLocalRecovery { get; } = RequiresLocalRecovery(account.UsageError);
    public bool DeferredAccessTokenRefresh { get; } = IsDeferredAccessTokenRefresh(account.UsageError);
    public bool HasTransientUsageError { get; } = !string.IsNullOrWhiteSpace(account.UsageError)
        && !RequiresLogin(account.UsageError)
        && !RequiresLocalRecovery(account.UsageError)
        && !IsDeferredAccessTokenRefresh(account.UsageError);
    public bool HasQuota { get; } = account.Usage?.Weekly is not null || account.Usage?.FiveHour is not null;
    public int QuotaPercent { get; } = account.Usage?.FiveHour?.RemainingPercent
        ?? account.Usage?.Weekly?.RemainingPercent
        ?? 0;
    public bool IsUsableForSwitch { get; } = IsUsable(account);
    public bool IsReady { get; } = !account.Archived
        && (string.IsNullOrWhiteSpace(account.UsageError)
            || IsDeferredAccessTokenRefresh(account.UsageError))
        && IsUsable(account);
    public string QuotaLabel { get; } = FormatQuota(account);
    public string QuotaWindowLabel { get; } = account.Usage?.FiveHour is not null ? "5 giờ" : "tuần";
    public string ResetLabel { get; } = FormatReset(account.Usage?.FiveHour ?? account.Usage?.Weekly, account.UsageError);
    public string SecondaryQuotaLabel { get; } = FormatSecondaryQuota(account);
    public string SidebarStatus { get; } = FormatSidebarStatus(account);
    public string HealthLabel { get; } = FormatHealth(account);
    public string LastVerifiedLabel { get; } = FormatLastVerified(account);
    public double RowOpacity { get; } = account.Archived ? 0.55 : 1;
    public bool CanActivate { get; } = !account.IsActive && !account.Archived
        && !RequiresLogin(account.UsageError) && !RequiresLocalRecovery(account.UsageError);
    public bool CanRelogin { get; } = !account.Archived && RequiresLogin(account.UsageError);

    public Visibility QuotaMeterVisibility => HasQuota && !NeedsRelogin && !NeedsLocalRecovery ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SecondaryQuotaVisibility => string.IsNullOrWhiteSpace(SecondaryQuotaLabel) ? Visibility.Collapsed : Visibility.Visible;
    public Visibility ActiveBadgeVisibility => IsActive ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ArchivedBadgeVisibility => IsArchived ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SwitchVisibility => CanActivate ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ReloginVisibility => CanRelogin ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ActiveStateVisibility => IsActive && !IsArchived ? Visibility.Visible : Visibility.Collapsed;

    private static bool IsUsable(AccountDto account)
    {
        if (HasUsableCredits(account)) return true;
        var windows = new[] { account.Usage?.Weekly, account.Usage?.FiveHour }
            .Where(window => window is not null)
            .Cast<UsageWindowDto>()
            .ToArray();
        return windows.Length > 0 && windows.All(window => window.RemainingPercent > 0);
    }

    private static bool HasUsableCredits(AccountDto account)
    {
        var credits = account.Usage?.Credits;
        if (credits is null) return false;
        if (credits.Unlimited) return true;
        if (!credits.HasCredits) return false;
        var digits = new string(credits.Balance.Where(ch => char.IsDigit(ch) || ch == '.').ToArray());
        return double.TryParse(digits, System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var value) && value > 0;
    }

    private static string FormatQuota(AccountDto account)
    {
        if (RequiresLogin(account.UsageError)) return "Cần đăng nhập";
        if (RequiresLocalRecovery(account.UsageError)) return "Cần khôi phục";
        var quota = account.Usage?.FiveHour ?? account.Usage?.Weekly;
        return quota is null ? "Chưa có quota" : $"{quota.RemainingPercent}%";
    }

    private static string FormatSecondaryQuota(AccountDto account)
    {
        if (RequiresLogin(account.UsageError) || RequiresLocalRecovery(account.UsageError)) return string.Empty;
        var weekly = account.Usage?.Weekly;
        var fiveHour = account.Usage?.FiveHour;
        if (weekly is null || fiveHour is null) return string.Empty;
        return $"Tuần: {weekly.RemainingPercent}%";
    }

    private static string FormatReset(UsageWindowDto? quota, string? error)
    {
        if (IsServerRevoked(error)) return "OpenAI đã thu hồi phiên";
        if (RequiresLogin(error)) return "Hãy đăng nhập lại";
        if (RequiresLocalRecovery(error)) return "Khôi phục snapshot local";
        if (IsDeferredAccessTokenRefresh(error) && quota is null) return "Làm mới khi chuyển";
        if (quota is null) return "Chưa kiểm tra";
        var span = quota.ResetAt - DateTimeOffset.Now;
        if (span <= TimeSpan.Zero) return "Đang chờ reset";
        var resetAt = quota.ResetAt.ToLocalTime().ToString("HH:mm · dd/MM");
        var remaining = span.TotalDays >= 2
            ? $"{(int)Math.Ceiling(span.TotalDays)} ngày"
            : span.TotalDays >= 1
                ? "khoảng 1 ngày"
                : span.TotalHours >= 2
                    ? $"{(int)Math.Ceiling(span.TotalHours)} giờ"
                    : span.TotalHours >= 1
                        ? "khoảng 1 giờ"
                        : span.TotalMinutes >= 1
                            ? $"{(int)Math.Ceiling(span.TotalMinutes)} phút"
                            : "ít hơn 1 phút";
        return $"Reset {resetAt} · còn {remaining}";
    }

    private static string FormatSidebarStatus(AccountDto account)
    {
        if (RequiresLogin(account.UsageError)) return "Cần đăng nhập lại";
        if (RequiresLocalRecovery(account.UsageError)) return "Cần khôi phục local";
        if (IsDeferredAccessTokenRefresh(account.UsageError) && account.Usage is null) return "Chờ làm mới khi chuyển";
        if (!string.IsNullOrWhiteSpace(account.UsageError) && account.Usage is null) return "Quota tạm thời lỗi";
        var fiveHour = account.Usage?.FiveHour;
        var weekly = account.Usage?.Weekly;
        var quota = fiveHour ?? weekly;
        if (quota is null) return "Chưa kiểm tra quota";
        var label = fiveHour is not null ? "5 giờ" : "Tuần";
        var remaining = quota.ResetAt - DateTimeOffset.Now;
        if (remaining <= TimeSpan.Zero) return $"{label} {quota.RemainingPercent}% · đang reset";
        if (remaining.TotalDays >= 1) return $"{label} {quota.RemainingPercent}% · reset {quota.ResetAt.ToLocalTime():dd/MM}";
        if (remaining.TotalHours >= 1) return $"{label} {quota.RemainingPercent}% · reset {quota.ResetAt.ToLocalTime():HH:mm}";
        return $"{label} {quota.RemainingPercent}% · reset sớm";
    }

    private static string FormatHealth(AccountDto account)
    {
        if (account.Archived) return "Đã lưu trữ";
        if (IsServerRevoked(account.UsageError)) return "OpenAI đã thu hồi phiên";
        if (RequiresLogin(account.UsageError)) return "Cần đăng nhập";
        if (RequiresLocalRecovery(account.UsageError)) return "Cần khôi phục local";
        if (IsDeferredAccessTokenRefresh(account.UsageError)) return "Sẽ làm mới khi chuyển";
        if (!string.IsNullOrWhiteSpace(account.UsageError)) return "Tạm thời không khả dụng";
        return "Phiên khỏe";
    }

    private static string FormatLastVerified(AccountDto account)
    {
        return account.Usage?.FetchedAt is { } fetchedAt
            ? $"Xác minh {fetchedAt.ToLocalTime():HH:mm · dd/MM}"
            : "Chưa xác minh quota";
    }

    private static bool RequiresLogin(string? error) =>
        error?.Contains("login required", StringComparison.OrdinalIgnoreCase) == true;

    private static bool RequiresLocalRecovery(string? error) =>
        error?.Contains("local recovery required", StringComparison.OrdinalIgnoreCase) == true;

    private static bool IsDeferredAccessTokenRefresh(string? error) =>
        error?.Contains("[access_token_unauthorized]", StringComparison.OrdinalIgnoreCase) == true;

    private static bool IsServerRevoked(string? error) =>
        error?.Contains("[server_session_revoked]", StringComparison.OrdinalIgnoreCase) == true;
}
