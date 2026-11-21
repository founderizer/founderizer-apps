using Founderizer.Setup.FirstRun;
using Founderizer.Windows.Pages.FirstRun;

namespace Founderizer.Windows.Navigation;

internal static partial class Routes
{
    /// <summary>**The first run's first pages** (piece U1, picture set 8, pictures 1 to 7): the welcome page with W8, Help
    /// improve Founderizer, Name your manager, the manager's AI provider, Your fleet's servers, and Tailscale on this
    /// PC. The pages after them come with piece U2 (the key, the VPS, the build) and U3 (the manager's setup).</summary>
    internal static readonly Family FirstRunPages = Add(new Family
    {
        Steps =
        {
            [SetupPage.Welcome] = host => new WelcomePage(host),
            [SetupPage.ErrorReports] = host => new ReportsPage(host),
            [SetupPage.Name] = host => new NamePage(host),
            [SetupPage.AiProvider] = host => new ProviderPage(host),
            [SetupPage.Servers] = host => new FleetServersPage(host),
            [SetupPage.Network] = host => new NetworkPage(host),
        },
    });
}
