using System.Diagnostics;

namespace CodexRoster.Windows.Services;

public static class CodexLoginLauncher
{
    private static Process? _deviceLoginProcess;

    public static void Start()
    {
        Stop();
        Process.Start(new ProcessStartInfo("https://auth.openai.com/codex/device") { UseShellExecute = true });
        var codexPath = ResolveCodexExecutable();
        // Quote the resolved path for cmd.exe. Prefer ArgumentList-style safety by
        // escaping embedded quotes rather than interpolating untrusted tokens.
        var quoted = QuoteForCmd(codexPath);
        _deviceLoginProcess = Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            // /c waits for login to complete, then terminates the child shell.
            Arguments = $"/c {quoted} login --device-auth",
            UseShellExecute = true,
            WorkingDirectory = Path.GetTempPath(),
        }) ?? throw new InvalidOperationException("Không thể mở đăng nhập Codex device.");
    }

    public static void Stop()
    {
        var process = Interlocked.Exchange(ref _deviceLoginProcess, null);
        if (process is null) return;
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        catch
        {
            // The login shell can finish while the window is being closed.
        }
        finally
        {
            process.Dispose();
        }
    }

    private static string ResolveCodexExecutable()
    {
        var candidates = new List<string?>
        {
            Environment.GetEnvironmentVariable("CODEX_ROSTER_CODEX_PATH"),
            Environment.GetEnvironmentVariable("CODEX_BINARY_PATH"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin", "codex.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin", "codex"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", "codex.cmd"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", "codex.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "npm", "codex.cmd"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "npm", "codex.exe"),
        };
        foreach (var candidate in candidates)
        {
            if (!string.IsNullOrWhiteSpace(candidate) && File.Exists(candidate)) return candidate;
        }

        var pathEntries = (Environment.GetEnvironmentVariable("PATH") ?? string.Empty)
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        foreach (var directory in pathEntries)
        {
            foreach (var name in new[] { "codex.cmd", "codex.exe", "codex" })
            {
                var candidate = Path.Combine(directory, name);
                if (File.Exists(candidate)) return candidate;
            }
        }

        // Last resort: let cmd resolve `codex` from PATH the same way a terminal would.
        return "codex";
    }

    private static string QuoteForCmd(string value)
    {
        if (value.Equals("codex", StringComparison.OrdinalIgnoreCase)) return "codex";
        var escaped = value.Replace("\"", "\\\"", StringComparison.Ordinal);
        return $"\"{escaped}\"";
    }
}
