using CodexRoster.Windows.Models;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace CodexRoster.Windows.Services;

public sealed class ResetNotifier : IDisposable
{
    private bool _registered;
    public bool IsAvailable => _registered;

    public void Register()
    {
        try
        {
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch
        {
            // Notifications are optional on Windows configurations that block
            // unpackaged app registration. The reset poll keeps running.
        }
    }

    public void Show(GlobalResetEventDto reset)
    {
        if (!_registered) return;
        try
        {
            var notification = new AppNotificationBuilder()
                .AddText("ChatGPT vừa có đợt mass reset")
                .AddText("Quota Codex và ChatGPT Work đang được đặt lại")
                .AddText(reset.Summary)
                .BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch
        {
            // Do not interrupt account switching if Windows notifications are disabled.
        }
    }

    public void Dispose()
    {
        if (!_registered) return;
        try { AppNotificationManager.Default.Unregister(); }
        catch { }
    }
}
