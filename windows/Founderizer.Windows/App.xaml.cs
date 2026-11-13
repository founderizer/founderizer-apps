using System;
using System.IO;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Navigation;
using Microsoft.UI.Xaml;

namespace Founderizer.Windows;

public partial class App : Application
{
    private static readonly string? DebugLog = Proofs.Variable("FOUNDERIZER_DEBUG_LOG");
    private Window? window;

    public App()
    {
        InitializeComponent();
        // With FOUNDERIZER_DEBUG_LOG set to a file, an exception that nothing caught is written there; else nothing.
        if (DebugLog is not null) UnhandledException += (_, e) => Note(e.Exception.ToString());
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        // The library's store, kept in the user's LocalAppData: with no hub it opens on Add this PC. A build with the
        // proofs' switch can show the sample fleet of the Mac and iPhone apps (FOUNDERIZER_SAMPLE=1) or take a hub
        // from the environment (app/windows/vm/README.md); a release build has neither.
        IFleetSource source;
        var store = StoreSource.FromProofs();
        if (Proofs.Variable("FOUNDERIZER_SAMPLE") == "1") source = new SampleSource();
        else if (store is not null) source = store;
        else source = store = StoreSource.Create();
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
