using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Setup.FirstRun;
using Founderizer.Windows.Pages.FirstRun;

namespace Founderizer.Windows.Navigation;

/// <summary>**The registry of the window's page families** (windows-app-plan-v2.md, section 6: "A page family joins the
/// window through one file of its own: <c>Navigation/Routes.&lt;Family&gt;.cs</c>, which U1's registry reads. So a window
/// piece adds files and edits none."). A family's file is a part of this class with one field:
///
/// <code>internal static readonly Family Agents = Add(new Family { Can = ["agents"], Steps = { ... } });</code>
///
/// Each family says the hub's names of what it can do (<see cref="Family.Can"/>: the page families of
/// <c>owner_computer.can</c>, which the store sends the hub, rule 17), and draws the first run's pages that it has
/// (<see cref="Family.Steps"/>). The first run's frame (<see cref="FirstRunHost"/>) asks <see cref="Step"/> for the view
/// of each page; a page that no family draws yet shows its frame alone.</summary>
internal static partial class Routes
{
    /// <summary>One family of pages.</summary>
    internal sealed class Family
    {
        /// <summary>The hub's names of what this family can do (<c>owner_computer.can</c>): none for the first run.</summary>
        public IReadOnlyList<string> Can { get; init; } = [];

        /// <summary>The first run's pages that this family draws, each made when its page opens.</summary>
        public Dictionary<SetupPage, Func<StepHost, IStepView>> Steps { get; init; } = new();
    }

    // No initializer of its own: each family's field adds to it while the class is set up, in any order of the files.
    private static List<Family>? families;

    private static Family Add(Family family)
    {
        (families ??= []).Add(family);
        return family;
    }

    /// <summary>The families, once every family's file has added its own (reading this field sets the class up).</summary>
    private static IReadOnlyList<Family> All => families ?? [];

    /// <summary>What this build can do, as the hub names it (<c>StoreSettings.Can</c>), from the families that it has.</summary>
    public static IReadOnlyList<string> Can => All.SelectMany(f => f.Can).Distinct(StringComparer.Ordinal).ToList();

    /// <summary>The view of a page of the first run, or null while no family draws it.</summary>
    public static Func<StepHost, IStepView>? Step(SetupPage page) =>
        All.Select(f => f.Steps.GetValueOrDefault(page)).FirstOrDefault(made => made is not null);
}
