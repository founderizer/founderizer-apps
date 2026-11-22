using Founderizer.Setup.FirstRun;
using Founderizer.Windows.Pages.FirstRun;

namespace Founderizer.Windows.Navigation;

internal static partial class Routes
{
    /// <summary>**The first run's pages of the fleet's network and servers** (piece U2, picture set 8, pictures 8 to 17 with
    /// 13d and 14b): Your Tailscale key, A VPS for your fleet, a provider's token with "Your fleet" and its build, Other
    /// VPS with the owner's key once, and the hub's install with the build page and its stop. The manager's own setup comes
    /// with piece U3.</summary>
    internal static readonly Family FleetPages = Add(new Family
    {
        Steps =
        {
            [SetupPage.Key] = host => new KeyPage(host),
            [SetupPage.Cloud] = host => new CloudPage(host),
            [SetupPage.Token] = host => new TokenPage(host),
            [SetupPage.Vps] = host => new VpsPage(host),
            [SetupPage.Installing] = host => new InstallPage(host),
        },
    });
}
