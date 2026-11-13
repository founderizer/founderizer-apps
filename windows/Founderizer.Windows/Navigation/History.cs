using System;
using System.Collections.Generic;
using Founderizer.Core;

namespace Founderizer.Windows.Navigation;

/// <summary>The window's history of pages (the library's <see cref="Page"/>), as the Mac's Back and Forward
/// (FleetView.swift historyButtons): a new page puts the one he leaves on the back list and clears the forward list;
/// Back and Forward move one page along the lists.</summary>
public sealed class History
{
    private readonly List<Page> back = new();
    private readonly List<Page> forward = new();

    public History(Page first) => Current = first;

    public Page Current { get; private set; }
    public bool CanGoBack => back.Count > 0;
    public bool CanGoForward => forward.Count > 0;

    /// <summary>Raised after each move.</summary>
    public event Action? Changed;

    public void Go(Page page)
    {
        if (page == Current) return;
        back.Add(Current);
        forward.Clear();
        Current = page;
        Changed?.Invoke();
    }

    public void GoBack()
    {
        if (back.Count == 0) return;
        forward.Add(Current);
        Current = back[^1];
        back.RemoveAt(back.Count - 1);
        Changed?.Invoke();
    }

    public void GoForward()
    {
        if (forward.Count == 0) return;
        back.Add(Current);
        Current = forward[^1];
        forward.RemoveAt(forward.Count - 1);
        Changed?.Invoke();
    }

    /// <summary>The first page of a launch, chosen once a reading can choose it (FleetStore.chooseHome): it replaces the
    /// page that stood before, with no way back to that one.</summary>
    public void Start(Page page)
    {
        back.Clear();
        forward.Clear();
        if (page == Current) return;
        Current = page;
        Changed?.Invoke();
    }

    /// <summary>A page that the fleet no longer has (an agent that left) leaves both lists.</summary>
    public void Forget(Func<Page, bool> gone)
    {
        back.RemoveAll(p => gone(p));
        forward.RemoveAll(p => gone(p));
    }

    /// <summary>The page that the launch argument -openPage asks for, as the Mac takes it (FleetStore.asked):
    /// needs, tasks, settings or agent.&lt;name&gt;. Null for none or another word.</summary>
    public static Page? Asked(IReadOnlyList<string> arguments)
    {
        for (int i = 0; i + 1 < arguments.Count; i++)
        {
            if (arguments[i] != "-openPage") continue;
            var page = arguments[i + 1];
            return page switch
            {
                "needs" => Page.Needs,
                "tasks" or "activity" => Page.Tasks,
                "settings" => Page.Settings,
                _ when page.StartsWith("agent.", StringComparison.Ordinal) && page.Length > 6 => Page.Chat(page[6..]),
                _ when page.StartsWith("task.", StringComparison.Ordinal)
                       && long.TryParse(page[5..], System.Globalization.NumberStyles.None,
                                        System.Globalization.CultureInfo.InvariantCulture, out var id) && id > 0 => Page.OfTask(id),
                _ => null,
            };
        }
        return null;
    }
}
