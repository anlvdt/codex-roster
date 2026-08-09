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
    [JsonPropertyName("process_warnings")]
    public List<RunningProcessDto> ProcessWarnings { get; init; } = [];
}

public sealed class LegacyRecoveryResponse
{
    [JsonPropertyName("recovered_accounts")]
    public int RecoveredAccounts { get; init; }
    [JsonPropertyName("imported_accounts")]
    public int ImportedAccounts { get; init; }
}

public sealed class AddAccountStatusResponse
{
    public bool Active { get; init; }
    [JsonPropertyName("auth_changed")]
    public bool AuthChanged { get; init; }
}

public sealed class SaveAccountResponse
{
    public AccountDto Account { get; init; } = new();
}

public sealed class RunningProcessDto
{
    public uint Pid { get; init; }
    public string Executable { get; init; } = string.Empty;
    public string Role { get; init; } = string.Empty;
}

public sealed class IdentityDto
{
    public string Email { get; init; } = string.Empty;
    public string? Name { get; init; }
    [JsonPropertyName("subject")]
    public string? Subject { get; init; }
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
    [JsonPropertyName("created_at")]
    public DateTimeOffset? CreatedAt { get; init; }
    [JsonPropertyName("updated_at")]
    public DateTimeOffset? UpdatedAt { get; init; }
    [JsonPropertyName("last_activated_at")]
    public DateTimeOffset? LastActivatedAt { get; init; }
    public AccountUsageDto? Usage { get; init; }
    [JsonPropertyName("usage_error")]
    public string? UsageError { get; init; }
}

public sealed class AccountUsageDto
{
    [JsonPropertyName("fetched_at")]
    public DateTimeOffset? FetchedAt { get; init; }
    [JsonPropertyName("five_hour")]
    public UsageWindowDto? FiveHour { get; init; }
    public UsageWindowDto? Weekly { get; init; }
}

public sealed class UsageWindowDto
{
    [JsonPropertyName("remaining_percent")]
    public int RemainingPercent { get; init; }
    [JsonPropertyName("reset_at")]
    [JsonConverter(typeof(RustDateTimeOffsetConverter))]
    public DateTimeOffset ResetAt { get; init; }
}

public sealed class ImportJsonResponse
{
    public string Format { get; init; } = string.Empty;
    public int Created { get; init; }
    public int Updated { get; init; }
    public List<AccountDto> Accounts { get; init; } = [];
}

public sealed class AutoSwitchOutput
{
    public bool Enabled { get; init; }
    public string Status { get; init; } = string.Empty;
    [JsonPropertyName("active_account_id")]
    public Guid? ActiveAccountId { get; init; }
    [JsonPropertyName("candidate_account_id")]
    public Guid? CandidateAccountId { get; init; }
    [JsonPropertyName("candidate_display_name")]
    public string? CandidateDisplayName { get; init; }
    public string? Detail { get; init; }
}

public sealed class ActivateOutput
{
    public AccountDto Account { get; init; } = new();
    [JsonPropertyName("previous_account_id")]
    public Guid? PreviousAccountId { get; init; }
}

public sealed class TokenUsageSummaryDto
{
    public ulong Today { get; init; }
    [JsonPropertyName("last_7_days")]
    public ulong Last7Days { get; init; }
    [JsonPropertyName("last_30_days")]
    public ulong Last30Days { get; init; }
    [JsonPropertyName("last_365_days")]
    public ulong Last365Days { get; init; }
}

public sealed class ResetOutlookDto
{
    [JsonPropertyName("chance_24_hours")]
    public int Chance24Hours { get; init; }
    [JsonPropertyName("chance_48_hours")]
    public int Chance48Hours { get; init; }
    [JsonPropertyName("window_label")]
    public string WindowLabel { get; init; } = string.Empty;
    public string Confidence { get; init; } = string.Empty;
}

public sealed class GlobalResetEventDto
{
    public string Id { get; init; } = string.Empty;
    [JsonPropertyName("announced_at")]
    public DateTimeOffset AnnouncedAt { get; init; }
    public string Summary { get; init; } = string.Empty;
    public string Url { get; init; } = string.Empty;
}

public sealed class OpenAiStatusDto
{
    public string Indicator { get; init; } = string.Empty;
    public string Description { get; init; } = string.Empty;
    [JsonPropertyName("codex_components")]
    public List<OpenAiComponentDto> CodexComponents { get; init; } = [];
}

public sealed class OpenAiComponentDto
{
    public string Name { get; init; } = string.Empty;
    public string Status { get; init; } = string.Empty;
}
