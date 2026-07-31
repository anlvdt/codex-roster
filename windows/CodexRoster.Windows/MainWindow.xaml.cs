using CodexRoster.Windows.Models;
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
    }

    private async void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        Activated -= MainWindow_Activated;
        await ViewModel.InitializeAsync();
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await ViewModel.RefreshAsync();

    private async void RefreshQuota_Click(object sender, RoutedEventArgs e) => await ViewModel.RefreshAllQuotaAsync();

    private async void AddAccount_Click(object sender, RoutedEventArgs e) => await ViewModel.StartDeviceLoginAsync();

    private async void SaveCurrent_Click(object sender, RoutedEventArgs e) => await ViewModel.SaveCurrentAccountAsync();

    private async void ActivateAccount_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is AccountItem account)
        {
            await ViewModel.ActivateAsync(account);
        }
    }

    private async void AccountActions_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is AccountItem account)
        {
            await ViewModel.ToggleArchiveAsync(account);
        }
    }

    private async void AutoQuotaRefresh_Toggled(object sender, RoutedEventArgs e)
    {
        await ViewModel.SetAutoQuotaRefreshAsync();
    }
}
