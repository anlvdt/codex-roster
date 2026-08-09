using System.Diagnostics;

namespace CodexRoster.Windows.Services;

public static class CodexLoginLauncher
{
    private static Process? _deviceLoginProcess;

    public static void Start()
    {
        Stop();
        // `codex login` opens its own browser sign-in (loopback/PKCE) — no device
        // code. Do not pre-open a page here; the CLI drives the correct auth URL.
        var codexPath = ResolveCodexExecutable();
        // Quote the resolved path for cmd.exe. Prefer ArgumentList-style safety by
        // escaping embedded quotes rather than interpolating untrusted tokens.
        var quoted = QuoteForCmd(codexPath);
        var startInfo = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetTempPath(),
        };
        startInfo.ArgumentList.Add("/d");
        startInfo.ArgumentList.Add("/s");
        startInfo.ArgumentList.Add("/c");
        startInfo.ArgumentList.Add($"{quoted} login");
        _deviceLoginProcess = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Không thể mở đăng nhập Codex.");
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
