using System.Diagnostics;

namespace CodexRoster.Windows.Services;

public static class CodexLoginLauncher
{
    private static Process? _deviceLoginProcess;

    public static void Start()
    {
        Stop();
        Process.Start(new ProcessStartInfo("https://auth.openai.com/codex/device") { UseShellExecute = true });
        var codexPath = Environment.GetEnvironmentVariable("CODEX_ROSTER_CODEX_PATH")
            ?? Environment.GetEnvironmentVariable("CODEX_BINARY_PATH")
            ?? "codex.exe";
        _deviceLoginProcess = Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            // /k leaves cmd.exe open after device login and keeps the app folder
            // busy. /c waits for login to complete, then terminates the child.
            Arguments = $"/c \"\"{codexPath}\" login --device-auth\"",
            UseShellExecute = true,
            WorkingDirectory = Path.GetTempPath(),
        });
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
}
