using System.Diagnostics;

namespace CodexRoster.Windows.Services;

public static class CodexLoginLauncher
{
    public static void Start()
    {
        Process.Start(new ProcessStartInfo("https://auth.openai.com/codex/device") { UseShellExecute = true });
        var codexPath = Environment.GetEnvironmentVariable("CODEX_ROSTER_CODEX_PATH")
            ?? Environment.GetEnvironmentVariable("CODEX_BINARY_PATH")
            ?? "codex.exe";
        Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = $"/k \"\"{codexPath}\" login --device-auth\"",
            UseShellExecute = true,
        });
    }
}
