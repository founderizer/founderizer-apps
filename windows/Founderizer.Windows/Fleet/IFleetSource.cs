using System;
using System.Collections.Generic;
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

    /// <summary>Sends the chat's draft through the store's outbox. Null when it went; else the owner's words.</summary>
    Task<string?> SendMessageAsync(string agent);

    /// <summary>His words in a request's answer box, kept as he types.</summary>
    void SetAnswerDraft(long need, string text);

    /// <summary>Sends a request's typed answer through the outbox.</summary>
    Task<string?> AnswerAsync(long need);

    /// <summary>The ticks of a request whose options combine ("Send N").</summary>
    Task<string?> TickAsync(long need, IReadOnlyCollection<int> choices);

    /// <summary>A press on one of a request's options.</summary>
    void Press(long need, int choice);

    /// <summary>Pause, Stop or Resume of a task.</summary>
    Task<string?> ControlAsync(long task, TaskControl action);

    /// <summary>Guidance for a task.</summary>
    Task<string?> GuideAsync(long task, string text);

    /// <summary>A read now (the line's Try again, the request line's Refresh receipt).</summary>
    Task RefreshAsync();

    /// <summary>The request line's Try again: the write that waits goes again.</summary>
    Task RetryAsync();

    /// <summary>The request line's Discard: a refused write is taken away.</summary>
    void DiscardRefused();

    /// <summary>A file that he added to a composer ("agent:&lt;name&gt;" or "need:&lt;id&gt;"). Null when it was
    /// taken; else the owner's words.</summary>
    Task<string?> AddFileAsync(string composer, string name, byte[] bytes, string? mime);

    /// <summary>A file of a composer that did not go up goes again.</summary>
    Task<string?> UploadAsync(string composer, Guid file);

    /// <summary>The cross of a file in a composer.</summary>
    void RemoveFile(string composer, Guid file);

    /// <summary>The bytes of a file of a message.</summary>
    Task<byte[]> FileAsync(MessageAttachment file);

    /// <summary>The notifications that are due, once each, also while the window is behind (the store's Notified).</summary>
    event EventHandler<IReadOnlyList<Notice>>? Notified;

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
