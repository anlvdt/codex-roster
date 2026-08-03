using System.Diagnostics;
using System.Text.Json;

namespace CodexRoster.Windows.Services;

public sealed class CodexRosterCli : IDisposable
{
    private readonly CancellationTokenSource _shutdown = new();
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public async Task<T> ReadAsync<T>(params string[] arguments)
    {
        var output = await RunAsync(arguments.Append("--json"));
        return JsonSerializer.Deserialize<T>(output, JsonOptions)
            ?? throw new InvalidOperationException("Codex Roster returned incomplete data.");
    }

    public async Task RunCommandAsync(params string[] arguments)
    {
        _ = await RunAsync(arguments.Append("--json"));
    }

    public async Task RunCommandWithInputAsync(string standardInput, params string[] arguments)
    {
        _ = await RunAsync(arguments.Append("--json"), standardInput);
    }

    private async Task<string> RunAsync(IEnumerable<string> arguments, string? standardInput = null)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = ResolveExecutable(),
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = standardInput is not null,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetTempPath(),
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);

        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Unable to start the Codex Roster service.");
        if (standardInput is not null)
        {
            await process.StandardInput.WriteAsync(standardInput);
            process.StandardInput.Close();
        }
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        try
        {
            await process.WaitForExitAsync(_shutdown.Token);
        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested)
        {
            try { process.Kill(entireProcessTree: true); }
            catch { }
            throw;
        }
        var output = await outputTask;
        var error = await errorTask;
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(SafeError(error));
        }
        return output;
    }

    public void Dispose() => _shutdown.Cancel();

    private static string ResolveExecutable()
    {
        var overridePath = Environment.GetEnvironmentVariable("CODEX_ROSTER_CLI_PATH");
        if (!string.IsNullOrWhiteSpace(overridePath)) return overridePath;
        var bundled = Path.Combine(AppContext.BaseDirectory, "CodexRoster.CLI.exe");
        if (File.Exists(bundled)) return bundled;
        var legacyBundled = Path.Combine(AppContext.BaseDirectory, "codex-roster.exe");
        return File.Exists(legacyBundled) ? legacyBundled : "codex-roster.exe";
    }

    private static string SafeError(string error)
    {
        if (string.IsNullOrWhiteSpace(error)) return "Codex Roster could not complete this operation.";
        if (error.Contains("token", StringComparison.OrdinalIgnoreCase) || error.Contains("auth", StringComparison.OrdinalIgnoreCase))
        {
            return "Codex session needs attention. Sign in again, then save the account.";
        }
        return error.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()
            ?? "Codex Roster could not complete this operation.";
    }
}
