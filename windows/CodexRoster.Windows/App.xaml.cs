using Microsoft.UI.Xaml;
using CodexRoster.Windows.Services;

namespace CodexRoster.Windows;

public partial class App : Application
{
    private static readonly Mutex SingleInstanceMutex = new(false, @"Local\CodexRoster.Windows.SingleInstance");
    private Window? _window;
    private bool _ownsSingleInstance;

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
            Environment.Exit(1);
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            try
            {
                _ownsSingleInstance = SingleInstanceMutex.WaitOne(0, false);
            }
            catch (AbandonedMutexException)
            {
                _ownsSingleInstance = true;
            }
            if (!_ownsSingleInstance)
            {
                Environment.Exit(0);
                return;
            }
            _window = new MainWindow();
            _window.Activate();
        }
        catch (Exception exception)
        {
            StartupDiagnostics.Report("Window launch", exception);
            Environment.Exit(1);
        }
    }

    private static void App_UnhandledException(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs args)
    {
        StartupDiagnostics.Report("Unhandled UI exception", args.Exception);
        args.Handled = true;
        Environment.Exit(1);
    }
}
