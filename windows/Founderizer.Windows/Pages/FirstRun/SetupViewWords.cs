namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**The words of the first run's pages that the library does not give**, because the Mac holds them in its views
/// only (the Mac's <c>SetupBack</c>, <c>SetupProgress</c>, <c>ServerBoxes</c> and <c>ServersSlider</c>): each the Mac's
/// sentence, held to the Mac's string catalog by a test, as the library's <c>SetupScreens</c> are.</summary>
internal static class SetupViewWords
{
    public const string Back = "Back";
    public const string Server = "Server", Hub = "Hub", Agent = "Agent";
    public const string AServer = "A server";
    public const string Slider = "Servers, from lower cost to more secure";

    /// <summary>What an assistive app reads for the steps on Back's line.</summary>
    public static string Progress(int current, int count, string name) =>
        current < count ? $"Step {current + 1} of {count}: {name}." : $"All {count} steps are done.";
}
