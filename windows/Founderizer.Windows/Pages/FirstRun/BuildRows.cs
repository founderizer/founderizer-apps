using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**The lines of the build page, and whether its title moves** (the Mac's <c>FirstRunView</c>: <c>buildRows</c>,
/// <c>hubRow</c>, <c>managersRow</c> and <c>buildWaits</c>, which the Mac keeps in its view): one line under each box of
/// the fleet, by the box's place (the hub's server first, then the manager's own), from the first run's state. It calls
/// no WinUI, so a test reads it.</summary>
internal static class BuildRows
{
    /// <summary>The steps of the hub's install and of a server's join, as their plans name them, for the minutes of a
    /// server that is still made (the Mac's <c>hubPlan</c> and <c>joinPlan</c>).</summary>
    public static readonly IReadOnlyList<string> HubPlan =
        InstallPlan.Hub(new InstallTarget("server"), "", null).Steps.Select(s => s.Id).ToList();
    public static readonly IReadOnlyList<string> JoinPlan =
        InstallPlan.Join(new InstallTarget("server"), "", "", null).Steps.Select(s => s.Id).ToList();

    /// <summary>A line for each box: the hub's server, and on 2 servers and 1 per agent the manager's own.</summary>
    public static IReadOnlyList<FleetBuildRow?> Of(SetupState s, bool managersChoiceOpen, DateTimeOffset now) =>
        s.MakesManagersServer ? [Hub(s, now), Managers(s, managersChoiceOpen, now)] : [Hub(s, now)];

    /// <summary>**The hub's server**: its build at the provider, an install that runs (with its four parts, held by its
    /// press: <see cref="InstallView.Phases"/>), the start of one with no step yet, or ready once its checks came.</summary>
    public static FleetBuildRow Hub(SetupState s, DateTimeOffset now)
    {
        if (s.CloudBuilds) return FleetBuildRow.Building(s.Cloud?.Stage == CloudStep.Stage.Joining, HubPlan);
        if (s.Install.Checklist is not null) return FleetBuildRow.Ready;
        if (s.Install.Phases(Seconds(now - s.Install.RunningSince)) is { } phases)
            return FleetBuildRow.Installing(phases, afterBuild: s.HubBuilt);
        return FleetBuildRow.Starting(HubPlan, s.HubBuilt);
    }

    /// <summary>**The manager's own server**: its build, its wait for the hub, its join; none before its build begins,
    /// none while its choice after a refusal shows, and none after a join that stopped, whose server its setup installs
    /// again.</summary>
    public static FleetBuildRow? Managers(SetupState s, bool choiceOpen, DateTimeOffset now)
    {
        if (!s.MakesManagersServer || choiceOpen) return null;
        var install = s.ManagerInstall;
        if (install.Checklist is not null) return FleetBuildRow.Ready;
        if (install.Running)
        {
            var name = ManagerName.Shown(s.ManagerName);
            return install.Phases(Seconds(now - install.RunningSince)) is { } phases
                ? FleetBuildRow.Installing(phases, name, afterBuild: true)
                : FleetBuildRow.Starting(JoinPlan, afterBuild: true);
        }
        if (install.Failure is not null) return null;
        return s.ManagersCloud?.Stage switch
        {
            CloudStep.Stage.Making => FleetBuildRow.Building(false, JoinPlan),
            CloudStep.Stage.Joining => FleetBuildRow.Building(true, JoinPlan),
            _ => s.ManagersServer is not null ? FleetBuildRow.WaitsForHub(JoinPlan) : null,
        };
    }

    /// <summary>**The build page's title moves while something builds**; with only the owner's choice of the manager's
    /// server left, it stands (the Mac's <c>buildWaits</c>).</summary>
    public static bool Waits(SetupState s, bool managersChoiceOpen)
    {
        var managersBuilds = s.ManagersCloud?.Stage is CloudStep.Stage.Making or CloudStep.Stage.Joining;
        return s.Install.Running || s.ManagerInstall.Running || managersBuilds || !managersChoiceOpen;
    }

    private static double Seconds(TimeSpan since) => Math.Max(0, since.TotalSeconds);
}
