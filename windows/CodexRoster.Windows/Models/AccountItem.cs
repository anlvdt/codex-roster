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
    public bool NeedsRelogin { get; } = !string.IsNullOrWhiteSpace(account.UsageError);
    public bool HasQuota { get; } = account.Usage?.Weekly is not null || account.Usage?.FiveHour is not null;
    public int QuotaPercent { get; } = account.Usage?.Weekly?.RemainingPercent
        ?? account.Usage?.FiveHour?.RemainingPercent
        ?? 0;
    public bool IsUsableForSwitch { get; } = IsUsable(account);
    public bool IsReady { get; } = !account.Archived
        && string.IsNullOrWhiteSpace(account.UsageError)
        && IsUsable(account);
    public string QuotaLabel { get; } = FormatQuota(account);
    public string ResetLabel { get; } = FormatReset(account.Usage?.Weekly ?? account.Usage?.FiveHour, account.UsageError);
    public string SecondaryQuotaLabel { get; } = FormatSecondaryQuota(account);
    public double RowOpacity { get; } = account.Archived ? 0.55 : 1;
    public bool CanActivate { get; } = !account.IsActive && !account.Archived && string.IsNullOrWhiteSpace(account.UsageError);
    public bool CanRelogin { get; } = !account.Archived && !string.IsNullOrWhiteSpace(account.UsageError);

    public Visibility QuotaMeterVisibility => HasQuota && !NeedsRelogin ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SecondaryQuotaVisibility => string.IsNullOrWhiteSpace(SecondaryQuotaLabel) ? Visibility.Collapsed : Visibility.Visible;
    public Visibility ActiveBadgeVisibility => IsActive ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ArchivedBadgeVisibility => IsArchived ? Visibility.Visible : Visibility.Collapsed;
    public Visibility SwitchVisibility => CanActivate ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ReloginVisibility => CanRelogin ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ActiveStateVisibility => IsActive && !IsArchived ? Visibility.Visible : Visibility.Collapsed;

    private static bool IsUsable(AccountDto account)
    {
        var windows = new[] { account.Usage?.Weekly, account.Usage?.FiveHour }
            .Where(window => window is not null)
            .Cast<UsageWindowDto>()
            .ToArray();
        return windows.Length > 0 && windows.All(window => window.RemainingPercent > 0);
    }

    private static string FormatQuota(AccountDto account)
    {
        if (!string.IsNullOrWhiteSpace(account.UsageError)) return "Cần đăng nhập";
        var quota = account.Usage?.Weekly ?? account.Usage?.FiveHour;
        return quota is null ? "Chưa có quota" : $"{quota.RemainingPercent}%";
    }

    private static string FormatSecondaryQuota(AccountDto account)
    {
        if (!string.IsNullOrWhiteSpace(account.UsageError)) return string.Empty;
        var weekly = account.Usage?.Weekly;
        var fiveHour = account.Usage?.FiveHour;
        if (weekly is null || fiveHour is null) return string.Empty;
        return $"5 giờ: {fiveHour.RemainingPercent}%";
    }

    private static string FormatReset(UsageWindowDto? quota, string? error)
    {
        if (!string.IsNullOrWhiteSpace(error)) return "Hãy đăng nhập lại";
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
}
