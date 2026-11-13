using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace Founderizer.Core;

/// <summary>Where the device's key lives. The screens give the Windows one (the user's protected storage, later the
/// TPM, slice 1.5); the tests give <see cref="MemoryKeyStore"/>. The key never goes into a file of the store, a log or an
/// address. <see cref="Read"/> may throw: the store then says that the key did not open.</summary>
public interface IDeviceKeyStore
{
    /// <summary>True unless the store knows that it holds no key.</summary>
    bool Has { get; }
    string? Read();
    void Write(string key);
    void Remove();
}

/// <summary>A key store in memory, for the tests and for a run that keeps nothing.</summary>
public sealed class MemoryKeyStore(string? key = null) : IDeviceKeyStore
{
    private string? key = key;
    public bool Has => key is not null;
    public string? Read() => key;
    public void Write(string key) => this.key = key;
    public void Remove() => key = null;
}

/// <summary>The protection of the device key at rest, which the screens give: Windows' own protection of the user's
/// data, later the TPM. <see cref="Protect"/> gives the bytes that the key's file holds, and <see cref="Unprotect"/>
/// gives the key's bytes back, or throws when they do not open. The library has no protection of its own, so that no
/// build keeps a key in the clear by mistake.</summary>
public interface IKeyProtection
{
    byte[] Protect(byte[] key);
    byte[] Unprotect(byte[] stored);
}

/// <summary>The device key in one file, through the screens' <see cref="IKeyProtection"/>: it stays between starts, so
/// that a start needs no new code (the iPhone keeps it in its keychain). The file is written whole or not at all, and
/// on a system with file modes only this user may read it. Keep it outside the store's folder, which holds no key.</summary>
public sealed class FileKeyStore(string path, IKeyProtection protection) : IDeviceKeyStore
{
    public string FilePath { get; } = path;

    public bool Has => File.Exists(FilePath);

    public string? Read()
    {
        if (!File.Exists(FilePath)) return null;
        var plain = protection.Unprotect(File.ReadAllBytes(FilePath));
        try { return Encoding.UTF8.GetString(plain); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    public void Write(string key)
    {
        var plain = Encoding.UTF8.GetBytes(key);
        byte[] stored;
        try { stored = protection.Protect(plain); }
        finally { CryptographicOperations.ZeroMemory(plain); }
        if (Path.GetDirectoryName(Path.GetFullPath(FilePath)) is { } folder) Directory.CreateDirectory(folder);
        var temporary = FilePath + ".new";
        var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using (var stream = new FileStream(temporary, options))
        {
            stream.Write(stored);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temporary, FilePath, overwrite: true);
    }

    /// <summary>Takes the key off this PC. A key file that is not there is no error.</summary>
    public void Remove()
    {
        File.Delete(FilePath + ".new");
        File.Delete(FilePath);
    }
}

/// <summary>The clocks of the store: this device's wall clock, a clock that only goes forward (uptime, for the cadence,
/// the cap and the holds), and a delay. The tests give their own.</summary>
public interface IStoreClock
{
    DateTimeOffset Now { get; }
    double Uptime { get; }
    System.Threading.Tasks.Task Delay(TimeSpan delay, System.Threading.CancellationToken cancel);
}

/// <summary>The real clocks.</summary>
public sealed class SystemClock : IStoreClock
{
    public static readonly SystemClock Shared = new();
    public DateTimeOffset Now => DateTimeOffset.UtcNow;
    public double Uptime => Environment.TickCount64 / 1000.0;
    public System.Threading.Tasks.Task Delay(TimeSpan delay, System.Threading.CancellationToken cancel) =>
        System.Threading.Tasks.Task.Delay(delay, cancel);
}

/// <summary>What one <see cref="OwnerStore"/> needs: the folder of its own files (the hub address, the last reading, the
/// newest items of each chat, the seen marks, the drafts and the outbox), the key store, and the client label of each
/// write.</summary>
public sealed record StoreSettings
{
    public required string Folder { get; init; }
    public required IDeviceKeyStore Keys { get; init; }
    /// <summary>The words of X-Fleet-Client: what the hub keeps as the client of each message ("founderizer-windows/1/…").</summary>
    public string ClientLabel { get; init; } = "founderizer-windows/1";
    public HubClientOptions Client { get; init; } = new();
    public IStoreClock Clock { get; init; } = SystemClock.Shared;
    /// <summary>This PC's Tailscale, so that a PC with no hub address finds its hub by itself (the Mac's findHub); null
    /// looks for none.</summary>
    public ITailscaleStatus? Tailscale { get; init; }
    /// <summary>The zone and culture of the models that a change compares; null is this PC's own at each change
    /// (<see cref="ScreenContext.Local"/>), as the screens draw them.</summary>
    public ScreenContext? Context { get; init; }
    /// <summary>For the tests: what asks one device whether it answers as a hub; null is its GET /health.</summary>
    internal Func<Uri, System.Threading.CancellationToken, System.Threading.Tasks.Task<bool>>? AnswersHealth { get; init; }
}

/// <summary>Where this device's key stands (the iPhone's keyState): none, locked (it needs the owner before it opens),
/// in hand, or it did not open.</summary>
public enum KeyState { None, Locked, InHand, Failed }

/// <summary>A file that the owner picked for a message or an answer (the iPhone's StagedFile). Its bytes wait in the
/// store's folder from the moment it is picked, so it stays between starts; then it goes up with its own number, so a
/// repeat is one file on the hub and never a second one. <see cref="File"/> is what the hub holds of it once its upload
/// worked, and only then does a message carry it.</summary>
public sealed record StagedFile
{
    /// <summary>The number of its upload (X-Fleet-Request-Id), and the name of its bytes in the store's folder.</summary>
    public required Guid RequestId { get; init; }
    public required string Name { get; init; }
    public required string Mime { get; init; }
    public required long Size { get; init; }
    /// <summary>What the hub called it, once its upload worked. Until then its bytes wait on this PC.</summary>
    public MessageAttachment? File { get; init; }
    /// <summary>Why its last upload did not work, in the owner's words.</summary>
    public string? Failure { get; init; }

    /// <summary>The hub's id of it, or null while it waits on this PC.</summary>
    public long? Id => File?.Id;
    public bool IsOnHub => File is not null;
}

/// <summary>One chat that the store holds: its items, oldest first, as far as this device read it.</summary>
public sealed record ChatPageState
{
    public required string Agent { get; init; }
    public ValueList<MobileChatItem> Items { get; init; } = ValueList<MobileChatItem>.Empty;
}

/// <summary>One task's page that the store holds: the task in full, its notes so far, its holds and outcomes.</summary>
public sealed record TaskPageState
{
    public required FleetTask Task { get; init; }
    public ValueList<ProgressNote> Notes { get; init; } = ValueList<ProgressNote>.Empty;
    public ValueList<TaskHold> Holds { get; init; } = ValueList<TaskHold>.Empty;
    public ValueList<TaskOutcome> Outcomes { get; init; } = ValueList<TaskOutcome>.Empty;
}

/// <summary>The store's whole state at one moment, immutable: what the screens draw from, through the models of
/// <see cref="Screens"/>. Each new state has a higher <see cref="Version"/>. The rules of the iPhone's MobileStore.</summary>
public sealed record StoreState
{
    /// <summary>The longest that a reading counts as current: the slowest cadence (30 s) and a request's whole time (15 s).</summary>
    public static readonly TimeSpan CurrentFor = TimeSpan.FromSeconds(45);
    /// <summary>The most characters of a message or an answer.</summary>
    public const int TextLimit = 16_000;

    public long Version { get; init; }
    /// <summary>The hub's address, or null on a PC that has none yet (no read, no words of an outage).</summary>
    public Uri? Hub { get; init; }
    public bool HasNoHub => Hub is null;
    /// <summary>The address error of the last Connect, in the owner's words.</summary>
    public string? AddressError { get; init; }
    public KeyState Key { get; init; }
    /// <summary>The key store's own words when the key did not open (for a screen reader).</summary>
    public string? KeyDetail { get; init; }
    /// <summary>This device as GET /ui/owner/devices names it.</summary>
    public MobileDevice? Device { get; init; }
    /// <summary>The newest reading of GET /ui/mobile, kept between launches.</summary>
    public MobileSnapshot? Fleet { get; init; }
    /// <summary>When that reading's body came (wall clock): a 304 does not move it.</summary>
    public DateTimeOffset? SnapshotAt { get; init; }
    /// <summary>When a read last answered (200 or 304): null at each launch until one does.</summary>
    public DateTimeOffset? LastRead { get; init; }
    /// <summary>The end of the last read attempt: every age counts from it.</summary>
    public DateTimeOffset? Clock { get; init; }
    /// <summary>The last read failed: the error, whether the hub decided (a definitive refusal), and its `auth`.</summary>
    public HubException? ReadError { get; init; }
    public bool ReadWasRefused { get; init; }
    public string? AuthProblem { get; init; }
    /// <summary>A request of the read now took longer than twice the slowest of the last good read.</summary>
    public bool ReadHeld { get; init; }
    /// <summary>The first read since the window came to the front runs, for its first second.</summary>
    public bool FirstReadWaits { get; init; }
    public bool Refreshing { get; init; }
    /// <summary>The chats as far as this device read them, by agent.</summary>
    public ImmutableDictionary<string, ChatPageState> Chats { get; init; } = ImmutableDictionary<string, ChatPageState>.Empty;
    public ImmutableDictionary<long, TaskPageState> TaskPages { get; init; } = ImmutableDictionary<long, TaskPageState>.Empty;
    /// <summary>The one write that waits for its receipt, or that the hub refused and waits for the owner.</summary>
    public PendingRequest? Pending { get; init; }
    /// <summary>A confirmed message that its chat has not read back yet: its bubble stays until then.</summary>
    public PendingRequest? Delivered { get; init; }
    public bool Sending { get; init; }
    /// <summary>What the owner must know about the last write.</summary>
    public string? SendError { get; init; }
    /// <summary>The outbox cannot be used, so nothing is sent; its words, and the system's.</summary>
    public string? StorageError { get; init; }
    public string? StorageErrorDetail { get; init; }
    /// <summary>The answers that the hub took, by request, until the reading folds their request.</summary>
    public ImmutableDictionary<long, PendingRequest> AnswersTaken { get; init; } = ImmutableDictionary<long, PendingRequest>.Empty;
    /// <summary>The presses that wait for the store to write, by request: the option's index.</summary>
    public ImmutableDictionary<long, int> WaitingPresses { get; init; } = ImmutableDictionary<long, int>.Empty;
    /// <summary>The time of the newest reply that the owner saw, by agent, for one hub and generation.</summary>
    public ImmutableDictionary<string, double> Seen { get; init; } = ImmutableDictionary<string, double>.Empty;
    public string? SeenContext { get; init; }
    /// <summary>One draft for each agent, and one for each open request.</summary>
    public ImmutableDictionary<string, string> Drafts { get; init; } = ImmutableDictionary<string, string>.Empty;
    public ImmutableDictionary<long, string> AnswerDrafts { get; init; } = ImmutableDictionary<long, string>.Empty;
    /// <summary>The files picked for a composer ("agent:&lt;name&gt;", "need:&lt;id&gt;"), in the order he picked them,
    /// kept between starts.</summary>
    public ImmutableDictionary<string, ValueList<StagedFile>> Staged { get; init; } = ImmutableDictionary<string, ValueList<StagedFile>>.Empty;
    /// <summary>The picked files whose upload runs now.</summary>
    public ImmutableHashSet<Guid> Uploading { get; init; } = ImmutableHashSet<Guid>.Empty;
    /// <summary>The files of messages whose bytes are read now, and those whose last read failed ("Not loaded").</summary>
    public ImmutableHashSet<long> FilesReading { get; init; } = ImmutableHashSet<long>.Empty;
    public ImmutableHashSet<long> FilesUnloaded { get; init; } = ImmutableHashSet<long>.Empty;
    /// <summary>Why the last file that he picked was not taken (its type, its size, the count), in his words, and the
    /// system's words when this PC could not keep it.</summary>
    public string? FileError { get; init; }
    public string? FileErrorDetail { get; init; }
    /// <summary>Where the search for a hub on this PC's Tailscale stands (a PC with no hub address looks for one).</summary>
    public HubSearch Search { get; init; }
    /// <summary>The chat and the task that a screen shows now: the store reads them first on each pass.</summary>
    public string? OpenChat { get; init; }
    public long? OpenTask { get; init; }
    /// <summary>The window is in front: the store reads only then.</summary>
    public bool Front { get; init; }

    // ---------------------------------------------------------------- the rules that the screens ask

    /// <summary>The hub serves this owner feature.</summary>
    public bool Offers(string feature) => Fleet?.Offers(feature) == true;

    /// <summary>A write may go: the reading is current (a slow read does not stop it), nothing is sending, no request
    /// waits, and the outbox can be used.</summary>
    public bool AnswersWrites(DateTimeOffset now) =>
        Fleet is not null && ReadError is null && LastRead is { } read && Max(Clock, now) - read < CurrentFor;

    public bool IsFresh(DateTimeOffset now) => AnswersWrites(now) && !ReadHeld;

    /// <summary>The screens draw the reading as current: it is fresh, or the first read of this return runs for its
    /// first second. Otherwise every page draws it as the last reading.</summary>
    public bool ShowsCurrent(DateTimeOffset now) => IsFresh(now) || (FirstReadWaits && Fleet is not null && ReadError is null);

    public bool ReadsAgain => Refreshing && Fleet is not null && ReadError is null;

    public bool CanWrite(DateTimeOffset now) => AnswersWrites(now) && !Sending && Pending is null && StorageError is null;

    /// <summary>Why a write of the owner cannot go now, or null when it can. <c>Waits</c> when the cause ends by itself:
    /// another write is on its way, or the reading is not answered yet while a read of the hub can come in front. Such
    /// a write waits and goes then, because the window draws a change after the store made it, and a press can come
    /// between them. Otherwise the owner's words, and nothing goes: the words of the line that already shows the same
    /// cause (a request that waits in Settings, the connection line, the storage line).</summary>
    public WriteHold? HoldsWrites(DateTimeOffset now)
    {
        if (CanWrite(now)) return null;
        if (StorageError is { } storage) return new WriteHold(false, storage);
        if (Sending) return new WriteHold(true, null);
        if (Pending is not null) return new WriteHold(false, SavedRequestWaits);
        if (!HasNoHub && Front && ReadCanCome) return new WriteHold(true, null);
        return new WriteHold(false, UnavailableWords(now) ?? KeyWords ?? NoAnswer);
    }

    /// <summary>A write that cannot go while a request waits in the outbox (the Mac's "A saved request waits. Check it
    /// below.", with the place where the PC shows that request, as the iPhone does).</summary>
    public const string SavedRequestWaits = "A saved request waits. Check it in Settings.";
    /// <summary>The iPhone's line for a hub that does not answer.</summary>
    public const string NoAnswer = "Your hub did not answer. Check that its server is on.";
    /// <summary>A write that waited while the hub or its generation changed (the Mac's "Not saved. The hub connection
    /// changed.").</summary>
    public const string ConnectionChanged = "Not sent. The hub connection changed.";

    public bool CanRetry(DateTimeOffset now) =>
        Pending is { } p && AnswersWrites(now) && !Sending && StorageError is null && p.Refusal is null &&
        p.Hub == Hub && p.Database == Fleet?.Db;

    public bool KeyIsHeldBack => !HasNoHub && Key is KeyState.Locked or KeyState.Failed;
    public bool ReadCanCome => ReadError is null && !KeyIsHeldBack && AuthProblem is null;
    /// <summary>The PC waits for its first reading: the screens show their loading line.</summary>
    public bool ReadsTheHub => Fleet is null && ReadCanCome && !HasNoHub;

    /// <summary>The hub's clock now: the last body's time and how long ago it came.</summary>
    public double HubNow(DateTimeOffset now)
    {
        if (Fleet is null) return now.ToUnixTimeMilliseconds() / 1000.0;
        if (SnapshotAt is not { } at) return Fleet.Time;
        return Fleet.Time + Math.Max(0, (Max(Clock, now) - at).TotalSeconds);
    }

    /// <summary>The key's words when it holds the reading back.</summary>
    public string? KeyWords => HasNoHub ? null : Key switch
    {
        KeyState.Locked => "This PC's key is locked. Unlock it in Settings to read the hub.",
        KeyState.Failed => "This PC's key did not open. Unlock it in Settings to read the hub.",
        _ => null,
    };

    /// <summary>The connection line over every page, or null: the key first, then the hub's refusal of the key, then
    /// the hub's own reason, then no answer. A read that runs now is no problem.</summary>
    public string? UnavailableWords(DateTimeOffset now)
    {
        if (HasNoHub || IsFresh(now) || FirstReadWaits) return null;
        if (KeyWords is { } key) return key;
        if (AuthProblem is { } auth) return PcWords(HubException.AuthWords(auth));
        if (ReadWasRefused && ReadError is not null) return PcWords(ReadError.Message);
        if (ReadError is not null) return NoAnswer;
        return null;
    }

    /// <summary>The connection line's one action takes the owner to Settings (the key, or the hub's refusal of it);
    /// otherwise it is "Try again".</summary>
    public bool OutageNeedsSettings => KeyWords is not null || AuthProblem is not null;

    /// <summary>The roles of the agents of this reading.</summary>
    public AgentBook Names => Cached(ref names, fleet => AgentBook.Of(fleet));
    private Cache<AgentBook>? names;

    /// <summary>The marks of the agents of this reading, in the hub's order.</summary>
    public IReadOnlyDictionary<string, GlyphLook> Marks =>
        Cached(ref marks, fleet => GlyphLook.Team((fleet?.Agents ?? []).Select(a => a.Name)));
    private Cache<IReadOnlyDictionary<string, GlyphLook>>? marks;

    /// <summary>A value made from one reading, with the reading that it was made from. A record's `with` copies the
    /// private fields, so a state made with another <see cref="Fleet"/> holds a cache of the reading before: the cache
    /// counts only while its reading is this state's own, and is made again otherwise. One reference, so a read on
    /// another thread sees a whole cache or none.</summary>
    private sealed record Cache<T>(MobileSnapshot? Fleet, T Value);

    private T Cached<T>(ref Cache<T>? cache, Func<MobileSnapshot?, T> make)
    {
        var held = cache;
        if (held is null || !ReferenceEquals(held.Fleet, Fleet))
        {
            held = new Cache<T>(Fleet, make(Fleet));
            cache = held;
        }
        return held.Value;
    }

    /// <summary>The mark of one agent: its look in the team, or its own look when the reading does not hold it.</summary>
    public GlyphLook MarkOf(string agent) => Marks.TryGetValue(agent, out var look) ? look : new GlyphLook(agent);

    public MobileAgent? Agent(string name) => Fleet?.Agents.FirstOrDefault(a => a.Name == name);

    /// <summary>A chat's items as far as this device read them; empty before its first read.</summary>
    public IReadOnlyList<MobileChatItem> Items(string agent) =>
        Chats.TryGetValue(agent, out var chat) ? chat.Items : [];

    public bool HasRead(string agent) => Chats.ContainsKey(agent);

    /// <summary>A reply came in this agent's chat after the owner last had that chat open.</summary>
    public bool HasNewReply(string agent) =>
        Agent(agent)?.Last is { Side: "agent" } last && last.Ts > Seen.GetValueOrDefault(agent);

    /// <summary>The agent works on his newest chat message now (MobileStore.thinks).</summary>
    public bool Thinks(string agent, DateTimeOffset now) =>
        Fleet is not null && Agent(agent) is { } entry &&
        ChatWaiting.Thinks(entry, Items(agent), Fleet.Time, Offers("chat_waits"), ShowsCurrent(now));

    /// <summary>The agent's state as its row, its pill and its panel show it.</summary>
    public AgentStatus StatusOf(string agent, DateTimeOffset now) =>
        Fleet is not null && Agent(agent) is { } entry
            ? AgentStatus.Of(entry, Fleet, ShowsCurrent(now), Thinks(agent, now))
            : new AgentStatus(AgentState.Unknown);

    /// <summary>The ids of the files of a composer that the hub holds, in the order he picked them.</summary>
    public IReadOnlyList<long> ReadyFiles(string composer) =>
        Staged.TryGetValue(composer, out var files) ? files.Where(f => f.IsOnHub).Select(f => f.Id!.Value).ToList() : [];

    /// <summary>A file of this composer is on its way up, or did not go: its message waits (filesAreWaiting).</summary>
    public bool FilesWait(string composer) => Staged.TryGetValue(composer, out var files) && files.Any(f => !f.IsOnHub);

    /// <summary>The words under a composer while a file of it waits: it goes up now, or it did not go.</summary>
    public (string Words, bool Warning)? FileWaitWords(string composer) =>
        !FilesWait(composer) ? null
        : Staged[composer].Any(f => !f.IsOnHub && Uploading.Contains(f.RequestId)) ? ("Sending a file…", false)
        : ("A file did not go up. Send it again, or take it out.", true);

    /// <summary>The words of the waiting write (pendingSummary).</summary>
    public string? PendingSummary => Pending switch
    {
        null => null,
        { NeedId: { } need } => $"Answer to item {need}",
        { ReplacesRequestId: not null } p => "Correction to " + Names.Label(p.Recipient ?? "manager"),
        { Command: { } command } => command.Kind switch
        {
            "steer" => "Guidance to a task",
            _ => "A control of a task",
        },
        { } p => "Message to " + Names.Label(p.Recipient ?? "manager"),
    };

    /// <summary>The iPhone's words say "phone"; the PC's say "PC" (the owner's yes to the pictures, W5).</summary>
    internal static string PcWords(string words) =>
        words.Replace("This phone's", "This PC's").Replace("this phone's", "this PC's").Replace("This phone", "This PC")
             .Replace("this phone", "this PC").Replace("the phone sent", "the PC sent").Replace("The phone may", "The PC may")
             .Replace("the phone's routes", "the PC's routes").Replace("the phone's API", "the PC's API");

    private static DateTimeOffset Max(DateTimeOffset? a, DateTimeOffset b) => a is { } x && x > b ? x : b;
}

/// <summary>Where the search for a hub on this PC's Tailscale stands (the Mac's FleetOnTailscale.findHub).</summary>
/// <summary>Why a write cannot go now: it waits, and goes when the store can write, or it does not go, with the owner's
/// words.</summary>
public readonly record struct WriteHold(bool Waits, string? Words);

public enum HubSearch
{
    /// <summary>No search: the PC has a hub address, or it has not looked yet.</summary>
    None,
    /// <summary>It asks the devices of the network now.</summary>
    Looking,
    /// <summary>This PC is on no network: no Tailscale, or Tailscale does not run.</summary>
    NoNetwork,
    /// <summary>No device of the network answered as a hub.</summary>
    NoHub,
    /// <summary>A device answered: its address is the hub's now.</summary>
    Found,
}

/// <summary>The parts of the screens, for <see cref="StoreChange.Parts"/>: each one is a model of <see cref="Screens"/>.</summary>
[Flags]
public enum StoreParts
{
    None = 0,
    /// <summary>The pane (<see cref="Screens.Pane"/>): Needs you and its count, the agents' rows.</summary>
    Pane = 1,
    /// <summary>The connection line over every page (<c>Screens.Line</c>).</summary>
    Line = 2,
    /// <summary>The open chat (<see cref="StoreState.OpenChat"/>, <see cref="Screens.Chat"/>): its rows, its waiting
    /// line, its composer and its panel.</summary>
    Chat = 4,
    /// <summary>Needs you (<see cref="Screens.Needs"/>): its cards, and the page of each open request.</summary>
    Needs = 8,
    /// <summary>Tasks (<see cref="Screens.Board"/>): the lanes and the cards of each period.</summary>
    Board = 16,
    /// <summary>The open task's page (<see cref="StoreState.OpenTask"/>, <see cref="Screens.Task"/>).</summary>
    Task = 32,
    /// <summary>Settings (<see cref="Screens.Settings"/>) and Add this PC: the hub, the key, this PC, the last reading,
    /// the waiting write, and the search for a hub.</summary>
    Settings = 64,
}

/// <summary>What changed from one state to the next, so that a screen changes only those rows. The store raises one
/// only when a model of a screen changed (<see cref="Parts"/>): a read that brought nothing new raises none. A screen that
/// builds its model again from <see cref="After"/> compares its rows with <see cref="RowDiff"/>.</summary>
public sealed record StoreChange
{
    public required StoreState Before { get; init; }
    public required StoreState After { get; init; }
    /// <summary>The parts of the screens whose models changed: never <see cref="StoreParts.None"/> in a change that the
    /// store raises. Ages that move with the clock alone are a screen's own timer, not a change.</summary>
    public StoreParts Parts { get; init; }
    /// <summary>The reading of the fleet changed (any part of GET /ui/mobile).</summary>
    public bool Fleet { get; init; }
    /// <summary>The agents whose row in the pane came, went or looks different.</summary>
    public IReadOnlySet<string> Agents { get; init; } = ImmutableHashSet<string>.Empty;
    /// <summary>The chats whose items, requests, waiting line or composer may look different.</summary>
    public IReadOnlySet<string> Chats { get; init; } = ImmutableHashSet<string>.Empty;
    /// <summary>The requests that came, went or changed, or whose answer moved.</summary>
    public IReadOnlySet<long> Needs { get; init; } = ImmutableHashSet<long>.Empty;
    /// <summary>The task heads that came, went or changed (the board).</summary>
    public IReadOnlySet<long> Tasks { get; init; } = ImmutableHashSet<long>.Empty;
    /// <summary>The task pages that changed.</summary>
    public IReadOnlySet<long> TaskPages { get; init; } = ImmutableHashSet<long>.Empty;
    /// <summary>The hub, the key, the device, the reading's freshness or its problem changed (Settings, the line).</summary>
    public bool Connection { get; init; }
    /// <summary>The waiting write, its words or the sending changed.</summary>
    public bool Pending { get; init; }

    /// <summary>The change from <paramref name="before"/> to <paramref name="after"/>, with the models of both built at
    /// the same moment, in this PC's zone and culture.</summary>
    public static StoreChange Between(StoreState before, StoreState after) =>
        Between(before, after, after.Clock ?? DateTimeOffset.UtcNow, ScreenContext.Local);

    /// <summary>The change from <paramref name="before"/> to <paramref name="after"/>, with the models of both built at
    /// <paramref name="now"/> in <paramref name="context"/>.</summary>
    public static StoreChange Between(StoreState before, StoreState after, DateTimeOffset now, ScreenContext context) =>
        Between(before, after, StoreView.Of(before, now, context), StoreView.Of(after, now, context));

    /// <summary>The change between two states whose models are built: the store keeps the models of the last state that
    /// it raised.</summary>
    internal static StoreChange Between(StoreState before, StoreState after, StoreView was, StoreView now)
    {
        var rows = Rows(before, after);
        var (parts, agents) = now.Changes(was);
        return rows with { Parts = parts, Agents = agents };
    }

    /// <summary>The rows whose data changed between two states.</summary>
    private static StoreChange Rows(StoreState before, StoreState after)
    {
        var fleet = !ReferenceEquals(before.Fleet, after.Fleet);
        var agents = new HashSet<string>();
        var chats = new HashSet<string>();
        var needs = new HashSet<long>();
        var tasks = new HashSet<long>();
        if (fleet)
        {
            Differ(before.Fleet?.Agents ?? [], after.Fleet?.Agents ?? [], a => a.Name, agents);
            Differ((before.Fleet?.Needs ?? []).Concat(before.Fleet?.AnsweredNeeds ?? []).ToList(),
                   (after.Fleet?.Needs ?? []).Concat(after.Fleet?.AnsweredNeeds ?? []).ToList(), n => n.Id, needs);
            var oldTasks = before.Fleet is null ? [] : Activity.AllTasks(before.Fleet);
            var newTasks = after.Fleet is null ? [] : Activity.AllTasks(after.Fleet);
            Differ(oldTasks, newTasks, t => t.Id, tasks);
            if (!(before.Fleet?.Holds ?? []).SequenceEqual(after.Fleet?.Holds ?? []) ||
                !(before.Fleet?.Outcomes ?? []).SequenceEqual(after.Fleet?.Outcomes ?? []))
                foreach (var t in (before.Fleet?.Holds ?? []).Concat(after.Fleet?.Holds ?? []).Select(h => h.Task)
                             .Concat((before.Fleet?.Outcomes ?? []).Concat(after.Fleet?.Outcomes ?? []).Select(o => o.Task)))
                    tasks.Add(t);
            foreach (var id in tasks)
            {
                if (newTasks.Concat(oldTasks).FirstOrDefault(t => t.Id == id)?.Owner is { } owner) agents.Add(owner);
            }
            foreach (var need in needs)
            {
                var by = (after.Fleet?.Needs ?? []).Concat(after.Fleet?.AnsweredNeeds ?? [])
                    .Concat(before.Fleet?.Needs ?? []).Concat(before.Fleet?.AnsweredNeeds ?? [])
                    .FirstOrDefault(n => n.Id == need)?.By;
                if (by is not null) chats.Add(by);
            }
            foreach (var name in agents) chats.Add(name);
            if (before.Fleet?.Time != after.Fleet?.Time || before.Fleet?.Db != after.Fleet?.Db)
                foreach (var a in after.Fleet?.Agents ?? []) agents.Add(a.Name);     // ages and helpers move
        }
        foreach (var (agent, page) in after.Chats)
            if (!before.Chats.TryGetValue(agent, out var old) || !old.Equals(page)) { chats.Add(agent); agents.Add(agent); }
        foreach (var agent in before.Chats.Keys) if (!after.Chats.ContainsKey(agent)) chats.Add(agent);
        foreach (var agent in after.Seen.Keys.Concat(before.Seen.Keys))
            if (after.Seen.GetValueOrDefault(agent) != before.Seen.GetValueOrDefault(agent)) agents.Add(agent);
        foreach (var (agent, draft) in after.Drafts.Concat(before.Drafts))
            if (after.Drafts.GetValueOrDefault(agent) != before.Drafts.GetValueOrDefault(agent)) chats.Add(agent);
        foreach (var key in after.Staged.Keys.Concat(before.Staged.Keys))
        {
            if (Equals(after.Staged.GetValueOrDefault(key), before.Staged.GetValueOrDefault(key))) continue;
            if (key.StartsWith("agent:", StringComparison.Ordinal)) chats.Add(key[6..]);
            else if (long.TryParse(key.AsSpan(5), out var need)) needs.Add(need);
        }
        foreach (var id in after.AnswerDrafts.Keys.Concat(before.AnswerDrafts.Keys)
                     .Concat(after.AnswersTaken.Keys).Concat(before.AnswersTaken.Keys)
                     .Concat(after.WaitingPresses.Keys).Concat(before.WaitingPresses.Keys))
            if (after.AnswerDrafts.GetValueOrDefault(id) != before.AnswerDrafts.GetValueOrDefault(id) ||
                !Equals(after.AnswersTaken.GetValueOrDefault(id), before.AnswersTaken.GetValueOrDefault(id)) ||
                after.WaitingPresses.GetValueOrDefault(id, -1) != before.WaitingPresses.GetValueOrDefault(id, -1))
                needs.Add(id);
        var pages = new HashSet<long>();
        foreach (var (id, page) in after.TaskPages)
            if (!before.TaskPages.TryGetValue(id, out var old) || !old.Equals(page)) pages.Add(id);
        var pending = !Equals(before.Pending, after.Pending) || !Equals(before.Delivered, after.Delivered) ||
                      before.Sending != after.Sending || before.SendError != after.SendError ||
                      before.StorageError != after.StorageError;
        if (pending)
        {
            foreach (var request in new[] { before.Pending, after.Pending, before.Delivered, after.Delivered })
            {
                if (request is null) continue;
                if (request.NeedId is { } need) needs.Add(need);
                else if (request.Command is { } command) pages.Add(command.Target);
                else chats.Add(request.Recipient ?? "manager");
            }
            foreach (var agent in after.Fleet?.Agents ?? []) chats.Add(agent.Name);    // every composer's Send
        }
        var connection = before.Hub != after.Hub || before.Key != after.Key || !Equals(before.Device, after.Device) ||
                         before.LastRead != after.LastRead || before.ReadHeld != after.ReadHeld ||
                         before.FirstReadWaits != after.FirstReadWaits || before.AuthProblem != after.AuthProblem ||
                         !ReferenceEquals(before.ReadError, after.ReadError) || before.AddressError != after.AddressError ||
                         before.Refreshing != after.Refreshing;
        return new StoreChange
        {
            Before = before,
            After = after,
            Fleet = fleet,
            Agents = agents,
            Chats = chats,
            Needs = needs,
            Tasks = tasks,
            TaskPages = pages,
            Connection = connection,
            Pending = pending,
        };
    }

    internal static void Differ<T, TKey>(IReadOnlyList<T> before, IReadOnlyList<T> after, Func<T, TKey> key,
                                        HashSet<TKey> changed) where TKey : notnull where T : class
    {
        var old = new Dictionary<TKey, T>();
        foreach (var item in before) old.TryAdd(key(item), item);
        var seen = new HashSet<TKey>();
        foreach (var item in after)
        {
            var k = key(item);
            seen.Add(k);
            if (!old.TryGetValue(k, out var was) || !(was.Equals(item) || RecordValues.Equal(was, item))) changed.Add(k);
        }
        foreach (var k in old.Keys) if (!seen.Contains(k)) changed.Add(k);
    }
}

/// <summary>The models of the screens of one state at one moment, which a change compares: the pane, the line, the open
/// chat, Needs you with the page of each open request, the board of each period, the open task, and Settings.</summary>
internal sealed class StoreView
{
    public required PaneModel Pane { get; init; }
    public required ConnectionLine? Line { get; init; }
    public required string? ChatAgent { get; init; }
    public required ChatModel? Chat { get; init; }
    public required NeedsModel Needs { get; init; }
    public required IReadOnlyDictionary<long, RequestStep?> Steps { get; init; }
    public required IReadOnlyList<TaskBoardModel> Boards { get; init; }
    public required long? TaskId { get; init; }
    public required TaskPageModel? Task { get; init; }
    public required SettingsModel Settings { get; init; }
    public required HubSearch Search { get; init; }

    public static StoreView Of(StoreState s, DateTimeOffset now, ScreenContext context)
    {
        var steps = new Dictionary<long, RequestStep?>();
        foreach (var need in s.Fleet?.Needs ?? []) steps[need.Id] = Screens.Needs(s, need.Id, null, now, context).AtHand;
        return new StoreView
        {
            Pane = Screens.Pane(s, Page.Tasks, now, context),
            Line = Screens.Line(s, now),
            ChatAgent = s.OpenChat,
            Chat = s.OpenChat is { } agent ? Screens.Chat(s, agent, now, context) : null,
            Needs = Screens.Needs(s, null, null, now, context),
            Steps = steps,
            Boards = Enum.GetValues<ActivityPeriod>().Select(p => Screens.Board(s, p, null, now, context)).ToList(),
            TaskId = s.OpenTask,
            Task = s.OpenTask is { } task ? Screens.Task(s, task, now, context) : null,
            Settings = Screens.Settings(s, "", now, context),
            Search = s.Search,
        };
    }

    /// <summary>The parts whose models differ from <paramref name="was"/>, and the agents whose pane rows did.</summary>
    public (StoreParts Parts, IReadOnlySet<string> Agents) Changes(StoreView was)
    {
        var parts = StoreParts.None;
        var rows = RowDiff.Of(was.Pane.Agents, Pane.Agents, r => r.Key);
        var agents = rows.Added.Concat(rows.Removed).Concat(rows.Changed).ToImmutableHashSet();
        if (!Equals(was.Pane, Pane)) parts |= StoreParts.Pane;
        if (!Equals(was.Line, Line)) parts |= StoreParts.Line;
        if (was.ChatAgent != ChatAgent || !Equals(was.Chat, Chat)) parts |= StoreParts.Chat;
        if (!Equals(was.Needs, Needs) || was.Steps.Count != Steps.Count ||
            Steps.Any(p => !was.Steps.TryGetValue(p.Key, out var step) || !Equals(step, p.Value)))
            parts |= StoreParts.Needs;
        if (!was.Boards.SequenceEqual(Boards)) parts |= StoreParts.Board;
        if (was.TaskId != TaskId || !Equals(was.Task, Task)) parts |= StoreParts.Task;
        if (!Equals(was.Settings, Settings) || was.Search != Search) parts |= StoreParts.Settings;
        return (parts, agents);
    }
}

/// <summary>The rows of a screen model that came, went, changed or moved between two builds.</summary>
public sealed record RowChanges<TKey>(IReadOnlyList<TKey> Added, IReadOnlyList<TKey> Removed, IReadOnlyList<TKey> Changed,
                                      bool Moved) where TKey : notnull
{
    public bool None => Added.Count == 0 && Removed.Count == 0 && Changed.Count == 0 && !Moved;
}

/// <summary>Compares two builds of a screen's rows by their key and their values.</summary>
public static class RowDiff
{
    public static RowChanges<TKey> Of<TRow, TKey>(IReadOnlyList<TRow> before, IReadOnlyList<TRow> after, Func<TRow, TKey> key)
        where TKey : notnull where TRow : class
    {
        var old = new Dictionary<TKey, TRow>();
        foreach (var row in before) old.TryAdd(key(row), row);
        var added = new List<TKey>();
        var changed = new List<TKey>();
        var keys = new HashSet<TKey>();
        foreach (var row in after)
        {
            var k = key(row);
            keys.Add(k);
            if (!old.TryGetValue(k, out var was)) added.Add(k);
            else if (!was.Equals(row) && !RecordValues.Equal(was, row)) changed.Add(k);
        }
        var removed = old.Keys.Where(k => !keys.Contains(k)).ToList();
        var oldOrder = before.Select(key).Where(keys.Contains).ToList();
        var newOrder = after.Select(key).Where(old.ContainsKey).ToList();
        return new RowChanges<TKey>(added, removed, changed, !oldOrder.SequenceEqual(newOrder));
    }
}
