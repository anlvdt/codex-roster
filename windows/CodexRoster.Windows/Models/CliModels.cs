using System.Text.Json.Serialization;

namespace CodexRoster.Windows.Models;

public sealed class AccountListResponse
{
    public List<AccountDto> Accounts { get; init; } = [];
}

public sealed class StatusResponse
{
    [JsonPropertyName("current_account")]
    public IdentityDto? CurrentAccount { get; init; }
}

public sealed class IdentityDto
{
    public string Email { get; init; } = string.Empty;
    public string? Name { get; init; }
}

public sealed class AccountDto
{
    public Guid Id { get; init; }
    public string Email { get; init; } = string.Empty;
    public string? Name { get; init; }
    [JsonPropertyName("custom_label")]
    public string? CustomLabel { get; init; }
    [JsonPropertyName("plan_label")]
    public string? PlanLabel { get; init; }
    [JsonPropertyName("is_active")]
    public bool IsActive { get; init; }
    public bool Archived { get; init; }
    public AccountUsageDto? Usage { get; init; }
    [JsonPropertyName("usage_error")]
    public string? UsageError { get; init; }
}

public sealed class AccountUsageDto
{
    [JsonPropertyName("five_hour")]
    public UsageWindowDto? FiveHour { get; init; }
    public UsageWindowDto? Weekly { get; init; }
}

public sealed class UsageWindowDto
{
    [JsonPropertyName("remaining_percent")]
    public int RemainingPercent { get; init; }
    [JsonPropertyName("reset_at")]
    public DateTimeOffset ResetAt { get; init; }
}

public sealed class AutoSwitchOutput
{
    public bool Enabled { get; init; }
    public string Status { get; init; } = string.Empty;
    [JsonPropertyName("candidate_display_name")]
    public string? CandidateDisplayName { get; init; }
    public string? Detail { get; init; }
}
