using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Core;

/// <summary>The store of Founderizer for Windows: what the iPhone's MobileStore does that draws nothing (ios/Sources/
/// MobileStore.swift). It reads GET /ui/mobile while the window is in front (every 10 seconds with a chat, a task or a
/// write open, else every 30, and at once on each wake of GET /ui/wait), the open chat and task first, and the other
/// chats that changed in the background; it sends each write through the outbox and keeps its receipt; and it keeps the
/// last reading, the newest items of each chat, the seen marks and the drafts between launches. It gives the screens an
/// immutable <see cref="StoreState"/> and, after each change, a <see cref="StoreChange"/> that says which rows changed.
///
/// <see cref="Changed"/> is raised in order, never twice for one state, on the thread that changed the store (a pool
/// thread for a read), and only when a model of a screen changed: a screen moves to its own
/// thread. Every method may be called from any thread.</summary>
public sealed class OwnerStore : IAsyncDisposable
{
    private readonly StoreSettings settings;
    private readonly HubClient client;
    private readonly IStoreClock clock;
    private readonly Outbox outbox;
    /// <summary>The writes that wait for their turn, by the order of their presses.</summary>
    private readonly SortedSet<long> waitingWrites = new();
    private long writeTickets;
    private CancellationTokenSource? ageWatch;
    private readonly object gate = new();
    private readonly object raising = new();
    private StoreState state = new();
    private StoreState raised = new();
    private StoreView raisedView = null!;
    private readonly RunOnceMore passes = new();
    private CancellationTokenSource? frontLoop;
    private CancellationTokenSource? watcher;
    private (Uri Hub, string Database, int Id)? watched;
    private int watches;
    private readonly WakeCap cap = new();
    private CancellationTokenSource? heldWake;
    private Task? chatsReading;
    private CancellationTokenSource? chatsCancel;
    private readonly Dictionary<string, double> chatsReadAt = new();
    private readonly Dictionary<string, double> chatCursor = new();
    private readonly Dictionary<long, long> taskCursor = new();
    private readonly Dictionary<long, CancellationTokenSource> pressWaits = new();
    private string? key;
    private string? etag;
    private string? keptDatabase;
    private double? lastReadUptime;
    private double lastRequestTook;
    private double slowestRequest;
    private bool disposed;

    public OwnerStore(StoreSettings settings) : this(settings, new HubClient(settings.Client)) { }

    internal OwnerStore(StoreSettings settings, HubClient client)
    {
        this.settings = settings;
        this.client = client;
        clock = settings.Clock;
        Directory.CreateDirectory(settings.Folder);
        outbox = new Outbox(Path.Combine(settings.Folder, "outbox.json"));
        Load();
    }

    /// <summary>The newest state.</summary>
    public StoreState State { get { lock (gate) return state; } }

    /// <summary>Raised after each change, with the rows that changed since the last one raised.</summary>
    public event EventHandler<StoreChange>? Changed;

    /// <summary>Raised when a reading brings notifications that are due (the Mac's rule, <see cref="Notifications.Due"/>):
    /// a new request of the manager, or a new episode of its warning, once each, also while the window is behind. On the
    /// thread of the read: move it to the UI thread.</summary>
    public event EventHandler<IReadOnlyList<Notice>>? Notified;

    public string ClientLabel => settings.ClientLabel;

    // ---------------------------------------------------------------- the window

    /// <summary>The window came to the front, or left it. In front, the store opens the key, reads at once, and then on
    /// its clock and on each wake; behind, it reads nothing, stops the wait and closes the key.</summary>
    public void SetFront(bool front)
    {
        if (disposed) return;
        if (front == State.Front) return;
        if (front)
        {
            var s = State;
            var holds = s.Fleet is not null && s.ReadError is null;
            Update(x => x with { Front = true, FirstReadWaits = holds || x.FirstReadWaits });
            if (holds) _ = EndFirstWaitAsync();
            behind = false;
            MarkRepliesSeen();
            var cancel = frontLoop = new CancellationTokenSource();
            _ = FrontLoopAsync(cancel.Token);
        }
        else
        {
            // Behind, the window is still open: the store keeps its key and its wait on the hub, and a wake reads the
            // fleet alone, so that a new request notifies (decision D4). It reads no chat, no task and nothing on its
            // clock until the window comes back.
            behind = true;
            frontLoop?.Cancel();
            frontLoop = null;
            chatsCancel?.Cancel();
            Update(x => x with { Front = false });
        }
    }

    private async Task EndFirstWaitAsync()
    {
        try { await clock.Delay(TimeSpan.FromSeconds(1), CancellationToken.None); } catch (OperationCanceledException) { }
        Update(x => x with { FirstReadWaits = false });
    }

    private async Task FrontLoopAsync(CancellationToken cancel)
    {
        try
        {
            if (!State.HasNoHub) Unlock();
            await RefreshAsync();
            while (!cancel.IsCancellationRequested)
            {
                // A PC with no hub address looks for its hub in front, at once and then every five seconds (the Mac's
                // first page, looksEvery), until it has one: found, or typed in Settings.
                if (State.HasNoHub && settings.Tailscale is not null)
                {
                    if (await FindHubAsync(cancel) is null) await clock.Delay(SearchEvery, cancel);
                    continue;
                }
                var wait = UntilRead();
                await clock.Delay(TimeSpan.FromSeconds(Math.Max(wait, 0.1)), cancel);
                if (UntilRead() == 0) await RefreshAsync();
            }
        }
        catch (OperationCanceledException) { }
    }

    /// <summary>How often a PC with no hub looks for one on its Tailscale while it is in front.</summary>
    public static readonly TimeSpan SearchEvery = TimeSpan.FromSeconds(5);

    /// <summary>Looks for the hub on this PC's Tailscale (the Mac's FleetOnTailscale.findHub), while the PC has no hub
    /// address: each device of the network is asked for GET /health, two seconds each, and the first that answers
    /// becomes the hub, as if the owner had typed its address. <see cref="StoreState.Search"/> says how it stands. Gives
    /// the hub it found, or null. An address that the owner types meanwhile wins.</summary>
    public async Task<Uri?> FindHubAsync(CancellationToken cancel = default)
    {
        if (settings.Tailscale is not { } tailscale || !State.HasNoHub || disposed) return null;
        // Looking only at the first search: a search again keeps the last answer, so five seconds raise no change.
        Update(x => x.Search == HubSearch.None ? x with { Search = HubSearch.Looking } : x);
        string? status;
        try
        {
            status = await tailscale.ReadAsync(cancel);
        }
        catch (Exception e) when (e is not OutOfMemoryException and not OperationCanceledException)
        {
            status = null;
        }
        if (status is null || !Runs(status))
        {
            Update(x => x.HasNoHub ? x with { Search = HubSearch.NoNetwork } : x);
            return null;
        }
        var answers = settings.AnswersHealth ?? ((hub, token) => client.AnswersHealthAsync(hub, token));
        var found = await Tailnet.FindAsync(status, answers, cancel);
        if (!State.HasNoHub) return null;
        if (found is null)
        {
            Update(x => x.HasNoHub ? x with { Search = HubSearch.NoHub } : x);
            return null;
        }
        Unlock();
        await ConnectAsync(found.ToString(), HubSearch.Found);
        return found;
    }

    /// <summary>The status of a Tailscale that runs: a status with no state, or "Running" (a stopped Tailscale lists its
    /// devices too, and reaches none of them).</summary>
    private static bool Runs(string status)
    {
        try
        {
            using var document = JsonDocument.Parse(status);
            return document.RootElement.ValueKind == JsonValueKind.Object &&
                   (!document.RootElement.TryGetProperty("BackendState", out var backend) ||
                    backend.ValueKind != JsonValueKind.String || backend.GetString() == "Running");
        }
        catch (JsonException)
        {
            return false;
        }
    }

    /// <summary>The seconds until the clock's next read: its interval counts from the last read, whoever ran it.</summary>
    private double UntilRead()
    {
        var s = State;
        var every = s.OpenChat is not null || s.OpenTask is not null || s.Pending is not null ? 10 : 30;
        return LiveChanges.UntilRead(lastReadUptime, clock.Uptime, every);
    }

    /// <summary>Opens the key: in hand, none, or it did not open (the key store's words).</summary>
    public void Unlock()
    {
        if (key is not null) return;
        try
        {
            key = settings.Keys.Read();
            Update(x => x with { Key = key is null ? KeyState.None : KeyState.InHand, KeyDetail = null });
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            key = null;
            Update(x => x with { Key = KeyState.Failed, KeyDetail = e.Message });
        }
    }

    /// <summary>The chat that a screen shows now, or null: the store reads it first on each pass, and its replies are
    /// seen.</summary>
    public void OpenChat(string? agent)
    {
        Update(x => x with { OpenChat = agent });
        MarkRepliesSeen();
    }

    /// <summary>The task whose page a screen shows now, or null.</summary>
    public void OpenTask(long? task) => Update(x => x with { OpenTask = task });

    // ---------------------------------------------------------------- the read

    /// <summary>A read now, after any read that runs (a call during a read runs once more after it, never dropped).</summary>
    public Task RefreshAsync() => passes.Run(ReadOnceAsync);

    private async Task ReadOnceAsync()
    {
        try
        {
            var s = State;
            if (s.HasNoHub || disposed) return;
            Update(x => x with { Refreshing = true });
            if (s.KeyIsHeldBack)
            {
                Update(x => x with { Refreshing = false, Clock = clock.Now });
                return;
            }
            var requested = s.Hub!;
            slowestRequest = 0;
            try
            {
                var early = s.Fleet?.Db;
                if (early is not null)
                {
                    if (!behind && s.OpenChat is { } chat) await Holding(requested, () => ReadChatAsync(chat, requested, early));
                    if (!behind && s.OpenTask is { } task) await Holding(requested, () => ReadTaskAsync(task, requested, early));
                }
                await Holding(requested, () => ReadSnapshotAsync(requested));
                if (State.Hub != requested || State.Fleet?.Db is not { } database) return;
                Follow();
                if (early != database && !behind)
                {
                    if (State.OpenChat is { } chat) await Holding(requested, () => ReadChatAsync(chat, requested, database));
                    if (State.OpenTask is { } task) await Holding(requested, () => ReadTaskAsync(task, requested, database));
                }
                if (!behind) ReadChangedChats(requested, database);
                await Holding(requested, () => ConfirmPendingAsync(requested, database));
                lastRequestTook = slowestRequest;
                Update(x => x with
                {
                    LastRead = clock.Now, ReadHeld = false, ReadError = null, ReadWasRefused = false, AuthProblem = null,
                });
            }
            catch (HubException e)
            {
                if (State.Hub != requested) return;
                if (e is { Kind: HubErrorKind.Refusal, Status: 409 })
                {
                    ForgetGeneration(keepSnapshot: false);
                    _ = RefreshAsync();
                    return;
                }
                Update(x => x with { ReadError = e, ReadWasRefused = e.IsDefinitive, AuthProblem = e.Auth });
            }
            catch (Exception e) when (e is IOException or JsonException or InvalidOperationException)
            {
                if (State.Hub != requested) return;
                Update(x => x with { ReadError = HubException.InvalidResponse("the store", e.Message, e), ReadWasRefused = false });
            }
            finally
            {
                Update(x => x with { Refreshing = false, Clock = clock.Now });
            }
        }
        finally
        {
            lastReadUptime = clock.Uptime;
            Update(x => x with { FirstReadWaits = false });
            WatchTheAge();
        }
    }

    /// <summary>The reading turns old by time alone, with no read: then a write cannot go and the connection line may
    /// show, so the store raises that change at that moment (the Mac's views follow its clock). Without it, a window
    /// that draws on changes kept a Pause that the store no longer took.</summary>
    private void WatchTheAge()
    {
        Interlocked.Exchange(ref ageWatch, null)?.Cancel();
        if (disposed || State.LastRead is not { } read) return;
        var due = read + StoreState.CurrentFor - clock.Now;
        if (due <= TimeSpan.Zero) return;
        var cancel = new CancellationTokenSource();
        ageWatch = cancel;
        _ = Task.Run(async () =>
        {
            try
            {
                await clock.Delay(due + TimeSpan.FromMilliseconds(5), cancel.Token);
                Raise(byClock: true);
            }
            catch (OperationCanceledException) { }
        });
    }

    /// <summary>One request of a read, with its hold: when it takes longer than twice the slowest request of the last good
    /// read (at least 1 second), the reading counts as old until a read answers.</summary>
    private async Task Holding(Uri requested, Func<Task> request)
    {
        var began = clock.Uptime;
        var hold = new CancellationTokenSource();
        var token = hold.Token;
        var limit = Math.Max(1, lastRequestTook * 2);
        _ = Task.Run(async () =>
        {
            try
            {
                await clock.Delay(TimeSpan.FromSeconds(limit), token);
                if (State.Hub == requested) Update(x => x with { ReadHeld = true });
            }
            catch (OperationCanceledException) { }
        });
        try
        {
            await request();
            slowestRequest = Math.Max(slowestRequest, clock.Uptime - began);
        }
        finally
        {
            hold.Cancel();
        }
    }

    private async Task ReadSnapshotAsync(Uri requested)
    {
        var s = State;
        var database = s.LastRead is null ? null : s.Fleet?.Db;
        var reading = await client.SnapshotAsync(requested, key, database, etag);
        if (reading is null)
        {
            Update(x => x with { LastRead = clock.Now, ReadError = null, ReadWasRefused = false, AuthProblem = null });
            return;
        }
        if (State.Hub != requested) return;
        if ((State.Fleet?.Db ?? keptDatabase) != reading.Snapshot.Db) ForgetGeneration(keepSnapshot: true);
        keptDatabase = reading.Snapshot.Db;
        etag = reading.ETag;
        var now = clock.Now;
        Update(x => x with { Fleet = reading.Snapshot, SnapshotAt = now });
        Notify(requested, reading.Snapshot);
        Keep("snapshot.json", JsonSerializer.SerializeToUtf8Bytes(
            new KeptSnapshot(requested.ToString(), reading.ETag, now.ToUnixTimeMilliseconds() / 1000.0,
                             Convert.ToBase64String(reading.Body)), CoreJson.Default.KeptSnapshot));
        MarkRepliesSeen();
    }

    /// <summary>A new generation (or a new hub): the chats, the task pages, the wait and the delivered write go; the
    /// waiting write stays, because it names its own hub and generation.</summary>
    private void ForgetGeneration(bool keepSnapshot)
    {
        StopWatching();
        etag = null;
        chatsCancel?.Cancel();
        chatsReadAt.Clear();
        chatCursor.Clear();
        taskCursor.Clear();
        keptDatabase = null;
        Remove("chats.json");
        Update(x => x with
        {
            Fleet = keepSnapshot ? x.Fleet : null,
            SnapshotAt = keepSnapshot ? x.SnapshotAt : null,
            Chats = ImmutableDictionary<string, ChatPageState>.Empty,
            TaskPages = ImmutableDictionary<long, TaskPageState>.Empty,
            Delivered = null,
            AnswersTaken = ImmutableDictionary<long, PendingRequest>.Empty,
        });
    }

    // ---------------------------------------------------------------- the pages

    private async Task ReadChatAsync(string agent, Uri requested, string database)
    {
        chatCursor.TryGetValue(agent, out var cursor);
        double? since = chatCursor.ContainsKey(agent) ? cursor : null;
        var page = await client.ChatAsync(requested, key, database, agent, since);
        if (State.Hub != requested || State.Fleet?.Db != database) return;
        chatCursor[agent] = Math.Max(page.Cursor, chatCursor.GetValueOrDefault(agent));
        var changed = false;
        Update(x =>
        {
            var held = x.Items(agent).ToList();
            if (since is null && page.Items.Count > 0 && held.Count > 0 && page.Items[0].Ts > held[^1].Ts) held = [];
            var latest = new Dictionary<string, MobileChatItem>();
            foreach (var item in page.Items) latest[item.Id] = item;
            var items = held.Select(i => latest.TryGetValue(i.Id, out var newer) ? newer : i).ToList();
            var known = items.Select(i => i.Id).ToHashSet();
            items.AddRange(page.Items.Where(i => !known.Contains(i.Id)));
            var read = items.OrderBy(i => i.Ts).ThenBy(i => i.Id, StringComparer.Ordinal).ToList();
            var delivered = x.Delivered;
            if (delivered is not null && (delivered.Recipient ?? "manager") == agent && Holds(delivered, read)) delivered = null;
            var list = ValueList.Of(read);
            changed = !x.Chats.TryGetValue(agent, out var old) || !old.Items.Equals(list) && !SameItems(old.Items, list);
            return changed ? x with { Chats = x.Chats.SetItem(agent, new ChatPageState { Agent = agent, Items = list }), Delivered = delivered }
                           : x with { Delivered = delivered };
        });
        if (changed) KeepChats();
    }

    private static bool SameItems(IReadOnlyList<MobileChatItem> a, IReadOnlyList<MobileChatItem> b) =>
        a.Count == b.Count && a.Zip(b).All(p => RecordValues.Equal(p.First, p.Second));

    private async Task ReadTaskAsync(long id, Uri requested, string database)
    {
        var page = await client.TaskAsync(requested, key, database, id, taskCursor.GetValueOrDefault(id));
        if (State.Hub != requested || State.Fleet?.Db != database) return;
        taskCursor[id] = Math.Max(page.Cursor, taskCursor.GetValueOrDefault(id));
        Update(x =>
        {
            var notes = x.TaskPages.TryGetValue(id, out var old) ? old.Notes.ToList() : [];
            var known = notes.Select(n => n.Id).ToHashSet();
            notes.AddRange(page.Notes.Where(n => !known.Contains(n.Id)));
            return x with
            {
                TaskPages = x.TaskPages.SetItem(id, new TaskPageState
                {
                    Task = page.Task,
                    Notes = ValueList.Of(notes.OrderBy(n => n.Id)),
                    Holds = ValueList.Of(page.Holds),
                    Outcomes = ValueList.Of(page.Outcomes),
                }),
            };
        });
    }

    /// <summary>The other chats whose newest line is newer than what this device holds, one after another in the
    /// background, so that a chat opens already drawn. A failure is quiet: the next pass tries again.</summary>
    private void ReadChangedChats(Uri requested, string database)
    {
        if (chatsReading is { IsCompleted: false }) return;
        var s = State;
        var changed = (s.Fleet?.Agents ?? []).Where(a => a.Last is not null && a.Name != s.OpenChat &&
                                                        chatsReadAt.GetValueOrDefault(a.Name, double.NaN) != a.Last!.Ts &&
                                                        a.Last!.Ts > (s.Items(a.Name).LastOrDefault()?.Ts ?? 0))
            .Select(a => (a.Name, a.Last!.Ts)).ToList();
        if (changed.Count == 0) return;
        var cancel = chatsCancel = new CancellationTokenSource();
        chatsReading = Task.Run(async () =>
        {
            foreach (var (name, ts) in changed)
            {
                if (cancel.IsCancellationRequested || State.Hub != requested || State.Fleet?.Db != database) return;
                try { await ReadChatAsync(name, requested, database); }
                catch (Exception e) when (e is HubException or IOException) { return; }
                chatsReadAt[name] = ts;
            }
        });
    }

    // ---------------------------------------------------------------- the wait

    /// <summary>Starts, keeps or stops the wait on GET /ui/wait, from the token of the newest body.</summary>
    private void Follow()
    {
        var s = State;
        var token = s.Offers(LiveChanges.Feature) ? LiveToken.Parse(s.Fleet?.Token) : null;
        if (watched is { } w && w.Hub == s.Hub && w.Database == s.Fleet?.Db && token is not null) return;
        if (watched is null && token is null) return;
        StopWatching();
        if (token is null || s.Fleet?.Db is not { } database || s.Hub is not { } hub) return;
        watches++;
        var now = (hub, database, watches);
        watched = now;
        var cancel = watcher = new CancellationTokenSource();
        _ = WatchAsync(now, token, cancel.Token);
    }

    private void StopWatching()
    {
        watcher?.Cancel();
        watcher = null;
        watched = null;
        heldWake?.Cancel();
        heldWake = null;
        cap.Reset();
    }

    private async Task WatchAsync((Uri Hub, string Database, int Id) watching, LiveToken from, CancellationToken cancel)
    {
        var watch = new LiveWatch(from);
        while (!cancel.IsCancellationRequested && watched == watching)
        {
            try
            {
                var started = clock.Uptime;
                var answer = await client.WaitAsync(watching.Hub, key, watching.Database, watch.Since, LiveChanges.Wait, cancel);
                if (cancel.IsCancellationRequested || watched != watching) return;
                if (answer.IsGenerationChanged)
                {
                    watched = null;
                    watcher = null;
                    Woke();
                    return;
                }
                var step = watch.Answered(answer.Token!, clock.Uptime - started, Random.Shared.NextDouble());
                if (step.Kind == WatchStep.Kinds.Wake) Woke();
                else if (step.Kind == WatchStep.Kinds.Pause) await clock.Delay(TimeSpan.FromSeconds(step.Pause), cancel);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception e) when (e is HubException or IOException)
            {
                if (cancel.IsCancellationRequested || watched != watching) return;
                try { await clock.Delay(TimeSpan.FromSeconds(watch.Failed(Random.Shared.NextDouble())), cancel); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    /// <summary>A wake reads at once, at most once in two seconds; the wakes inside them fold into one at their end.</summary>
    private void Woke()
    {
        var answer = cap.Wake(clock.Uptime);
        if (answer.Kind == WakeAnswer.Kinds.Now) { _ = RefreshAsync(); return; }
        if (answer.Kind == WakeAnswer.Kinds.Folded) return;
        var cancel = heldWake = new CancellationTokenSource();
        _ = Task.Run(async () =>
        {
            try
            {
                await clock.Delay(TimeSpan.FromSeconds(Math.Max(0, answer.At - clock.Uptime)), cancel.Token);
                heldWake = null;
                cap.Fired(clock.Uptime);
                await RefreshAsync();
            }
            catch (OperationCanceledException) { }
        });
    }

    // ---------------------------------------------------------------- the notifications

    private NotificationLedger ledger = new();
    /// <summary>The window went behind and did not come back: a wake reads the fleet alone, and no reply is seen.</summary>
    private volatile bool behind;

    /// <summary>The notifications that a new body brings, by the ledger that stays between starts.</summary>
    private void Notify(Uri hub, MobileSnapshot fleet)
    {
        IReadOnlyList<Notice> due;
        byte[] kept;
        lock (ledger)
        {
            due = Notifications.Due(ledger, hub, fleet, AgentBook.Of(fleet));
            kept = JsonSerializer.SerializeToUtf8Bytes(new KeptLedger(ledger.Seen, ledger.Warnings), CoreJson.Default.KeptLedger);
        }
        Keep("notifications.json", kept);
        if (due.Count == 0) return;
        try { Notified?.Invoke(this, due); }
        catch (Exception) when (!disposed) { }
    }

    // ---------------------------------------------------------------- the seen marks

    /// <summary>The open chat's replies are seen; a new hub or generation takes the replies that it has as seen.</summary>
    private void MarkRepliesSeen()
    {
        StoreState? after = null;
        Update(x =>
        {
            if (x.Fleet is not { } fleet || x.Hub is null) return x;
            var context = $"{x.Hub}\n{fleet.Db}";
            var seen = x.SeenContext == context ? x.Seen : ImmutableDictionary<string, double>.Empty;
            if (x.SeenContext != context)
                foreach (var a in fleet.Agents) if (a.Last is { Side: "agent" } last) seen = seen.SetItem(a.Name, last.Ts);
            if (!behind && x.OpenChat is { } open && x.Agent(open)?.Last is { Side: "agent" } l) seen = seen.SetItem(open, l.Ts);
            if (x.SeenContext == context && seen.Count == x.Seen.Count && seen.All(p => x.Seen.GetValueOrDefault(p.Key, -1) == p.Value))
                return x;
            return after = x with { Seen = seen, SeenContext = context };
        });
        if (after is not null)
            Keep("seen.json", JsonSerializer.SerializeToUtf8Bytes(
                new KeptSeen(after.SeenContext, new Dictionary<string, double>(after.Seen)), CoreJson.Default.KeptSeen));
    }

    // ---------------------------------------------------------------- drafts and files

    public void SetDraft(string agent, string text)
    {
        Update(x => x with { Drafts = text.Length == 0 ? x.Drafts.Remove(agent) : x.Drafts.SetItem(agent, text) });
        KeepDrafts();
    }

    public void SetAnswerDraft(long need, string text)
    {
        Update(x => x with { AnswerDrafts = text.Length == 0 ? x.AnswerDrafts.Remove(need) : x.AnswerDrafts.SetItem(need, text) });
        KeepDrafts();
    }

    /// <summary>Sends one file up for a composer ("agent:&lt;name&gt;" or "need:&lt;id&gt;"), before the message that
    /// carries it. Null when it went; else the owner's words.</summary>
    public async Task<string?> AddFileAsync(string composer, string name, byte[] bytes, string? mime = null)
    {
        var s = State;
        if (s.StorageError is not null) return s.StorageError;
        mime ??= MessageAttachment.MimeFor(name);
        string? refused = null;
        if (mime is null || !MessageAttachment.Types.ContainsKey(mime)) refused = new AttachmentException(AttachmentException.Problem.Type).Message;
        else if (bytes.Length == 0 || bytes.Length > MessageAttachment.SizeLimit) refused = new AttachmentException(AttachmentException.Problem.TooLarge).Message;
        else if ((s.Staged.GetValueOrDefault(composer)?.Count ?? 0) >= MessageAttachment.PerMessage)
            refused = $"A message carries at most {MessageAttachment.PerMessage} files.";
        if (refused is not null)
        {
            Update(x => x with { FileError = refused, FileErrorDetail = null });
            return refused;
        }
        // The bytes wait in the store's folder before anything goes, so a file that he picked stays between starts.
        var file = new StagedFile
        {
            RequestId = Guid.NewGuid(), Name = MessageAttachment.SafeName(name, mime!), Mime = mime!, Size = bytes.Length,
        };
        try
        {
            WriteStaged(file, bytes);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            const string words = "Cannot keep this file on this PC. Nothing was sent.";
            Update(x => x with { FileError = words, FileErrorDetail = e.Message });
            return words;
        }
        Update(x => x with
        {
            FileError = null, FileErrorDetail = null,
            Staged = x.Staged.SetItem(composer, ValueList.Of((x.Staged.GetValueOrDefault(composer) ?? ValueList<StagedFile>.Empty).Append(file))),
        });
        KeepStaged();
        return await UploadAsync(composer, file.RequestId);
    }

    /// <summary>Sends one picked file up with its own number (the iPhone's upload): a file that is on the hub never goes
    /// again, and one that goes now does not go twice. Null when it went, or when the PC has no reading to send it
    /// with (it waits); else the words of what failed, which the file also carries.</summary>
    public async Task<string?> UploadAsync(string composer, Guid file)
    {
        var s = State;
        if (s.Staged.GetValueOrDefault(composer)?.FirstOrDefault(f => f.RequestId == file) is not { IsOnHub: false } staged)
            return null;
        if (s.Hub is not { } hub || s.Fleet?.Db is not { } database) return null;
        lock (gate)
        {
            if (state.Uploading.Contains(file)) return null;
            state = state with { Uploading = state.Uploading.Add(file), Version = state.Version + 1 };
        }
        Raise();
        string? failure = null;
        string? auth = null;
        MessageAttachment? sent = null;
        try
        {
            byte[]? bytes = null;
            try
            {
                bytes = File.ReadAllBytes(StagedPath(file));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                failure = "The bytes of this file are gone from this PC. Pick it again.";
            }
            if (bytes is not null)
            {
                try
                {
                    sent = await client.UploadAsync(hub, key, database, bytes, staged.Name, staged.Mime, file, settings.ClientLabel);
                }
                catch (AttachmentException e) { failure = e.Message; }
                catch (HubException e) { failure = e.NotSentWords; auth = e.Auth; }
            }
        }
        finally
        {
            // One change: the upload ends and the file says how it went.
            Update(x => Change(x with { Uploading = x.Uploading.Remove(file), AuthProblem = auth ?? x.AuthProblem }, composer, file,
                               f => f with { File = sent ?? f.File, Failure = sent is null ? failure ?? f.Failure : null }));
            KeepStaged();
        }
        return failure;
    }

    /// <summary>Takes a picked file out of a composer, with its bytes. A file that goes up now stays until its upload has
    /// answered; one that is on the hub stays there until the hub drops it, but no message of this PC names it.</summary>
    public void RemoveFile(string composer, Guid file)
    {
        if (State.Uploading.Contains(file)) return;
        try { File.Delete(StagedPath(file)); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        Update(x => x.Staged.TryGetValue(composer, out var files)
            ? x with { Staged = Without(x.Staged, composer, files.Where(f => f.RequestId != file)) }
            : x);
        KeepStaged();
    }

    /// <summary>The bytes of a file that a message carries, checked against its size and SHA-256; a file that this
    /// device sent up and still holds comes from its own copy.</summary>
    public async Task<byte[]> FileAsync(MessageAttachment file)
    {
        Update(x => x with { FilesReading = x.FilesReading.Add(file.Id) });
        try
        {
            var bytes = await ReadFileAsync(file);
            Update(x => x with { FilesReading = x.FilesReading.Remove(file.Id), FilesUnloaded = x.FilesUnloaded.Remove(file.Id) });
            return bytes;
        }
        catch
        {
            // "Not loaded" until a read of it works (MessageFilesView: unloadedFiles).
            Update(x => x with { FilesReading = x.FilesReading.Remove(file.Id), FilesUnloaded = x.FilesUnloaded.Add(file.Id) });
            throw;
        }
    }

    private async Task<byte[]> ReadFileAsync(MessageAttachment file)
    {
        var s = State;
        foreach (var staged in s.Staged.Values.SelectMany(v => v))
        {
            if (staged.Id != file.Id) continue;
            try
            {
                var own = File.ReadAllBytes(StagedPath(staged.RequestId));
                if (file.Matches(own)) return own;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        if (s.Hub is not { } hub || s.Fleet?.Db is not { } database) throw HubException.NoAnswer();
        return await client.AttachmentAsync(hub, key, database, file);
    }

    private static StoreState Change(StoreState s, string composer, Guid file, Func<StagedFile, StagedFile> edit) =>
        s.Staged.TryGetValue(composer, out var files) && files.Any(f => f.RequestId == file)
            ? s with { Staged = s.Staged.SetItem(composer, ValueList.Of(files.Select(f => f.RequestId == file ? edit(f) : f))) }
            : s;

    private static ImmutableDictionary<string, ValueList<StagedFile>> Without(
        ImmutableDictionary<string, ValueList<StagedFile>> staged, string composer, IEnumerable<StagedFile> left)
    {
        var list = ValueList.Of(left);
        return list.Count == 0 ? staged.Remove(composer) : staged.SetItem(composer, list);
    }

    private string StagedPath(Guid file) =>
        Path.Combine(settings.Folder, "staged", file.ToString("D", CultureInfo.InvariantCulture));

    private void WriteStaged(StagedFile file, byte[] bytes)
    {
        Directory.CreateDirectory(Path.Combine(settings.Folder, "staged"));
        var path = StagedPath(file.RequestId);
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using var stream = new FileStream(path, options);
        stream.Write(bytes);
    }

    private void KeepStaged()
    {
        var s = State;
        Keep("staged.json", JsonSerializer.SerializeToUtf8Bytes(
            new KeptStaged(s.Staged.ToDictionary(p => p.Key, p => p.Value.Select(f => new KeptFile(f.RequestId, f.Name, f.Mime, f.Size, f.File, f.Failure)).ToList())),
            CoreJson.Default.KeptStaged));
    }

    // ---------------------------------------------------------------- the writes

    // Every write below gives null when it went (or when it is no write that a screen offers now), else the owner's
    // words of why nothing went. A write that comes while another write is on its way, or while the reading waits for
    // a read that comes, waits and goes then, in the order the presses came (StoreState.HoldsWrites).

    /// <summary>Sends the agent's draft (or <paramref name="text"/>) and the files of its composer.</summary>
    public Task<string?> SendMessageAsync(string agent, string? text = null) =>
        WriteAsync(text ?? State.Drafts.GetValueOrDefault(agent, ""), recipient: agent, files: State.ReadyFiles("agent:" + agent));

    /// <summary>Sends the typed answer of an open request (its draft, or <paramref name="text"/>) with its files.</summary>
    public Task<string?> AnswerAsync(long need, string? text = null)
    {
        var item = State.Fleet?.Needs.FirstOrDefault(n => n.Id == need);
        if (item is null) return NoWrite;
        return WriteAsync(text ?? State.AnswerDrafts.GetValueOrDefault(need, ""), needId: need, recipient: item.By,
                          files: State.ReadyFiles("need:" + need));
    }

    /// <summary>A press on one of a request's options. It is never refused: while the store cannot write, the newest
    /// press of the request waits, and goes when it can, unless the request, the hub or the generation changes.</summary>
    public void Press(long need, int choice)
    {
        if (State.CanWrite(clock.Now))
        {
            Update(x => x with { WaitingPresses = x.WaitingPresses.Remove(need) });
            _ = SendChoiceAsync(need, choice);
            return;
        }
        Update(x => x with { WaitingPresses = x.WaitingPresses.SetItem(need, choice) });
        lock (pressWaits) if (pressWaits.ContainsKey(need)) return;
        var cancel = new CancellationTokenSource();
        lock (pressWaits) pressWaits[need] = cancel;
        var (hub, database) = (State.Hub, State.Fleet?.Db);
        _ = Task.Run(async () =>
        {
            try
            {
                while (!cancel.IsCancellationRequested)
                {
                    var s = State;
                    if (s.Hub != hub || s.Fleet?.Db != database || s.StorageError is not null ||
                        s.Fleet?.Needs.Any(n => n.Id == need && n.IsOpen) != true ||
                        !s.WaitingPresses.TryGetValue(need, out var waiting))
                        break;
                    if (s.CanWrite(clock.Now))
                    {
                        Update(x => x with { WaitingPresses = x.WaitingPresses.Remove(need) });
                        lock (pressWaits) pressWaits.Remove(need);
                        await SendChoiceAsync(need, waiting);
                        return;
                    }
                    await clock.Delay(TimeSpan.FromMilliseconds(250), cancel.Token);
                }
            }
            catch (OperationCanceledException) { }
            Update(x => x with { WaitingPresses = x.WaitingPresses.Remove(need) });
            lock (pressWaits) pressWaits.Remove(need);
        });
    }

    private Task<string?> SendChoiceAsync(long need, int choice)
    {
        var item = State.Fleet?.Needs.FirstOrDefault(n => n.Id == need);
        if (item is null || choice < 0 || choice >= item.Choices.Count) return NoWrite;
        return WriteAsync(item.Choices[choice], needId: need, recipient: item.By, choice: choice);
    }

    /// <summary>Sends the ticked options of a request whose options combine.</summary>
    public Task<string?> TickAsync(long need, IReadOnlyCollection<int> choices)
    {
        var item = State.Fleet?.Needs.FirstOrDefault(n => n.Id == need);
        if (item is null || !item.Combines || choices.Count == 0 || choices.Any(c => c < 0 || c >= item.Choices.Count))
            return NoWrite;
        // The Mac's words of ticked options (FleetStore.answer(choices:)): their own words in order, joined by "; ".
        var words = string.Join("; ", choices.Order().Select(c => item.Choices[c]));
        return WriteAsync(words, needId: need, recipient: item.By, choices: choices.Select(c => (long)c).ToList());
    }

    /// <summary>Pause, stop or resume a task (`task_controls`).</summary>
    public Task<string?> ControlAsync(long task, TaskControl action) =>
        WriteAsync("", command: OwnerCommand.Control(task, action), feature: "task_controls");

    /// <summary>Guidance for a task's current attempt (`task_steering`).</summary>
    public Task<string?> GuideAsync(long task, string text)
    {
        var s = State;
        var attempt = s.TaskPages.TryGetValue(task, out var page) ? page.Task.Attempt
            : s.Fleet?.Tasks.FirstOrDefault(t => t.Id == task)?.Attempt ?? 0;
        return attempt > 0 ? WriteAsync(text, command: OwnerCommand.Steer(task, attempt), feature: "task_steering") : NoWrite;
    }

    private static readonly Task<string?> NoWrite = Task.FromResult<string?>(null);

    /// <summary>Sends the waiting write again, with the same number: the hub answers the first event again.</summary>
    public Task RetryAsync()
    {
        var s = State;
        return s.CanRetry(clock.Now) && s.Pending is { } pending ? TransmitAsync(pending) : Task.CompletedTask;
    }

    /// <summary>Lets a refused write go, and gives its words back to the draft when the draft is empty.</summary>
    public void DiscardRefused()
    {
        var s = State;
        if (s.Sending || s.Pending is not { Refusal: not null } pending) return;
        try
        {
            outbox.Clear(pending.RequestId);
        }
        catch (Exception e) when (e is IOException or OutboxException or UnauthorizedAccessException)
        {
            Update(x => x with { StorageError = "Cannot clear the refused request. Sending is blocked.", StorageErrorDetail = e.Message });
            return;
        }
        Update(x => x with { Pending = null, SendError = null });
        if (pending.NeedId is null && pending.Command is null && pending.Text.Length > 0)
        {
            var name = pending.Recipient ?? "manager";
            if (State.Drafts.GetValueOrDefault(name, "").Length == 0) SetDraft(name, pending.Text);
        }
    }

    private async Task<string?> WriteAsync(string value, long? needId = null, string? recipient = null, int? choice = null,
                                           IReadOnlyList<long>? choices = null, IReadOnlyList<long>? files = null,
                                           OwnerCommand? command = null, string? feature = null)
    {
        var ticket = Interlocked.Increment(ref writeTickets);
        lock (waitingWrites) waitingWrites.Add(ticket);
        try
        {
            (Uri Hub, string Database)? first = null;
            var askedRead = false;
            while (!disposed)
            {
                var s = State;
                var now = clock.Now;
                if (s.Hub is { } h && s.Fleet is { } f)
                {
                    first ??= (h, f.Db);
                    if (first != (h, f.Db)) return StoreState.ConnectionChanged;
                }
                var hold = s.HoldsWrites(now);
                if (hold is { Waits: false } refused) return refused.Words;
                if (hold is null)
                {
                    if (Request(s, value, needId, recipient, choice, choices, files ?? [], command, feature) is not { } request)
                        return null;
                    if (TryClaim(ticket, now)) return await GoAsync(request, needId, recipient, command);
                }
                else if (!s.Sending && !s.Refreshing && !askedRead)
                {
                    // The reading waits for a read: it comes now, not on the clock.
                    askedRead = true;
                    _ = RefreshAsync();
                }
                await clock.Delay(TimeSpan.FromMilliseconds(100), CancellationToken.None);
            }
            return null;
        }
        finally
        {
            lock (waitingWrites) waitingWrites.Remove(ticket);
        }
    }

    /// <summary>The request of one write, from the state that may take it; null when it is no write that the screens
    /// offer now (the same rules as their models: the feature, the chat, the text, an open request).</summary>
    private PendingRequest? Request(StoreState s, string value, long? needId, string? recipient, int? choice,
                                    IReadOnlyList<long>? choices, IReadOnlyList<long> files, OwnerCommand? command, string? feature)
    {
        if (s.Fleet is not { } fleet || s.Hub is not { } hub) return null;
        if (feature is not null && !s.Offers(feature)) return null;
        if (command is null)
        {
            if (needId is null && !fleet.CanChat(recipient ?? "manager")) return null;
            if (files.Count > 0 && !s.Offers("attachments")) return null;
        }
        var text = value.Trim();
        if (command is { Kind: "control" }) text = "";
        else if ((text.Length == 0 && files.Count == 0) || new StringInfo(text).LengthInTextElements > StoreState.TextLimit) return null;
        if (needId is { } n && !fleet.Needs.Any(x => x.Id == n && x.IsOpen)) return null;
        return PendingRequest.New(hub, fleet.Db, settings.ClientLabel, text, needId: needId, choice: choice,
                                  choices: choices, recipient: needId is null && command is null && s.Offers("direct_chat") ? recipient : null,
                                  command: command, attachments: files);
    }

    /// <summary>The write whose turn it is takes the store, in one step with the check: nothing else can write until it
    /// ends. A write that came earlier and still waits goes first.</summary>
    private bool TryClaim(long ticket, DateTimeOffset now)
    {
        lock (gate)
        {
            if (!state.CanWrite(now)) return false;
            lock (waitingWrites) if (waitingWrites.Min != ticket) return false;
            state = state with { Sending = true, Version = state.Version + 1 };
        }
        Raise();
        return true;
    }

    private async Task<string?> GoAsync(PendingRequest request, long? needId, string? recipient, OwnerCommand? command)
    {
        try
        {
            outbox.Save(request);
        }
        catch (Exception e) when (e is IOException or OutboxException or UnauthorizedAccessException)
        {
            const string words = "Cannot save this request. Nothing was sent.";
            Update(x => x with { Sending = false, StorageError = words, StorageErrorDetail = e.Message });
            return words;
        }
        var name = recipient ?? "manager";
        Update(x => x with
        {
            Pending = request,
            AnswersTaken = needId is { } id ? x.AnswersTaken.Remove(id) : x.AnswersTaken,
            // The words leave the field as the request takes their place; words typed while it waited stay.
            Drafts = needId is null && command is null && x.Drafts.GetValueOrDefault(name, "").Trim() == request.Text
                ? x.Drafts.Remove(name) : x.Drafts,
        });
        if (needId is null && command is null) KeepDrafts();
        await TransmitAsync(request);
        var s = State;
        return s.Pending?.RequestId == request.RequestId ? s.Pending.Refusal ?? s.SendError ?? StoreState.SavedRequestWaits : null;
    }

    private async Task TransmitAsync(PendingRequest request)
    {
        Update(x => x with { Sending = true, SendError = null });
        try
        {
            try
            {
                if (request.Command is null)
                {
                    var receipt = await client.SendAsync(request, key);
                    Finish(request, receipt.Edited == true ? receipt.MessageRequestId ?? request.ReplacesRequestId : null);
                }
                else
                {
                    await client.CommandAsync(request, key);
                    Finish(request, null);
                }
            }
            catch (Exception e) when (e is HubException or IOException or OutboxException or UnauthorizedAccessException)
            {
                if (State.Pending?.RequestId != request.RequestId) return;
                if (e is HubException { Kind: HubErrorKind.Refusal, Status: 422 })
                {
                    try
                    {
                        var refused = outbox.RejectSecret(request.RequestId, () => { });
                        Update(x => x with
                        {
                            Pending = refused,
                            Drafts = ImmutableDictionary<string, string>.Empty,
                            AnswerDrafts = ImmutableDictionary<long, string>.Empty,
                            SendError = "The hub refused registered login text. The text and the drafts are gone from this PC.",
                        });
                        KeepDrafts();
                    }
                    catch (Exception storage) when (storage is IOException or OutboxException or UnauthorizedAccessException)
                    {
                        Update(x => x with
                        {
                            StorageError = "Cannot remove the refused text from this PC. Sending is blocked.",
                            StorageErrorDetail = storage.Message,
                        });
                    }
                }
                else if (e is HubException { IsDefinitive: true } refusal)
                {
                    var refused = request with { Refusal = StoreState.PcWords(refusal.NotSentWords) };
                    try
                    {
                        outbox.Save(refused);
                        Update(x => x with { Pending = refused, SendError = refused.Refusal, AuthProblem = refusal.Auth ?? x.AuthProblem });
                    }
                    catch (Exception storage) when (storage is IOException or OutboxException or UnauthorizedAccessException)
                    {
                        Update(x => x with
                        {
                            StorageError = "Cannot save the refusal. The request is kept as it was.",
                            StorageErrorDetail = storage.Message,
                        });
                    }
                }
                else
                {
                    Update(x => x with { SendError = "Your hub did not confirm it. Sending it again does not send it twice." });
                }
            }
            await RefreshAsync();
            if (request.NeedId is { } need && State.AnswersTaken.ContainsKey(need) &&
                State.Fleet?.Needs.Any(n => n.Id == need && n.IsOpen) == true)
                Update(x => x with { AnswersTaken = x.AnswersTaken.Remove(need) });
        }
        finally
        {
            Update(x => x with { Sending = false });
        }
    }

    private void Finish(PendingRequest request, string? editedInPlace)
    {
        outbox.Clear(request.RequestId);
        var before = State;
        Update(x =>
        {
            var name = request.Recipient ?? "manager";
            var y = x;
            if (request.NeedId is { } need)
            {
                if (y.AnswerDrafts.GetValueOrDefault(need, "").Trim() == request.Text)
                    y = y with { AnswerDrafts = y.AnswerDrafts.Remove(need) };
                y = y with
                {
                    Staged = Unstage(y.Staged, "need:" + need, request.Attachments),
                    AnswersTaken = y.AnswersTaken.SetItem(need, request),
                };
            }
            else if (request.Command is null)
            {
                if (y.Drafts.GetValueOrDefault(name, "").Trim() == request.Text) y = y with { Drafts = y.Drafts.Remove(name) };
                y = y with { Staged = Unstage(y.Staged, "agent:" + name, request.Attachments) };
                if (editedInPlace is not null && y.Chats.TryGetValue(name, out var chat))
                    y = y with { Chats = y.Chats.SetItem(name, chat with { Items = ValueList.Of(Edit(chat.Items, editedInPlace, request.Text)) }) };
                else if (!Holds(request, y.Items(name)))
                    y = y with { Delivered = request };
            }
            return y with { Pending = null, SendError = null };
        });
        KeepDrafts();
        DropUnstaged(before);
        KeepStaged();
    }

    /// <summary>The files that the hub took with a message leave their composer; one that he picked while the message
    /// was on its way stays for the next message.</summary>
    private static ImmutableDictionary<string, ValueList<StagedFile>> Unstage(
        ImmutableDictionary<string, ValueList<StagedFile>> staged, string composer, IReadOnlyList<long> sent) =>
        staged.TryGetValue(composer, out var files)
            ? Without(staged, composer, files.Where(f => f.Id is not { } id || !sent.Contains(id)))
            : staged;

    /// <summary>The bytes of the picked files that no composer holds any more.</summary>
    private void DropUnstaged(StoreState before)
    {
        var held = State.Staged.Values.SelectMany(v => v).Select(f => f.RequestId).ToHashSet();
        foreach (var file in before.Staged.Values.SelectMany(v => v))
        {
            if (held.Contains(file.RequestId)) continue;
            try { File.Delete(StagedPath(file.RequestId)); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    private static IEnumerable<MobileChatItem> Edit(IEnumerable<MobileChatItem> items, string message, string text) =>
        items.Select(i => i.Kind == "message" && string.Equals(i.Key, message, StringComparison.OrdinalIgnoreCase)
                         ? i with { Text = text } : i);

    /// <summary>The chat holds the message of this request.</summary>
    internal static bool Holds(PendingRequest request, IEnumerable<MobileChatItem> items) =>
        items.Any(i => i.Kind == "message" && string.Equals(i.Key, request.RequestIdText, StringComparison.OrdinalIgnoreCase));

    /// <summary>The receipt that never came: the chat's last page shows the message, so the write is done.</summary>
    private async Task ConfirmPendingAsync(Uri requested, string database)
    {
        var s = State;
        if (s.Pending is not { Refusal: null, NeedId: null, Command: null } request || request.Hub != requested ||
            request.Database != database || s.Sending)
            return;
        var agent = request.Recipient ?? "manager";
        var page = await client.ChatAsync(requested, key, database, agent);
        if (State.Hub != requested || State.Pending?.RequestId != request.RequestId) return;
        var found = Holds(request, page.Items) ? (true, (string?)null)
            : request.ReplacesRequestId is { } original && page.Items.Any(i => i.Kind == "message" &&
                string.Equals(i.Key, original, StringComparison.OrdinalIgnoreCase) && i.Text == request.Text)
                ? (true, original) : (false, null);
        if (!found.Item1) return;
        try
        {
            Finish(request, found.Item2);
        }
        catch (Exception e) when (e is IOException or OutboxException or UnauthorizedAccessException)
        {
            Update(x => x with { StorageError = "Cannot clear the confirmed request. Sending is blocked.", StorageErrorDetail = e.Message });
        }
    }

    // ---------------------------------------------------------------- enrollment, Connect, the key, the device

    /// <summary>Enrolls this PC with a code from the Mac app. Null when it took its key; else the owner's words (a code
    /// that the hub refused may not go again).</summary>
    public async Task<string?> EnrollAsync(string code)
    {
        if (HubClient.NormalizedCode(code) is null) return "A code is eight characters, as the Mac app shows it (XXXX-XXXX).";
        if (State.Hub is not { } hub) return "Give your hub's address in Settings first.";
        try
        {
            var enrollment = await client.EnrollAsync(hub, code);
            try
            {
                settings.Keys.Write(enrollment.Key);
            }
            catch (Exception e) when (e is not OutOfMemoryException)
            {
                Update(x => x with { KeyDetail = e.Message });
                return "This PC could not keep its key. Make a new code.";
            }
            key = enrollment.Key;
            Update(x => x with { Key = KeyState.InHand, AuthProblem = null, ReadError = null });
            await RefreshAsync();
            await ReadDeviceAsync();
            return null;
        }
        catch (HubException e)
        {
            return StoreState.PcWords(HubException.EnrollWords(e));
        }
    }

    /// <summary>The hub's address, as the owner typed it (the iPhone's connect): HTTP or HTTPS, a host, and no login,
    /// path, query or fragment. A new address drops what the PC held of the old hub at once, so nothing of one hub
    /// shows under another, and the hub is read. Null when it took it; else the owner's words, which
    /// <see cref="StoreState.AddressError"/> keeps.</summary>
    public Task<string?> ConnectAsync(string address) => ConnectAsync(address, HubSearch.None);

    private async Task<string?> ConnectAsync(string address, HubSearch search)
    {
        Uri next;
        try
        {
            next = HubClient.Address(address);
        }
        catch (HubException e)
        {
            Update(x => x with { AddressError = e.Message });
            return e.Message;
        }
        Update(x => x with { AddressError = null, Search = search });
        if (next != State.Hub)
        {
            Keep("hub.json", JsonSerializer.SerializeToUtf8Bytes(new KeptHub(next.ToString()), CoreJson.Default.KeptHub));
            Use(next);
        }
        await RefreshAsync();
        return null;
    }

    private void Use(Uri next)
    {
        Update(x => x with { Hub = next });
        ForgetGeneration(keepSnapshot: false);
        lastRequestTook = 0;
        Remove("snapshot.json");
        Update(x => x with
        {
            Device = null, LastRead = null, ReadError = null, ReadWasRefused = false, ReadHeld = false, AuthProblem = null,
            OpenChat = null, OpenTask = null,
        });
    }

    /// <summary>Takes the key off this PC. The hub keeps its record until the owner removes the device on the Mac, so a
    /// new enrollment needs a new code. Null when it went; else the owner's words.</summary>
    public string? ForgetKey()
    {
        try
        {
            settings.Keys.Remove();
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            Update(x => x with { KeyDetail = e.Message });
            return "Cannot take the key off this PC.";
        }
        key = null;
        Update(x => x with { Key = KeyState.None, Device = null });
        return null;
    }

    /// <summary>Reads this device as the hub names it (Settings' address line).</summary>
    public async Task ReadDeviceAsync()
    {
        var s = State;
        if (s.Hub is not { } hub || s.Fleet?.Db is not { } database) return;
        try
        {
            var devices = await client.DevicesAsync(hub, key, database);
            Update(x => x with { Device = devices.ThisDevice });
        }
        catch (HubException)
        {
            Update(x => x with { Device = null });
        }
    }

    // ---------------------------------------------------------------- the files of the store

    private void Load()
    {
        var hub = Read("hub.json", CoreJson.Default.KeptHub)?.Hub;
        Uri? address = null;
        if (hub is not null)
        {
            try { address = HubClient.Address(hub); } catch (HubException) { }
        }
        var initial = new StoreState { Hub = address, Key = settings.Keys.Has ? KeyState.Locked : KeyState.None };
        if (Read("staged.json", CoreJson.Default.KeptStaged) is { } staged)
            initial = initial with
            {
                Staged = staged.Composers.Where(p => p.Value.Count > 0).ToImmutableDictionary(p => p.Key, p => ValueList.Of(p.Value.Select(f =>
                    new StagedFile { RequestId = f.RequestId, Name = f.Name, Mime = f.Mime, Size = f.Size, File = f.File, Failure = f.Failure }))),
            };
        if (Read("notifications.json", CoreJson.Default.KeptLedger) is { } notified)
            ledger = new NotificationLedger { Seen = new Dictionary<string, long>(notified.Seen), Warnings = notified.Warnings is null ? null : new Dictionary<string, string>(notified.Warnings) };
        if (Read("seen.json", CoreJson.Default.KeptSeen) is { } seen)
            initial = initial with { SeenContext = seen.Context, Seen = seen.Seen.ToImmutableDictionary() };
        if (Read("drafts.json", CoreJson.Default.KeptDrafts) is { } drafts)
            initial = initial with
            {
                Drafts = drafts.Agents.ToImmutableDictionary(),
                AnswerDrafts = drafts.Answers.Where(p => long.TryParse(p.Key, out _))
                    .ToImmutableDictionary(p => long.Parse(p.Key, CultureInfo.InvariantCulture), p => p.Value),
            };
        if (address is not null && Read("snapshot.json", CoreJson.Default.KeptSnapshot) is { } kept && kept.Hub == address.ToString())
        {
            try
            {
                var snapshot = HubDecode.Snapshot(Convert.FromBase64String(kept.Body));
                etag = kept.ETag;
                initial = initial with { Fleet = snapshot, SnapshotAt = DateTimeOffset.FromUnixTimeMilliseconds((long)(kept.At * 1000)) };
            }
            catch (Exception e) when (e is HubException or FormatException) { }
        }
        if (address is not null && Read("chats.json", CoreJson.Default.KeptChats) is { } chats && chats.Hub == address.ToString() &&
            (initial.Fleet is null || initial.Fleet.Db == chats.Db))
        {
            keptDatabase = chats.Db;
            var held = ImmutableDictionary<string, ChatPageState>.Empty;
            foreach (var (agent, items) in chats.Chats)
            {
                try
                {
                    held = held.SetItem(agent, new ChatPageState { Agent = agent, Items = ValueList.Of(items.Select(HubDecode.Keyed)) });
                }
                catch (HubException) { }
            }
            initial = initial with { Chats = held };
        }
        try
        {
            initial = initial with { Pending = outbox.Load() };
        }
        catch (Exception e) when (e is IOException or OutboxException or UnauthorizedAccessException)
        {
            initial = initial with { StorageError = "Cannot read the saved request. Sending is blocked.", StorageErrorDetail = e.Message };
        }
        lock (gate) state = raised = initial;
        raisedView = StoreView.Of(initial, clock.Now, settings.Context ?? ScreenContext.Local);
    }

    private void KeepChats()
    {
        var s = State;
        if (s.Hub is null) return;
        var chats = s.Chats.ToDictionary(p => p.Key, p => p.Value.Items.TakeLast(40).ToList());
        Keep("chats.json", JsonSerializer.SerializeToUtf8Bytes(
            new KeptChats(s.Hub.ToString(), s.Fleet?.Db ?? keptDatabase, chats), CoreJson.Default.KeptChats));
    }

    private void KeepDrafts()
    {
        var s = State;
        Keep("drafts.json", JsonSerializer.SerializeToUtf8Bytes(
            new KeptDrafts(new Dictionary<string, string>(s.Drafts),
                           s.AnswerDrafts.ToDictionary(p => p.Key.ToString(CultureInfo.InvariantCulture), p => p.Value)),
            CoreJson.Default.KeptDrafts));
    }

    private T? Read<T>(string name, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type) where T : class
    {
        try
        {
            var path = Path.Combine(settings.Folder, name);
            return File.Exists(path) ? JsonSerializer.Deserialize(File.ReadAllBytes(path), type) : null;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void Keep(string name, byte[] data)
    {
        try
        {
            var path = Path.Combine(settings.Folder, name);
            var temporary = path + ".new";
            var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using (var stream = new FileStream(temporary, options)) stream.Write(data);
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private void Remove(string name)
    {
        try { File.Delete(Path.Combine(settings.Folder, name)); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    // ---------------------------------------------------------------- the state and its change

    private void Update(Func<StoreState, StoreState> change)
    {
        lock (gate)
        {
            var next = change(state);
            if (ReferenceEquals(next, state)) return;
            state = next with { Version = state.Version + 1 };
        }
        Raise();
    }

    /// <summary>Raises the change from the last raised state to the newest, in order: two updates at once give one or two
    /// changes, never one that goes back. A state that changes no model of a screen raises nothing (a read that brought
    /// nothing new, a field that no screen reads): the next change then counts from the last one raised.</summary>
    private void Raise(bool byClock = false)
    {
        lock (raising)
        {
            StoreState current;
            lock (gate) current = state;
            if (current.Version < raised.Version || current.Version == raised.Version && !byClock) return;
            StoreView view;
            StoreChange change;
            try
            {
                view = StoreView.Of(current, clock.Now, settings.Context ?? ScreenContext.Local);
                change = StoreChange.Between(raised, current, raisedView, view);
            }
            catch (Exception e) when (e is not OutOfMemoryException)
            {
                // A model that cannot be built is no reason to keep a change back: every part may have changed.
                view = raisedView;
                change = StoreChange.Between(raised, current, raisedView, raisedView) with { Parts = (StoreParts)127 };
            }
            if (change.Parts == StoreParts.None) return;
            raised = current;
            raisedView = view;
            try { Changed?.Invoke(this, change); }
            catch (Exception) when (!disposed) { }
        }
    }

    public async ValueTask DisposeAsync()
    {
        disposed = true;
        ageWatch?.Cancel();
        frontLoop?.Cancel();
        chatsCancel?.Cancel();
        StopWatching();
        lock (pressWaits) foreach (var wait in pressWaits.Values) wait.Cancel();
        if (chatsReading is not null) { try { await chatsReading; } catch (Exception) { } }
        client.Dispose();
    }
}

/// <summary>A read that is asked for while it runs runs once more, and is never dropped (FleetCore's RunAgain): the calls
/// during one run share the one more, and each returns only after a run that began after it.</summary>
internal sealed class RunOnceMore
{
    private readonly object gate = new();
    private bool running;
    private bool again;
    private int started;
    private readonly List<(int Run, TaskCompletionSource Done)> waiting = new();

    public async Task Run(Func<Task> body)
    {
        TaskCompletionSource? mine = null;
        lock (gate)
        {
            if (running)
            {
                again = true;
                mine = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                waiting.Add((started + 1, mine));
            }
            else
            {
                running = true;
            }
        }
        if (mine is not null)
        {
            await mine.Task;
            return;
        }
        while (true)
        {
            int run;
            lock (gate)
            {
                again = false;
                started += 1;
                run = started;
            }
            try { await body(); }
            catch (Exception) { }
            List<TaskCompletionSource> done;
            lock (gate)
            {
                done = waiting.Where(w => w.Run <= run).Select(w => w.Done).ToList();
                waiting.RemoveAll(w => w.Run <= run);
                if (!again)
                {
                    running = false;
                    foreach (var d in done) d.TrySetResult();
                    return;
                }
            }
            foreach (var d in done) d.TrySetResult();
        }
    }
}

/// <summary>The last reading, as the store keeps it between launches: the body as the hub sent it.</summary>
internal sealed record KeptSnapshot(string Hub, string? ETag, double At, string Body);

/// <summary>The newest 40 items of each chat, for one hub and generation.</summary>
internal sealed record KeptChats(string Hub, string? Db, Dictionary<string, List<MobileChatItem>> Chats);

/// <summary>The seen marks of one hub and generation.</summary>
internal sealed record KeptSeen(string? Context, Dictionary<string, double> Seen);

/// <summary>The drafts: one for each agent, and one for each open request.</summary>
internal sealed record KeptDrafts(Dictionary<string, string> Agents, Dictionary<string, string> Answers);

/// <summary>The hub's address.</summary>
internal sealed record KeptHub(string? Hub);

/// <summary>The files that the owner picked, by composer; their bytes are in the folder `staged`, by request id.</summary>
internal sealed record KeptLedger(Dictionary<string, long> Seen, Dictionary<string, string>? Warnings);

internal sealed record KeptStaged(Dictionary<string, List<KeptFile>> Composers);

internal sealed record KeptFile(Guid RequestId, string Name, string Mime, long Size, MessageAttachment? File, string? Failure);
