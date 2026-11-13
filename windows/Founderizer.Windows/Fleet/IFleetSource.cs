using System;
using System.Threading.Tasks;
using Founderizer.Core;

namespace Founderizer.Windows.Fleet;

/// <summary>A new state of the store, with the moment it reached the window's side (Stopwatch ticks), for the reading of
/// the time from an answer to the change on screen.</summary>
public sealed record FleetChange(StoreState State, long ArrivedTicks);

/// <summary>Where the window's state comes from: the library's store against a hub (<see cref="StoreSource"/>), or the
/// sample fleet of the Mac and iPhone apps (<see cref="SampleSource"/>). The screens draw only what the library's
/// models (Screens.Pane and the others) make of <see cref="State"/>, and every write is the store's own
/// ("What the screens call" in app/windows/README.md).</summary>
public interface IFleetSource : IAsyncDisposable
{
    StoreState State { get; }

    /// <summary>Raised on any thread, in order, after each change.</summary>
    event EventHandler<FleetChange>? Changed;

    /// <summary>The window came to the front (true) or left it (false).</summary>
    void SetFront(bool front);

    /// <summary>The chat that a page shows now, or null.</summary>
    void OpenChat(string? agent);

    /// <summary>The task whose page shows now, or null.</summary>
    void OpenTask(long? task);

    /// <summary>His words in a chat's composer, kept as he types.</summary>
    void SetDraft(string agent, string text);

    /// <summary>Sends the chat's draft through the store's outbox.</summary>
    Task SendMessageAsync(string agent);

    /// <summary>His words in a request's answer box, kept as he types.</summary>
    void SetAnswerDraft(long need, string text);

    /// <summary>Sends a request's typed answer through the outbox.</summary>
    Task AnswerAsync(long need);

    /// <summary>A press on one of a request's options.</summary>
    void Press(long need, int choice);

    /// <summary>Pause or Stop of a task.</summary>
    Task ControlAsync(long task, TaskControl action);

    /// <summary>Guidance for a task.</summary>
    Task GuideAsync(long task, string text);

    /// <summary>Settings' Connect: the hub's address as he typed it. Null when it took it; else the owner's words.</summary>
    Task<string?> ConnectAsync(string address);

    /// <summary>Add this PC: a whole code. Null when the PC took its key; else the owner's words.</summary>
    Task<string?> EnrollAsync(string code);

    /// <summary>Settings' Forget the key. Null when it went; else the owner's words.</summary>
    string? ForgetKey();

    /// <summary>Reads this PC as the hub names it, for Settings' address line, when Settings opens (the iPhone's
    /// readDevice).</summary>
    Task ReadDeviceAsync();
}
