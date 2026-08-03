using System.Runtime.InteropServices;
using System.Text;

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
        var details = FormatException(exception);
        try
        {
            Directory.CreateDirectory(logDirectory);
            File.AppendAllText(logPath, $"[{DateTimeOffset.Now:O}] {stage}{Environment.NewLine}{details}{Environment.NewLine}{Environment.NewLine}");
        }
        catch
        {
            // Reporting must never hide the original startup failure.
        }
        _ = MessageBox(
            IntPtr.Zero,
            $"Codex Roster không thể mở giao diện. Chi tiết đã được lưu tại:{Environment.NewLine}{logPath}{Environment.NewLine}{Environment.NewLine}{RootMessage(exception)}",
            "Codex Roster",
            ErrorIcon);
    }

    private static string RootMessage(Exception exception)
    {
        var current = exception;
        while (current.InnerException is not null) current = current.InnerException;
        return current.Message;
    }

    private static string FormatException(Exception exception)
    {
        var builder = new StringBuilder();
        var current = exception;
        var depth = 0;
        while (current is not null)
        {
            if (depth > 0) builder.AppendLine("--- inner exception ---");
            builder.AppendLine($"{current.GetType().FullName}: {current.Message}");
            if (current.HResult != 0) builder.AppendLine($"HResult: 0x{current.HResult:X8}");
            if (!string.IsNullOrWhiteSpace(current.StackTrace)) builder.AppendLine(current.StackTrace);
            current = current.InnerException;
            depth++;
        }
        return builder.ToString().TrimEnd();
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr window, string text, string caption, uint type);
}
