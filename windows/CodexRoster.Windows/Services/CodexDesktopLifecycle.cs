using System.Diagnostics;

namespace CodexRoster.Windows.Services;

public sealed class CodexDesktopRestartPlan
{
    private readonly IReadOnlyList<string> _executables;

    internal CodexDesktopRestartPlan(IReadOnlyList<string> executables)
    {
        _executables = executables;
    }

    public bool HasDesktop => _executables.Count > 0;

    public void Restart()
    {
        foreach (var executable in _executables)
        {
            try
            {
                Process.Start(new ProcessStartInfo(executable) { UseShellExecute = true });
            }
            catch
            {
                // The account swap already completed. A missing/unlaunchable desktop
                // executable must not undo the restored Codex session.
            }
        }
    }
}

public static class CodexDesktopLifecycle
{
    private static readonly string[] DesktopProcessNames = ["codex", "chatgpt"];

    public static async Task<CodexDesktopRestartPlan> CloseForAccountSwitchAsync()
    {
        var desktops = DesktopProcessNames
            .SelectMany(Process.GetProcessesByName)
            .Where(process => !process.HasExited && process.MainWindowHandle != IntPtr.Zero)
            .ToList();
        var executables = desktops
            .Select(ExecutablePath)
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Cast<string>()
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        foreach (var process in desktops)
        {
            try { process.CloseMainWindow(); }
            catch { }
        }
        await Task.Delay(TimeSpan.FromSeconds(2));
        foreach (var process in desktops.Where(process => !process.HasExited))
        {
            try { process.Kill(entireProcessTree: true); }
            catch { }
        }
        await Task.WhenAll(desktops.Select(WaitForExitAsync));
        return new CodexDesktopRestartPlan(executables);
    }

    public static bool IsRunning() => DesktopProcessNames
        .SelectMany(Process.GetProcessesByName)
        .Any(process => !process.HasExited && process.MainWindowHandle != IntPtr.Zero);

    private static async Task WaitForExitAsync(Process process)
    {
        try
        {
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch
        {
            // `activate` will still perform its own process-safety preflight.
        }
        finally
        {
            process.Dispose();
        }
    }

    private static string? ExecutablePath(Process process)
    {
        try { return process.MainModule?.FileName; }
        catch { return null; }
    }
}
