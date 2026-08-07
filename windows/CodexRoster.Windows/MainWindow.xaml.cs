using CodexRoster.Windows.Models;
using CodexRoster.Windows.Services;
using CodexRoster.Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace CodexRoster.Windows;

public sealed partial class MainWindow : Window
{
    public RosterViewModel ViewModel { get; } = new();

    public MainWindow()
    {
        InitializeComponent();
        Activated += MainWindow_Activated;
        Closed += MainWindow_Closed;
    }

    private async void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        Activated -= MainWindow_Activated;
        await ViewModel.InitializeAsync();
    }

    private void MainWindow_Closed(object sender, WindowEventArgs args)
    {
        ViewModel.Dispose();
        Application.Current.Exit();
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await ViewModel.RefreshAsync();

    private async void RefreshQuota_Click(object sender, RoutedEventArgs e) => await ViewModel.RefreshAllQuotaAsync();

    private void LoadDemoData_Click(object sender, RoutedEventArgs e) => ViewModel.LoadDemoData();

    private void AccountMenu_Click(object sender, RoutedEventArgs e)
    {
        var flyout = new MenuFlyout();
        var refresh = new MenuFlyoutItem { Text = "Làm mới dữ liệu" };
        refresh.Click += async (_, _) => await ViewModel.RefreshAsync();
        var insights = new MenuFlyoutItem { Text = "Cập nhật hoạt động & dịch vụ" };
        insights.Click += async (_, _) => await ViewModel.RefreshInsightsAsync();
        var update = new MenuFlyoutItem { Text = ViewModel.UpdateActionLabel };
        update.Click += async (_, _) => await ViewModel.InstallAvailableUpdateAsync();
        var tray = new MenuFlyoutItem { Text = "Gửi xuống khay thông báo" };
        tray.Click += SendToTray_Click;
        flyout.Items.Add(refresh);
        flyout.Items.Add(insights);
        flyout.Items.Add(update);
        flyout.Items.Add(new MenuFlyoutSeparator());
        flyout.Items.Add(tray);
        flyout.ShowAt(sender as FrameworkElement);
    }

    private void ErrorInfoBar_CloseClick(InfoBar sender, object args) => ViewModel.ClearError();

    private async void AddAccount_Click(object sender, RoutedEventArgs e) => await ViewModel.StartDeviceLoginAsync();

    private async void ImportJson_Click(object sender, RoutedEventArgs e) => await ImportJsonAccountAsync();

    private async void SaveCurrent_Click(object sender, RoutedEventArgs e) => await ViewModel.SaveCurrentAccountAsync();

    private async Task ImportJsonAccountAsync()
    {
        var path = new TextBox
        {
            Header = "Đường dẫn file JSON",
            PlaceholderText = "C:\\Users\\you\\.codex\\auth.json",
        };
        var label = new TextBox
        {
            Header = "Tên hiển thị (tuỳ chọn, chỉ khi nhập 1 tài khoản)",
            PlaceholderText = "Ví dụ: Plus công ty",
        };
        var hint = new TextBlock
        {
            Text = "Hỗ trợ: auth.json của Codex, snapshot Roster, hoặc backup Roster dạng JSON (không mã hóa).",
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.72,
        };
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(hint);
        content.Children.Add(path);
        content.Children.Add(label);
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Thêm tài khoản từ JSON",
            Content = content,
            PrimaryButtonText = "Nhập",
            CloseButtonText = "Hủy",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (string.IsNullOrWhiteSpace(path.Text)) return;
        await ViewModel.ImportAccountsFromJsonAsync(path.Text.Trim(), label.Text);
    }

    private async void CancelPendingLogin_Click(object sender, RoutedEventArgs e) => await ViewModel.CancelPendingLoginAsync();

    private async void ReloginAccount_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not AccountItem account) return;
        await ViewModel.StartReloginAsync(account);
    }

    private async void ActivateAccount_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not AccountItem account) return;

        var desktopRunning = ViewModel.IsCodexDesktopRunning();
        IReadOnlyList<RunningProcessDto> warnings = [];
        try { warnings = await ViewModel.GetProcessWarningsAsync(); }
        catch { /* status probe is advisory before the confirm dialog */ }

        if (!desktopRunning && warnings.Count > 0)
        {
            var block = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = "Codex đang chạy",
                Content = "Hãy đóng các tác vụ Codex CLI đang chạy trước khi chuyển tài khoản để bảo vệ công việc.",
                CloseButtonText = "Đóng",
            };
            await block.ShowAsync();
            return;
        }

        if (desktopRunning)
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = "Chuyển tài khoản Codex?",
                Content = "Codex Desktop sẽ được đóng, chuyển session, rồi mở lại. Các tác vụ Codex CLI đang chạy phải được đóng trước.",
                PrimaryButtonText = "Chuyển và mở lại",
                CloseButtonText = "Hủy",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            await ViewModel.ActivateAsync(account, restartDesktop: true);
            return;
        }
        await ViewModel.ActivateAsync(account, restartDesktop: false);
    }

    private async void AccountActions_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is AccountItem account)
        {
            var flyout = new MenuFlyout();
            var rename = new MenuFlyoutItem { Text = "Đổi tên hiển thị" };
            rename.Click += async (_, _) => await RenameAccountAsync(account);
            var relogin = new MenuFlyoutItem { Text = "Đăng nhập lại tài khoản này" };
            relogin.Click += async (_, _) => await ViewModel.StartReloginAsync(account);
            var archive = new MenuFlyoutItem { Text = account.IsArchived ? "Khôi phục tài khoản" : "Lưu trữ tài khoản" };
            archive.Click += async (_, _) => await ViewModel.ToggleArchiveAsync(account);
            var delete = new MenuFlyoutItem { Text = "Xóa khỏi Roster" };
            delete.Click += async (_, _) => await DeleteAccountAsync(account);
            flyout.Items.Add(rename);
            flyout.Items.Add(relogin);
            flyout.Items.Add(archive);
            flyout.Items.Add(new MenuFlyoutSeparator());
            flyout.Items.Add(delete);
            flyout.ShowAt(sender as FrameworkElement);
        }
    }

    private async Task RenameAccountAsync(AccountItem account)
    {
        var label = new TextBox { Text = account.DisplayName, PlaceholderText = account.Email };
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Đổi tên hiển thị",
            Content = label,
            PrimaryButtonText = "Lưu",
            CloseButtonText = "Hủy",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await ViewModel.SetCustomLabelAsync(account, label.Text);
        }
    }

    private async Task DeleteAccountAsync(AccountItem account)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Xóa tài khoản đã lưu?",
            Content = $"{account.Email} sẽ bị xóa khỏi Codex Roster. Phiên Codex đang dùng không bị xóa.",
            PrimaryButtonText = "Xóa",
            CloseButtonText = "Hủy",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await ViewModel.DeleteAsync(account);
        }
    }

    private async void AutoQuotaRefresh_Toggled(object sender, RoutedEventArgs e)
    {
        await ViewModel.SetAutoQuotaRefreshAsync();
    }

    private async void AutoSwitchWhenExhausted_Toggled(object sender, RoutedEventArgs e)
    {
        await ViewModel.SetAutoSwitchWhenExhaustedAsync();
    }

    private async void RunAutoSwitchCheck_Click(object sender, RoutedEventArgs e)
    {
        await ViewModel.RunAutoSwitchCheckAsync();
    }

    private async void LaunchAtLogin_Toggled(object sender, RoutedEventArgs e)
    {
        await ViewModel.SetLaunchAtLoginAsync();
    }

    private async void RestoreAccountList_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Khôi phục danh sách tài khoản?",
            Content = "Danh sách tài khoản đã lưu sẽ được thay bằng bản sao lưu metadata gần nhất. Phiên Codex đang dùng không bị ghi đè.",
            PrimaryButtonText = "Khôi phục danh sách",
            CloseButtonText = "Hủy",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        await ViewModel.RestoreLatestAccountListBackupAsync();
    }

    private async void RestoreFullBackup_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Khôi phục phiên đầy đủ?",
            Content = "Bản sao lưu tự động đầy đủ gần nhất sẽ ghi đè danh sách và có thể thay phiên Codex hiện tại trên máy này.",
            PrimaryButtonText = "Khôi phục phiên đầy đủ",
            CloseButtonText = "Hủy",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        await ViewModel.RestoreLatestFullBackupAsync();
    }

    private void AccountSort_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is ComboBox { SelectedIndex: var selectedIndex }) ViewModel.SetAccountSortMode(selectedIndex);
    }

    private async void RefreshInsights_Click(object sender, RoutedEventArgs e) => await ViewModel.RefreshInsightsAsync();

    private async void Update_Click(object sender, RoutedEventArgs e) => await ViewModel.InstallAvailableUpdateAsync();

    private async void ExportBackup_Click(object sender, RoutedEventArgs e) => await TransferBackupAsync(importing: false);

    private async void ImportBackup_Click(object sender, RoutedEventArgs e) => await TransferBackupAsync(importing: true);

    private async void SendToTray_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = "Gửi xuống khay thông báo?",
                Content = "Codex Roster sẽ tiếp tục chạy nền để theo dõi quota. Chọn Quit trong menu khay thông báo trước khi xóa hoặc thay thư mục ứng dụng.",
                PrimaryButtonText = "Gửi xuống khay thông báo",
                CloseButtonText = "Hủy",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            CodexTrayLauncher.Start();
            Close();
        }
        catch
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = "Không thể mở khay thông báo",
                Content = "Không thể khởi động companion ở khay thông báo. Hãy thử lại sau.",
                CloseButtonText = "Đóng",
            };
            await dialog.ShowAsync();
        }
    }

    private async Task TransferBackupAsync(bool importing)
    {
        var path = new TextBox
        {
            Header = importing ? "Đường dẫn file .codexroster" : "Nơi lưu file .codexroster",
            PlaceholderText = importing ? "C:\\Backups\\roster.codexroster" : "C:\\Backups\\roster.codexroster",
        };
        var password = new PasswordBox { Header = "Mật khẩu mã hóa" };
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(path);
        content.Children.Add(password);
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = importing ? "Nhập bản sao lưu mã hóa" : "Xuất bản sao lưu mã hóa",
            Content = content,
            PrimaryButtonText = importing ? "Nhập" : "Xuất",
            CloseButtonText = "Hủy",
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (string.IsNullOrWhiteSpace(path.Text) || string.IsNullOrWhiteSpace(password.Password)) return;
        if (importing)
        {
            var confirm = new ContentDialog
            {
                XamlRoot = Content.XamlRoot,
                Title = "Nhập bản sao lưu?",
                Content = "Tài khoản trong file sao lưu sẽ được nhập vào Roster trên máy này. Phiên hiện tại chỉ đổi khi bạn kích hoạt một tài khoản sau đó.",
                PrimaryButtonText = "Nhập",
                CloseButtonText = "Hủy",
                DefaultButton = ContentDialogButton.Close,
            };
            if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
            await ViewModel.ImportBackupAsync(path.Text.Trim(), password.Password);
        }
        else
        {
            await ViewModel.ExportBackupAsync(path.Text.Trim(), password.Password);
        }
    }
}
