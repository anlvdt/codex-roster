namespace CodexRoster.Windows.Models;

public sealed class AccountItem(AccountDto account)
{
    public Guid Id { get; } = account.Id;
    public string Email { get; } = account.Email;
    public bool IsActive { get; } = account.IsActive;
    public bool IsArchived { get; } = account.Archived;
    public string DisplayName { get; } = account.CustomLabel ?? account.Name ?? account.Email;
    public string PlanLabel { get; } = account.PlanLabel ?? "ChatGPT";
    public int QuotaPercent { get; } = account.Usage?.Weekly?.RemainingPercent ?? account.Usage?.FiveHour?.RemainingPercent ?? 0;
    public string QuotaLabel { get; } = FormatQuota(account);
    public string ResetLabel { get; } = FormatReset(account.Usage?.Weekly ?? account.Usage?.FiveHour, account.UsageError);
    public bool CanActivate => !IsActive && !IsArchived && string.IsNullOrWhiteSpace(account.UsageError);

    private static string FormatQuota(AccountDto account)
    {
        if (!string.IsNullOrWhiteSpace(account.UsageError)) return "Cần đăng nhập";
        var quota = account.Usage?.Weekly ?? account.Usage?.FiveHour;
        return quota is null ? "Chưa có quota" : $"{quota.RemainingPercent}%";
    }

    private static string FormatReset(UsageWindowDto? quota, string? error)
    {
        if (!string.IsNullOrWhiteSpace(error)) return "Hãy đăng nhập lại";
        if (quota is null) return "Chưa kiểm tra";
        var span = quota.ResetAt - DateTimeOffset.Now;
        if (span <= TimeSpan.Zero) return "Đang chờ reset";
        if (span.TotalDays >= 1) return $"Reset sau {(int)Math.Ceiling(span.TotalDays)} ngày";
        if (span.TotalHours >= 1) return $"Reset sau {(int)Math.Ceiling(span.TotalHours)} giờ";
        return "Reset trong chưa đầy 1 giờ";
    }
}
