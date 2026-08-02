using System.Diagnostics;

namespace CodexRoster.Windows.Services;

public static class CodexTrayLauncher
{
    public static void Start()
    {
        var bundled = Path.Combine(AppContext.BaseDirectory, "codex-roster.exe");
        var executable = File.Exists(bundled) ? bundled : "codex-roster.exe";
        _ = Process.Start(new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            CreateNoWindow = true,
            ArgumentList = { "tray" },
        }) ?? throw new InvalidOperationException("Unable to start the Codex Roster notification-area companion.");
    }
}
