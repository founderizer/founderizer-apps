using System;
using System.IO;
using System.Linq;
using Founderizer.Install;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Navigation;
using Founderizer.Windows.Update;
using Microsoft.UI.Xaml;

namespace Founderizer.Windows;

public partial class App : Application
{
    private static readonly string? DebugLog = Proofs.Variable("FOUNDERIZER_DEBUG_LOG");
    private Window? window;
    private Updater? updater;

    public App()
    {
        InitializeComponent();
        // With FOUNDERIZER_DEBUG_LOG set to a file, an exception that nothing caught is written there; else nothing.
        if (DebugLog is not null) UnhandledException += (_, e) => Note(e.Exception.ToString());
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        // A build of an install (%LOCALAPPDATA%\Programs\Founderizer\builds\<build>) takes updates, and the app's
        // identity of the Start menu entry, so that a pin of its window pins the launcher and not this build's folder.
        var install = Updater.ThisInstall();
        if (install is { } proved && ReleaseChannel.EndsBeforeGoodStart == proved.Build.Build)
        {
            proved.Folder.Log("app", $"build {proved.Build.Build} ends before its first good start, as the proofs ask (the way back)");
            Environment.Exit(3);
        }
        // Every start takes it: Windows' notifications need an explicit identity of an app that is not packaged.
        WindowsEntries.TakeAppId();

        // The library's store, kept in the user's LocalAppData: with no hub it opens on Add this PC. A build with the
        // proofs' switch can show the sample fleet of the Mac and iPhone apps (FOUNDERIZER_SAMPLE=1) or take a hub
        // from the environment (app/windows/vm/README.md); a release build has neither.
        IFleetSource source;
        var store = StoreSource.FromProofs();
        try
        {
            if (Proofs.Variable("FOUNDERIZER_SAMPLE") == "1") source = new SampleSource();
            else if (store is not null) source = store;
            else source = store = StoreSource.Create();
        }
        catch (Exception e)
        {
            // An exception before the window has no window to raise it in: the proofs' log takes it.
            Note(e.ToString());
            throw;
        }
        var arguments = Environment.GetCommandLineArgs();
        var afterUpdate = arguments.FirstOrDefault(a => a.StartsWith("--after-update", StringComparison.Ordinal));
        try
        {
            window = new MainWindow(source, History.Asked(arguments));
        }
        catch (Exception e)
        {
            Note(e.ToString());
            throw;
        }
        if (install is { } it) updater = new Updater(it.Folder, it.Build, source, window, afterUpdate);
        if (afterUpdate is not null && updater is not null) Updater.ShowWithoutActivation(window);
        else window.Activate();
        if (store is not null && await store.StartAsync() is { } refused) Note("the store did not start: " + refused);
    }

    private static void Note(string line)
    {
        if (DebugLog is null) return;
        try { File.AppendAllText(DebugLog, line + Environment.NewLine); } catch (IOException) { }
    }
}
