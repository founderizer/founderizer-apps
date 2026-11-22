namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**The words of the first run's pages that the library does not give**, because the Mac holds them in its views
/// only (the Mac's <c>SetupBack</c>, <c>SetupProgress</c>, <c>ServerBoxes</c>, <c>ServersSlider</c>, <c>FleetBuildLine</c>,
/// <c>ServerBoxChoice</c>, <c>CloudChoice</c>, <c>PolicyLines</c>, <c>MachineInstallForm</c>, <c>MachineInstallRun</c> and
/// <c>VerifyChecklistView</c>): each the Mac's sentence, held to the Mac's string catalog by a test, as the library's
/// <c>SetupScreens</c> are.</summary>
internal static class SetupViewWords
{
    public const string Back = "Back";
    public const string Server = "Server", Hub = "Hub", Agent = "Agent";
    public const string AServer = "A server";
    public const string Slider = "Servers, from lower cost to more secure";

    /// <summary>What an assistive app reads for the steps on Back's line.</summary>
    public static string Progress(int current, int count, string name) =>
        current < count ? $"Step {current + 1} of {count}: {name}." : $"All {count} steps are done.";

    // ------------------------------------------------------------ piece U2: the key, the VPS and the build pages

    /// <summary>The minutes left on a server's line of the build page (the Mac's <c>FleetBuildLine</c>).</summary>
    public static string Minutes(int minutes) => $"{minutes} min";

    /// <summary>The list under a server of "Your fleet" (the Mac's <c>ServerBoxChoice.of</c>): the other providers, and the
    /// words of one whose token this PC holds none of.</summary>
    public const string AnotherProvider = "Another provider", AsksForToken = "asks for its token";

    /// <summary>The account's list (the Mac's <c>CloudChoice</c>): the new server's row.</summary>
    public const string NewServer = "New server";

    /// <summary>The lines that a policy file must get by the owner's own hand (the Mac's <c>PolicyLines</c>).</summary>
    public const string Copy = "Copy", Copied = "Copied";

    /// <summary>The title of Windows' own picker of the owner's key (the Mac's <c>chooseKey()</c> panel).</summary>
    public const string ChooseKeyTitle = "Choose the SSH private key for this server";

    /// <summary>An install that stopped (the Mac's <c>MachineInstallRun</c>): each step's word and the stop's row. "Report
    /// a problem" beside Try again comes with its form (piece U11).</summary>
    public const string Done = "Done", Failed = "Failed", Waiting = "Waiting";
    public const string InstallStopped = "The install stopped";

    /// <summary>The checks of a server that did not pass (the Mac's <c>VerifyChecklistView</c>).</summary>
    public const string Checks = "Checks", Ready = "Ready", NotReady = "Not ready", NotChecked = "Not checked", Warning = "Warning";
    public const string ChecksFooter = "Each failed check carries its own fix. Put it right, then check this server again from its page.";
}
