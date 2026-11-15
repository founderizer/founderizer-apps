using System.Globalization;
using Founderizer.Core;

namespace Founderizer.Windows.Navigation;

/// <summary>What the pane's rows show beside their words, from the library's <see cref="PaneModel"/>.</summary>
public static class PaneMarks
{
    /// <summary>The count in the pill of the Needs you row (the Mac's FleetView.swift needsRow and SidebarBadge): the
    /// open items, and no pill (null) when none is open. After his last answer the row stays while Needs you is open,
    /// selected and with no count (approved picture 12).</summary>
    public static string? NeedsBadge(PaneModel pane) =>
        pane.NeedsCount > 0 ? pane.NeedsCount.ToString(CultureInfo.CurrentCulture) : null;
}
