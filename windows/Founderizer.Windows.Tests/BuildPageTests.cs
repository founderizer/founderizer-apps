using System;
using System.Collections.Generic;
using System.IO;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Founderizer.Windows.Fleet;
using Founderizer.Windows.Pages.FirstRun;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Windows.Tests;

/// <summary>**The window's own parts of piece U2**: the lines of the build page and its title (the Mac keeps them in its
/// view, so the window ports them: <see cref="BuildRows"/>), and the one read of the owner's key file
/// (<see cref="KeyFile"/>).</summary>
[TestClass]
public sealed class BuildPageTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 22, 12, 0, 0, TimeSpan.Zero);

    private static CloudStep.View Cloud(CloudStep.Stage stage, CloudStep.Stage? stopped = null) =>
        new(stage, stopped, null, CloudProvider.Hetzner, CloudServerUse.Hub, null, [], [], null, true, false, 1, true);

    /// <summary>A first run on 2 servers, from the slider's page, whose hub's server the provider makes.</summary>
    private static SetupState Fleet(CloudStep.Stage hub, CloudStep.Stage managers = CloudStep.Stage.Choosing) => new()
    {
        Page = SetupPage.Token,
        Named = true,
        Shaped = true,
        ServersStep = ServersStep.Two,
        ManagerName = "Juno",
        Cloud = Cloud(hub),
        ManagersCloud = Cloud(managers),
    };

    private static InstallView Running(params InstallProgress[] steps) =>
        new(true, steps, BuildRows.HubPlan, Now.AddSeconds(-30), null, null, null, false);

    /// <summary>**The hub's line follows its server from the provider to its checks** (the Mac's <c>hubRow</c>). The bug:
    /// the line of the provider's build ("Making your server") stays once the server is on the network and its install
    /// runs, or a server that is ready keeps a line and a bar under its box.</summary>
    [TestMethod]
    public void TheHubsLineFollowsItsServerFromTheProviderToItsChecks()
    {
        Assert.AreEqual("Making your server", BuildRows.Hub(Fleet(CloudStep.Stage.Making), Now).Words);
        Assert.AreEqual("Starting your server", BuildRows.Hub(Fleet(CloudStep.Stage.Joining), Now).Words);

        var installing = Fleet(CloudStep.Stage.Token) with
        {
            Page = SetupPage.Installing,
            HubBuilt = true,
            Install = Running(new InstallProgress("read", "Read the server", "", ProgressState.Done),
                              new InstallProgress("network", "The private network", "", ProgressState.Done),
                              new InstallProgress("code", "The Founderizer code", "", ProgressState.Done),
                              new InstallProgress("plan", "The plan", "", ProgressState.Done),
                              new InstallProgress("start", "Install the hub", "", ProgressState.Done),
                              new InstallProgress("wait_claim", "Wait for the link code", "", ProgressState.Done),
                              new InstallProgress("claim", "Claim the hub", "", ProgressState.Done),
                              new InstallProgress("wait_ready", "Finish the install", "", ProgressState.Running,
                                                  ["Founderizer step 14: security updates"])),
        };
        var row = BuildRows.Hub(installing, Now);
        Assert.AreEqual("Installing security updates", row.Words);
        Assert.IsTrue(row.Minutes > 0);
        Assert.AreEqual(1.0, row.Parts![0]);
        Assert.AreEqual(1.0, row.Parts[1]);
        Assert.IsTrue(row.Parts[2] is > 0 and < 1, "the part that runs");

        var ready = installing with { Install = installing.Install with { Running = false, Checklist = new VerifyChecklist([new VerifyCheck("service", "ok", "")]) } };
        Assert.AreEqual(FleetBuildRow.Ready, BuildRows.Hub(ready, Now));
        Assert.IsNull(BuildRows.Hub(ready, Now).Parts);
    }

    /// <summary>**The manager's own server has a line while it is made and waits for the hub, and none while its choice
    /// after a refusal shows** (the Mac's <c>managersRow</c>). The bug: a line and a bar over the refused server's why and
    /// its press, or no line for a server that waits for the hub, which reads as a server that nobody makes.</summary>
    [TestMethod]
    public void TheManagersServerHasALineWhileItBuildsAndNoneWhileItsChoiceShows()
    {
        var waits = Fleet(CloudStep.Stage.Token, CloudStep.Stage.Token) with
        {
            Page = SetupPage.Installing,
            Install = Running(new InstallProgress("read", "Read the server", "", ProgressState.Running)),
            ManagersServer = new MadeServer("worker-2", "100.64.0.11", "1002", CloudProvider.Hetzner),
        };
        Assert.AreEqual("Waiting for your hub", BuildRows.Managers(waits, choiceOpen: false, Now)!.Words);
        Assert.AreEqual("Making your server", BuildRows.Managers(waits with { ManagersCloud = Cloud(CloudStep.Stage.Making) }, false, Now)!.Words);
        Assert.AreEqual(2, BuildRows.Of(waits, false, Now).Count);

        // The provider refused it: the build had named the server before it asked, and no provider's id or address came.
        var refused = waits with
        {
            ManagersServer = new MadeServer("worker-2", null, null, CloudProvider.Hetzner),
            ManagersCloud = Cloud(CloudStep.Stage.Choosing, CloudStep.Stage.Making),
        };
        Assert.IsNull(BuildRows.Managers(refused, choiceOpen: true, Now));
        // On 1 server the press makes the hub's server alone: one box, one line.
        Assert.AreEqual(1, BuildRows.Of(waits with { ServersStep = ServersStep.One }, false, Now).Count);
    }

    /// <summary>**The title stands when only the owner's choice is left** (the Mac's <c>buildWaits</c>; set 8, picture
    /// 16: "The title stands: only his choice is left"). The bug: the title moves over a page that waits for his press,
    /// as the library's screen of the build page says for every state of it.</summary>
    [TestMethod]
    public void TheBuildTitleStandsWhenOnlyTheOwnersChoiceIsLeft()
    {
        var turn = Fleet(CloudStep.Stage.Token, CloudStep.Stage.Choosing) with
        {
            Page = SetupPage.Installing,
            Install = new InstallView(false, [], BuildRows.HubPlan, Now, null, new VerifyChecklist([new VerifyCheck("service", "ok", "")]), null, false),
        };
        Assert.IsFalse(BuildRows.Waits(turn, managersChoiceOpen: true));
        Assert.IsTrue(BuildRows.Waits(turn, managersChoiceOpen: false), "nothing to choose: the fleet still builds");
        Assert.IsTrue(BuildRows.Waits(turn with { Install = Running() }, managersChoiceOpen: true), "the hub still installs");
        Assert.IsTrue(BuildRows.Waits(turn with { ManagersCloud = Cloud(CloudStep.Stage.Making) }, managersChoiceOpen: true),
                      "the manager's server is made again");
    }

    /// <summary>**The owner's key file is read once, at most the model's limit, and only its name goes on** (plan 5.5 and
    /// U2). The bug: a file of any size read whole into memory, or its folder given to the model, which shows the name in
    /// the row and must keep no path.</summary>
    [TestMethod]
    public void TheKeyFileIsReadOnceAtMostTheLimitAndOnlyItsNameGoesOn()
    {
        var folder = Path.Combine(Path.GetTempPath(), "founderizer-key-file-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var small = Path.Combine(folder, "id_example");
            File.WriteAllBytes(small, [1, 2, 3]);
            var read = KeyFile.Read(small);
            Assert.IsNotNull(read);
            CollectionAssert.AreEqual(new byte[] { 1, 2, 3 }, read.Value.Bytes);
            Assert.AreEqual("id_example", read.Value.Name);

            var large = Path.Combine(folder, "large.ppk");
            File.WriteAllBytes(large, new byte[Founderizer.Remote.OwnerKeyFile.MaxLength + 4096]);
            Assert.AreEqual(Founderizer.Remote.OwnerKeyFile.MaxLength, KeyFile.Read(large)!.Value.Bytes.Length);

            Assert.IsNull(KeyFile.Read(Path.Combine(folder, "gone")));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
