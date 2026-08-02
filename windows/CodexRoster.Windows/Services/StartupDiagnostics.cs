using System.Runtime.InteropServices;

namespace CodexRoster.Windows.Services;

public static class StartupDiagnostics
{
    private const uint ErrorIcon = 0x10;

    public static void Report(string stage, Exception exception)
    {
        var logDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CodexRoster",
            "logs");
        var logPath = Path.Combine(logDirectory, "startup.log");
        try
        {
            Directory.CreateDirectory(logDirectory);
            File.AppendAllText(logPath, $"[{DateTimeOffset.Now:O}] {stage}{Environment.NewLine}{exception}{Environment.NewLine}{Environment.NewLine}");
        }
        catch
        {
            // Reporting must never hide the original startup failure.
        }
        _ = MessageBox(
            IntPtr.Zero,
            $"Codex Roster không thể mở giao diện. Chi tiết đã được lưu tại:{Environment.NewLine}{logPath}{Environment.NewLine}{Environment.NewLine}{exception.Message}",
            "Codex Roster",
            ErrorIcon);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr window, string text, string caption, uint type);
}
