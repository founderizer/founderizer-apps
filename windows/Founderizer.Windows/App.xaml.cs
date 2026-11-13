using System;
using System.IO;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Navigation;
using Microsoft.UI.Xaml;

namespace Founderizer.Windows;

public partial class App : Application
{
    private static readonly string? DebugLog = Environment.GetEnvironmentVariable("FOUNDERIZER_DEBUG_LOG");
    private Window? window;

    public App()
    {
        InitializeComponent();
        // With FOUNDERIZER_DEBUG_LOG set to a file, an exception that nothing caught is written there; else nothing.
        if (DebugLog is not null) UnhandledException += (_, e) => Note(e.Exception.ToString());
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        // The library's store against the hub of FOUNDERIZER_HUB, for the proofs until Add this PC comes (slice 1.5);
        // else the sample fleet of the Mac and iPhone apps.
        IFleetSource source;
        var store = StoreSource.FromEnvironment();
        if (store is not null) source = store;
        else source = new SampleSource();
        window = new MainWindow(source, History.Asked(Environment.GetCommandLineArgs()));
        window.Activate();
        if (store is not null && await store.StartAsync() is { } refused) Note("the store did not start: " + refused);
    }

    private static void Note(string line)
    {
        if (DebugLog is null) return;
        try { File.AppendAllText(DebugLog, line + Environment.NewLine); } catch (IOException) { }
    }
}
