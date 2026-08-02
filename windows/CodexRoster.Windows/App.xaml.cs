using Microsoft.UI.Xaml;
using CodexRoster.Windows.Services;

namespace CodexRoster.Windows;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        try
        {
            InitializeComponent();
            UnhandledException += App_UnhandledException;
        }
        catch (Exception exception)
        {
            StartupDiagnostics.Report("Application initialization", exception);
            throw;
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            _window = new MainWindow();
            _window.Activate();
        }
        catch (Exception exception)
        {
            StartupDiagnostics.Report("Window launch", exception);
        }
    }

    private static void App_UnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs args)
    {
        StartupDiagnostics.Report("Unhandled UI exception", args.Exception);
        args.Handled = true;
    }
}
