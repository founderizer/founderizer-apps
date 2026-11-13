using System;
using Founderizer.Core;

namespace Founderizer.Windows.Fleet;

/// <summary>A new state of the store, with the moment it reached the window's side (Stopwatch ticks), for the reading of
/// the time from an answer to the change on screen.</summary>
public sealed record FleetChange(StoreState State, long ArrivedTicks);

/// <summary>Where the window's state comes from: the library's store against a hub (<see cref="StoreSource"/>), or the
/// sample fleet of the Mac and iPhone apps (<see cref="SampleSource"/>). The screens draw only what the library's
/// models (Screens.Pane and the others) make of <see cref="State"/>.</summary>
public interface IFleetSource : IAsyncDisposable
{
    StoreState State { get; }

    /// <summary>Raised on any thread, in order, after each change.</summary>
    event EventHandler<FleetChange>? Changed;

    /// <summary>The window came to the front (true) or left it (false).</summary>
    void SetFront(bool front);
}
