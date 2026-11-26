using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Founderizer.Core;

namespace Founderizer.Owner.Vault;

/// <summary>**What the secure form starts from** (the Mac's <c>SecretPreset</c>): an agent's request for one secret, the
/// chat that it was opened from, a key that the owner pasted there, or nothing. Nothing keeps it: a pasted key is in it
/// only until the form takes it.</summary>
public sealed class SecretPreset
{
    /// <summary>The request that the save answers (owner feature <c>secret_requests</c>).</summary>
    public long? Need { get; init; }
    public SecretKind Kind { get; init; } = SecretKind.ApiKey;
    public string Env { get; init; } = "";
    public string Url { get; init; } = "";
    /// <summary>What each agent gets: the request's proposal, which the owner changes in the form.</summary>
    public IReadOnlyDictionary<string, SecretGrant> Give { get; init; } = new Dictionary<string, SecretGrant>();
    /// <summary>The agent of the chat that the form was opened from. After the save, the owner's message there names the
    /// secret and who holds it, never its value.</summary>
    public string? Tell { get; init; }
    /// <summary>A key that the owner pasted into a chat and saves here instead. The form takes it into its field, and it is
    /// here no more.</summary>
    public string? Key { init => key = value; }
    private string? key;

    internal string? TakeKey()
    {
        var taken = key;
        key = null;
        return taken;
    }
    /// <summary>The note that the request gives the secret (owner feature <c>secret_notes</c>).</summary>
    public string Note { get; init; } = "";
    /// <summary>The account that a login request names: the start of the form's User name field.</summary>
    public string Account { get; init; } = "";
    /// <summary>The reference of a key of the list whose value this form replaces, in one press
    /// (<see cref="SecretValueReplace"/>): a request for a new value of a key that the fleet holds, and the part "Value" of
    /// a key's page.</summary>
    public string? Replace { get; init; }

    /// <summary>The form of a request, or null for an item that asks for no secret and for a request that gives no form
    /// (<see cref="SecretRequest.GivesNoForm"/>).</summary>
    public static SecretPreset? Of(OwnerNeed need)
    {
        if (SecretRequest.Of(need) is not { GivesNoForm: false } asked) return null;
        return new SecretPreset
        {
            // A request for a new value takes no address: it would take the place of the key's own.
            Need = need.Id, Kind = asked.Kind, Env = asked.Env ?? "", Url = SecretValueReplace.FormAddress(asked), Give = asked.Proposal,
            Note = asked.Note ?? "", Account = asked.Kind == SecretKind.Login ? asked.Account ?? "" : "", Replace = asked.Replaces,
        };
    }
}

/// <summary>One agent's step of a save: the level that it gets (null takes the secret back from it), and what the owner
/// must know about it.</summary>
public sealed class SaveGrant(string agent, SecretGrant? grant)
{
    public string Agent { get; } = agent;
    public SecretGrant? Grant { get; } = grant;
    public bool Done { get; internal set; }
    public string? Note { get; internal set; }
    public bool Warning { get; internal set; }
}

/// <summary>**What came of a save once the hub had its reference, step by step** (the Mac's <c>SecretProgress</c>). The
/// sealed copy, until the vault has it, is the only thing of the value that is left here, and only that vault opens
/// it.</summary>
public sealed class SecretProgress
{
    internal SecretProgress(string login, string title, SecretKind kind, IReadOnlyList<SaveGrant> grants, long? need,
                            IReadOnlyList<long>? needs = null, string? note = null, string? tell = null, string? sealedCopy = null,
                            (string Statement, string Signature)? signed = null)
    {
        Login = login;
        Title = title;
        Kind = kind;
        Grants = grants;
        Need = need;
        Needs = needs ?? (need is { } own ? [own] : []);
        AnswerIds = Needs.Distinct().ToDictionary(n => n, _ => Guid.NewGuid());
        Note = note;
        Tell = tell;
        SealedCopy = sealedCopy;
        Signed = signed;
    }

    public string Login { get; }
    public string Title { get; }
    public SecretKind Kind { get; }
    public IReadOnlyList<SaveGrant> Grants { get; }
    /// <summary>The form's own request, or null.</summary>
    public long? Need { get; }
    /// <summary>The requests that the save answers: its own first, then, for a new value of a key of the list, each other
    /// open request for a new value of that key.</summary>
    public IReadOnlyList<long> Needs { get; }
    /// <summary>The one answer of each request, so that a retry is that answer again and never a second one.</summary>
    internal Dictionary<long, Guid> AnswerIds { get; }
    internal HashSet<long> AnsweredNeeds { get; } = [];
    public bool Answered => Needs.All(AnsweredNeeds.Contains);
    /// <summary>The words when the form's own request had its answer already.</summary>
    public string? AnswerNote { get; internal set; }
    public string? AnswerProblem { get; internal set; }
    /// <summary>The secret's note as the form showed it at the save, which goes with the own request's answer.</summary>
    public string? Note { get; }
    public string? Tell { get; }
    public bool Told { get; internal set; }
    public string? TellProblem { get; internal set; }
    internal string? SealedCopy { get; set; }
    /// <summary>The sealed copy is in the vault.</summary>
    public bool InVault => SealedCopy is null;
    public string? SealedProblem { get; internal set; }
    internal (string Statement, string Signature)? Signed { get; }
    /// <summary>This save replaces the value of a key that the list has.</summary>
    public bool Replaces => Signed is not null;
    public bool IsDone => InVault && Grants.All(g => g.Done) && Answered && (Tell is null || Told);
    public IReadOnlyList<SaveGrant> Given => Grants.Where(g => g.Done).ToList();
}

/// <summary>What the form shows.</summary>
public enum SecretFormPhase
{
    /// <summary>The fields.</summary>
    Form,
    /// <summary>The central vault does not answer with the key that this PC pinned: nothing can be saved, and Try again
    /// reads it once more (<see cref="SecretForm.StartAsync"/>).</summary>
    NoVault,
    /// <summary>The save's steps (<see cref="SecretForm.Progress"/>).</summary>
    Saved,
}

/// <summary>**The secure form as a model** (the Mac's <c>SecretEntryView</c> without its drawing): the owner types one login
/// or one API key, and the fleet's central vault keeps it. It is the one way a value reaches a server: the central vault
/// gives it to each server whose agents get it, for a grant that the owner signed.
///
/// The form saves only while the hub names, as the central vault's key, the key this PC pinned at Set up. It makes the
/// reference itself, seals the value to that key, registers the reference with the hub (its fingerprints, made here from
/// the hub's salts, and its catalog entry), and sends the sealed value. Then, in order: the agents that the owner chose
/// get it, each grant signed with the owner key, the requests that the form answers get their answer, and the chat that it
/// was opened from gets one message of the owner's that names the secret and never its value. A step that fails is shown
/// with its words and Try again (<see cref="TryAgainAsync"/>); the steps before it stay done.
///
/// **The value is only in <see cref="Login"/>.** It leaves the form as soon as the hub has the reference: then the sealed
/// copy is all that is left of it here. The bytes of the item are cleared at the end of each try. No draft, outbox record,
/// file or log gets it. The form sends only to the hub and the generation that it was opened on.
///
/// Not safe for calls from two threads: the window calls it from its own, and <see cref="Changed"/> comes there.</summary>
public sealed class SecretForm
{
    private readonly IVaultCalls calls;
    private readonly ICentralVaultPins pins;
    private readonly VaultSigning signing;
    private readonly Func<string, bool> looksLikeKey;
    private readonly Func<string, string> label;
    private readonly Func<string, string, Task<bool>>? say;
    private readonly Func<int, byte[]>? random;
    private readonly Uri? hub;
    private readonly string? database;

    private LoginSecret login;
    private Dictionary<string, SecretGrant> access;
    private HashSet<string> touched = [];
    private readonly HashSet<string> proposed;
    private Dictionary<string, SecretGrant> raised = [];
    private string? levelsOf;
    private CatalogEntry? levelsEntry;
    private string? sameName;
    private string? unconfirmed;            // the reference of a save that the hub did not confirm
    private string note;
    private Guid declineId = Guid.NewGuid(), clarifyId = Guid.NewGuid();

    /// <param name="preset">What the form starts from.</param>
    /// <param name="calls">The store's calls.</param>
    /// <param name="pins">The central vault's key as this PC pinned it.</param>
    /// <param name="signing">The owner's signatures.</param>
    /// <param name="looksLikeKey">Whether a text holds something that looks like a key: the window gives
    /// <c>KeyInText.Contains</c> of Founderizer.Core.</param>
    /// <param name="label">An agent's name as the app shows it.</param>
    /// <param name="say">The owner's message to an agent, for a form that a chat opened.</param>
    /// <param name="random">Only a test gives its own.</param>
    public SecretForm(SecretPreset preset, IVaultCalls calls, ICentralVaultPins pins, VaultSigning signing, Func<string, bool> looksLikeKey,
                      Func<string, string> label, Func<string, string, Task<bool>>? say = null, Func<int, byte[]>? random = null)
    {
        Preset = preset;
        hub = calls.Hub;
        database = calls.Database;
        this.calls = new CallsOfOnePlace(calls.Held(), hub, database);
        this.pins = pins;
        this.signing = signing.On(this.calls);
        this.looksLikeKey = looksLikeKey;
        this.label = label;
        this.say = say;
        this.random = random;
        login = Blank();
        if (preset.TakeKey() is { } key) login.Password = key;
        access = new Dictionary<string, SecretGrant>(preset.Give, StringComparer.Ordinal);
        proposed = preset.Give.Keys.ToHashSet(StringComparer.Ordinal);
        note = SecretRequest.OneLine(preset.Note, SecretRequest.NoteMost);
        Phase = calls.Features.Contains(VaultRoutes.CentralVaultFeature) ? SecretFormPhase.Form : SecretFormPhase.NoVault;
    }

    /// <summary>The hub has the features of the form (the Mac's <c>isOffered</c>).</summary>
    public static bool IsOffered(IReadOnlyList<string> features) =>
        features.Contains(VaultRoutes.SecretsFeature) && features.Contains(VaultRoutes.GrantsFeature);

    public SecretPreset Preset { get; }
    public SecretFormPhase Phase { get; private set; }
    public SecretProgress? Progress { get; private set; }
    /// <summary>The last problem or the next step: the form's one orange line.</summary>
    public string? Message { get; private set; }
    /// <summary>A step runs now.</summary>
    public bool Busy { get; private set; }
    /// <summary>The save passed the checks that end with a line of their own and has not ended: the ring.</summary>
    public bool Saving { get; private set; }
    /// <summary>The central vault's key, which the form seals to: the one that this PC pinned. Null while it is not known.</summary>
    public string? Central { get; private set; }
    /// <summary>The fields. Change one with <see cref="Edit"/>, which keeps the form's rules about the name.</summary>
    public LoginSecret Login => login;
    /// <summary>The rows of "Who can use it".</summary>
    public IReadOnlyDictionary<string, SecretGrant> Access => access;
    /// <summary>The rows show the levels of now of a key of the list.</summary>
    public bool ShowsLevels => levelsOf is not null;
    /// <summary>A save that stopped on the note opens its field.</summary>
    public bool NoteOpened { get; private set; }
    public bool IsRequest => Preset.Need is not null;
    /// <summary>The form has the note's field: the request gave a note, and the hub keeps one.</summary>
    public bool ShowsNote => IsRequest && Preset.Note.Length > 0 && calls.Features.Contains(VaultRoutes.NotesFeature);
    public string Note => note;
    /// <summary>The request takes his words about it.</summary>
    public bool Clarifies => IsRequest && calls.Features.Contains(VaultRoutes.ClarifyFeature);

    /// <summary>The form changed.</summary>
    public event Action? Changed;
    /// <summary>The form is at its end: the reference that was saved, or null after a decline or his words.</summary>
    public event Action<string?>? Done;

    /// <summary>What a key request's card draws for his save (<see cref="KeySaveLooks"/>).</summary>
    public KeySaveLook? Look =>
        Progress is { } progress
            ? KeySaveLooks.Of(progress.IsDone, progress.Given.Any(g => g.Warning) || progress.AnswerNote is not null, Busy, Saving)
            : KeySaveLooks.Of(null, false, Busy, Saving);

    /// <summary>A change of the fields. Any change drops the reference of a save that the hub did not confirm, and a change
    /// of the name takes the levels of another key out of the rows.</summary>
    public void Edit(Action<LoginSecret> change)
    {
        if (Busy) return;               // a save reads the fields after its first calls: they stay as they were
        var title = login.Title;
        change(login);
        unconfirmed = null;
        if (login.Title != title)
        {
            sameName = null;
            DropLevels();
        }
        Notify();
    }

    /// <summary>A login, or an API key. The other kind's fields go: a password never becomes a key, and the reverse.</summary>
    public void SetKind(SecretKind kind)
    {
        if (Busy || login.Kind == kind) return;
        Blank(login);
        login = new LoginSecret { Kind = kind };
        sameName = null;
        unconfirmed = null;
        Message = null;
        DropLevels();
        Notify();
    }

    /// <summary>The owner sets a row; null is no access.</summary>
    public void SetAccess(string agent, SecretGrant? grant)
    {
        if (Busy) return;
        if (grant is { } level) access[agent] = level;
        else access.Remove(agent);
        touched.Add(agent);
        proposed.Remove(agent);
        raised.Remove(agent);
        Notify();
    }

    /// <summary>The note's field holds no more than the hub takes, so what he reads there is what goes; and the line about
    /// a key in the note leaves once the note holds none. A change that makes the note one character longer than it was,
    /// and too long, does not go in: a typed character, anywhere in the note. Any other change that is too long is cut at
    /// the end of the note.</summary>
    public void SetNote(string words)
    {
        if (Busy) return;
        if (SecretRequest.NoteLength(words) > SecretRequest.NoteMost)
            note = new StringInfo(words).LengthInTextElements == new StringInfo(note).LengthInTextElements + 1 &&
                   SecretRequest.NoteLength(note) <= SecretRequest.NoteMost
                ? note : SecretRequest.Cut(words, SecretRequest.NoteMost, note: true);
        else note = words;
        if (Message == VaultWords.KeyInNote && !HoldsKey(note)) Message = null;
        Notify();
    }

    /// <summary>The central vault's key, read as the form opens and at each Try again: while the hub serves the vault and
    /// names the very key this PC pinned at Set up, the form saves there. Otherwise nothing can be saved. What came of a
    /// save stays.</summary>
    public async Task StartAsync()
    {
        if (Phase == SecretFormPhase.Saved) return;
        string? recipient = null;
        if (HasContext)
        {
            try
            {
                // The Mac's form asks only for the pinned key: the hub decides about the recovery key (with a list of the
                // owner's devices the vault needs none), and refuses the save (503) when it takes no new secret.
                if (calls.Features.Contains(VaultRoutes.CentralVaultFeature) && await VaultRoutes.ReadingAsync(calls) is { FleetId: { } fleet } reading &&
                    hub is not null)
                    recipient = reading.Trusted(pins.Recipient(hub, fleet));
            }
            catch (Exception e) when (IsCallFailure(e) || e is System.IO.InvalidDataException)
            {
                // no reading, or a pins file that does not read: no key
            }
        }
        if (Phase == SecretFormPhase.Saved) return;
        Central = recipient;
        Phase = recipient is null ? SecretFormPhase.NoVault : SecretFormPhase.Form;
        Notify();
    }

    /// <summary>The secrets of the catalog that fit the request: an earlier save can answer it.</summary>
    public async Task<IReadOnlyList<(string Reference, CatalogEntry Entry)>> FitsAsync()
    {
        if (Preset.Replace is not null || Asked is not { } asked || !HasContext) return [];
        try
        {
            var (_, catalog) = await VaultRoutes.TeamAsync(calls);
            return (catalog ?? []).Where(e => e.Value.IsApiKey == (asked.Kind == SecretKind.ApiKey) && asked.Fits(e.Value.Name))
                                  .OrderBy(e => e.Key, StringComparer.Ordinal).Select(e => (e.Key, e.Value)).ToList();
        }
        catch (Exception e) when (IsCallFailure(e))
        {
            return [];
        }
    }

    /// <summary>Save, or Replace.</summary>
    public async Task SaveAsync()
    {
        if (Busy) return;
        Message = null;
        if ((login.Problem ?? login.VaultProblem) is { } problem) { Say(problem); return; }
        // The note is in the fleet's settings, not in the vault: one that looks like a key, or that holds the value of this
        // very form, stops the save before anything is sent.
        if (ShowsNote && HoldsKey(NoteWords)) { NoteOpened = true; Say(VaultWords.KeyInNote); return; }
        if (!HasContext) { Say(VaultWords.NoStatus); return; }
        if (Central is not { } recipient) { Phase = SecretFormPhase.NoVault; Notify(); return; }
        Busy = true;
        Notify();
        try
        {
            string title = login.Title;
            var kind = login.Kind;
            var variable = login.Variable;
            var grants = Chosen();
            (string Reference, CatalogEntry Entry)? replacing = null;
            // Before anything is sent: the hub answers for this generation, and its catalog has room.
            try
            {
                var (_, catalog) = await VaultRoutes.TeamAsync(calls);
                if (catalog is null) { Message = VaultWords.NoList; return; }
                var replaces = calls.Features.Contains(VaultRoutes.ReplaceFeature) && signing.Offered;
                if (Preset.Replace is { } asked)
                {
                    // A new value of a key that the card names, in one press: no orange line first, and no access step.
                    var (plan, entry) = SecretValueReplace.Plan(asked, Preset.Env, catalog, replaces);
                    if (plan == ReplacePlan.Gone) { Message = VaultWords.Gone; return; }
                    if (entry is null) { Message = VaultWords.NotYet(title); return; }
                    replacing = (asked, entry);
                    grants = [];
                }
                else
                {
                    // The entry of a save that the hub did not confirm is this very save, not a second secret.
                    switch (SecretNameHeld.Of(title, kind, catalog, unconfirmed))
                    {
                        case SecretNameHeld.None when levelsOf is not null:
                            // No key of this name any more: rows that the form filled with a key's levels are not his
                            // choice for a new key, so they give nothing.
                            DropLevels();
                            grants = Chosen();
                            break;
                        case SecretNameHeld.Twice:
                            DropLevels();
                            Message = VaultWords.Twice(title);
                            return;
                        case SecretNameHeld.Second when sameName != title:
                            sameName = title;
                            Message = VaultWords.Second(title);
                            return;
                        case SecretNameHeld.Key(var reference, var entry):
                            if (!replaces || entry.HasStore) { Message = VaultWords.NotYet(title); return; }
                            if (sameName != title || levelsOf != reference)
                            {
                                // The first Save: the line says what the next one does, and the rows show who has the key now.
                                sameName = title;
                                Message = VaultWords.Replaces(title);
                                ShowLevels(reference, entry);
                                return;
                            }
                            replacing = (reference, entry);
                            // The same agents keep the key: only a row that he set himself makes a step.
                            grants = [.. Changes(entry), .. DoorGrant()];
                            break;
                    }
                }
                if (replacing is null && catalog.Count >= LoginSecret.MaxCatalog)
                {
                    Message = VaultWords.Full(LoginSecret.MaxCatalog.ToString(System.Globalization.CultureInfo.InvariantCulture));
                    return;
                }
            }
            catch (Exception e) when (IsCallFailure(e))
            {
                Message = VaultWords.NoAnswerForSave(Why(e));
                return;
            }
            Saving = true;
            Notify();
            await SaveCentralAsync(recipient, title, kind, variable, grants, replacing);
        }
        finally
        {
            Busy = false;
            Saving = false;
            Notify();
        }
    }

    /// <summary>A save into the central vault. The value is sealed to the vault's key first, so it leaves the form as soon as
    /// the hub has the reference. A hub that does not confirm the reference leaves the fields as typed, and Save again goes
    /// under the same one. <paramref name="replacing"/>: the key of the list whose value this save replaces, under that
    /// key's own reference, with the owner's signed statement about the sealed copy, which is made before anything is
    /// sent.</summary>
    private async Task SaveCentralAsync(string recipient, string title, SecretKind kind, string? variable, IReadOnlyList<SaveGrant> grants,
                                        (string Reference, CatalogEntry Entry)? replacing)
    {
        byte[] value;
        try
        {
            // A new value in one press seals the key alone: an address in it would take the place of the key's own.
            value = Preset.Replace is not null ? SecretValueReplace.Value(login) : login.Value();
        }
        catch (InvalidOperationException)
        {
            Message = VaultWords.CannotSend;
            return;
        }
        string reference, sealedCopy;
        (string Statement, string Signature)? signed = null;
        try
        {
            try
            {
                sealedCopy = AgeSeal.Seal(value, recipient, random);
            }
            catch (Exception e) when (e is SealException or CryptographicException)
            {
                Message = VaultWords.CannotSeal;
                return;
            }
            reference = replacing?.Reference ?? unconfirmed ?? VaultIds.NewReference();
            if (replacing is not null)
            {
                try
                {
                    signed = await signing.ReplaceAsync(reference, sealedCopy);
                }
                catch (Exception e) when (IsCallFailure(e))
                {
                    Message = VaultWords.NothingSent(Why(e));
                    return;
                }
                if (!HasContext) { Message = VaultWords.NoStatus; return; }
            }
            else
            {
                unconfirmed = reference;
            }
            try
            {
                // A replace keeps the entry's site, and the hub gives no site from an address then: it sends none.
                await RegisterAsync(calls, reference, replacing?.Entry.Title ?? title, kind, replacing is { } held ? held.Entry.Env : variable,
                                    replacing is null ? VaultRoutes.AddressFor(login, calls.Features) : null, value);
            }
            catch (HubException e) when (e is { Kind: HubErrorKind.Refusal, Status: 503 })
            {
                // The hub takes no new secret while the central vault does not answer: nothing was sent.
                Central = null;
                Phase = SecretFormPhase.NoVault;
                return;
            }
            catch (Exception e) when (IsCallFailure(e))
            {
                Message = Preset.Replace is not null ? VaultWords.CannotChange(Why(e)) : VaultWords.NotRegistered(Why(e));
                return;
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(value);
        }
        Clear();
        unconfirmed = null;
        // A new value of a key of the list also answers each open request for a new value of that key.
        var needs = SecretValueReplace.Answers(Preset.Need, replacing?.Reference, calls.Needs);
        Progress = new SecretProgress(reference, title, kind, grants, Preset.Need, needs, ShowsNote ? NoteWords : null, Preset.Tell, sealedCopy, signed);
        Phase = SecretFormPhase.Saved;
        Notify();
        await ProceedAsync();
    }

    /// <summary>**The hub's half of a save**: the fingerprints of the value, made here from the salts that the hub gives for
    /// this reference, and the catalog entry under it. The hub takes the same reference again. The value does not leave
    /// this call.</summary>
    internal static async Task RegisterAsync(IVaultCalls calls, string reference, string title, SecretKind kind, string? variable, string? address,
                                             byte[] value)
    {
        var salts = await VaultRoutes.SaltsAsync(calls, reference);
        await VaultRoutes.AddAsync(calls, reference, title, kind, variable, address, SecretFingerprint.Of(value, salts), Guid.NewGuid());
    }

    /// <summary>A secret of the catalog answers the request: the agents that the owner chose get it, then the request its
    /// answer.</summary>
    public async Task AnswerWithAsync(string reference, CatalogEntry entry)
    {
        if (Busy) return;
        Busy = true;                // the rows do not change while the levels are read again
        Message = null;
        Notify();
        try
        {
            var kind = entry.IsApiKey ? SecretKind.ApiKey : SecretKind.Login;
            IReadOnlyList<SaveGrant> grants;
            if (levelsOf == reference)
            {
                // The levels of now, read again; when the hub does not answer, the entry of the Save that showed them.
                var now = levelsEntry ?? entry;
                if (HasContext)
                {
                    try
                    {
                        if ((await VaultRoutes.TeamAsync(calls)).Catalog?.GetValueOrDefault(reference) is { } fresh) now = fresh;
                    }
                    catch (Exception e) when (IsCallFailure(e))
                    {
                        // the entry of that Save
                    }
                }
                grants = [.. Changes(now), .. DoorGrant()];
            }
            else
            {
                // The rows show no levels, or the levels of another key: the answer gives what he set himself and what the
                // request proposes, and nothing of a level that the form put into a row for that other key.
                var rows = levelsOf is null ? access
                    : SecretReplaceAccess.Own(access, calls.Holders, touched, raised, Preset.Give, proposed);
                grants = [.. calls.Holders.Where(rows.ContainsKey).Select(a => new SaveGrant(a, kind == SecretKind.Login ? SecretGrant.Use : rows[a])),
                          .. DoorGrant()];
            }
            // The note goes only to a secret of the list with no note of its own and of the account that the request names.
            // One that looks like a key stops the answer here, read before the fields are cleared.
            var goes = ShowsNote && Asked?.NoteGoes(entry) == true;
            if (goes && HoldsKey(NoteWords)) { NoteOpened = true; Message = VaultWords.KeyInNote; return; }
            Saving = true;
            Clear();
            Progress = new SecretProgress(reference, entry.Name, kind, grants, Preset.Need, note: goes ? NoteWords : null);
            Phase = SecretFormPhase.Saved;
            Notify();
            await ProceedAsync();
        }
        finally
        {
            Busy = false;
            Saving = false;
            Notify();
        }
    }

    /// <summary>Try again: the steps that are not done.</summary>
    public Task TryAgainAsync() => Busy ? Task.CompletedTask : ProceedAsync();

    /// <summary>The steps after the registration, each once: the sealed value to the central vault, the grants, each signed
    /// with the owner key first, the answers of the requests and the message to the chat's agent. A step that is done is not
    /// done again; Try again runs the rest. Nothing follows a save before the vault has its value.</summary>
    private async Task ProceedAsync()
    {
        if (Progress is not { } progress) return;
        if (!HasContext) { Say(VaultWords.NoStatusAgain); return; }
        var wasBusy = Busy;
        Busy = true;
        Message = null;
        Notify();
        try
        {
            if (progress.SealedCopy is { } sealedCopy)
            {
                try
                {
                    await VaultRoutes.IntakeAsync(calls, progress.Login, sealedCopy, progress.Signed, Guid.NewGuid());
                    progress.SealedCopy = null;
                    progress.SealedProblem = null;
                    Notify();
                }
                catch (Exception e) when (IsCallFailure(e))
                {
                    progress.SealedProblem = Why(e);
                    return;
                }
            }
            foreach (var wanted in progress.Grants.Where(g => !g.Done))
            {
                if (!HasContext) { Message = VaultWords.NoStatusAgain; return; }
                try
                {
                    var receipt = await SecretAccess.ChangeAsync(calls, signing, progress.Login, wanted.Agent, label(wanted.Agent), wanted.Grant);
                    (wanted.Note, wanted.Warning) = NoteOf(receipt, progress.Title);
                    wanted.Done = true;
                }
                catch (Exception e) when (IsCallFailure(e))
                {
                    wanted.Note = $"{(wanted.Grant is null ? VaultWords.NotTakenBack : VaultWords.NotGiven)} {Why(e)}";
                    wanted.Warning = true;
                }
                Notify();
            }
            if (!progress.Answered)
            {
                progress.AnswerProblem = null;
                foreach (var need in progress.Needs.Where(n => !progress.AnsweredNeeds.Contains(n)).ToList())
                {
                    if (!HasContext) { Message = VaultWords.NoStatusAgain; return; }
                    var own = need == progress.Need;
                    try
                    {
                        // The secret's note goes with the form's own request alone.
                        await VaultRoutes.AnswerAsync(calls, need, progress.Login, own ? progress.Note : null, progress.AnswerIds[need]);
                        progress.AnsweredNeeds.Add(need);
                    }
                    catch (HubException e) when (e is { Kind: HubErrorKind.Refusal, Status: 409, Code: "request_answered" })
                    {
                        // A request that had its answer already takes no other.
                        progress.AnsweredNeeds.Add(need);
                        if (own) progress.AnswerNote = VaultWords.HadAnswer;
                    }
                    catch (Exception e) when (IsCallFailure(e))
                    {
                        progress.AnswerProblem ??= Why(e);
                    }
                }
                Notify();
            }
            if (progress is { Tell: { } agent, Told: false } && HasContext)
            {
                progress.Told = say is not null && await say(agent, Telling(progress));
                progress.TellProblem = progress.Told ? null : VaultWords.CannotSay;
                Notify();
            }
            if (HasContext) await calls.RefreshAsync();
            if (progress is { IsDone: true, Tell: not null } && !progress.Given.Any(g => g.Warning)) Done?.Invoke(progress.Login);
        }
        finally
        {
            Busy = wasBusy;
            Notify();
        }
    }

    /// <summary>The owner says no to the request, with one press: no reason, no second step.</summary>
    public async Task DeclineAsync()
    {
        if (Busy || Preset.Need is not { } need || !HasContext) return;
        Busy = true;
        Message = null;
        Notify();
        try
        {
            await VaultRoutes.DeclineAsync(calls, need, declineId);
            Clear();
            await calls.RefreshAsync();
            Done?.Invoke(null);
        }
        catch (Exception e) when (IsCallFailure(e))
        {
            if (e is HubException { Kind: HubErrorKind.Refusal, Status: 409 }) declineId = Guid.NewGuid();   // another command next time
            Message = VaultWords.NotDeclined(Why(e));
        }
        finally
        {
            Busy = false;
            Notify();
        }
    }

    /// <summary>**Needs clarification**: his words about the request close it and go to the agent that asked. Words that
    /// look like a key, or that hold the value of the form's own field, stay here. True when they went.</summary>
    public async Task<bool> ClarifyAsync(string text)
    {
        var words = FoundationText.Trim(text);
        if (Busy || Preset.Need is not { } need || !Clarifies || !HasContext || words.Length == 0 ||
            SecretRequest.CodePoints(words) > SecretRequest.ClarifyMost) return false;
        if (HoldsKey(words)) { Say(VaultWords.KeyInWords); return false; }
        Busy = true;
        Message = null;
        Notify();
        try
        {
            await VaultRoutes.ClarifyAsync(calls, need, words, clarifyId);
            Clear();
            await calls.RefreshAsync();
            Done?.Invoke(null);
            return true;
        }
        catch (Exception e) when (IsCallFailure(e))
        {
            if (e is HubException { Kind: HubErrorKind.Refusal, Status: 409 }) clarifyId = Guid.NewGuid();
            Message = VaultWords.NotClarified(Why(e));
            return false;
        }
        finally
        {
            Busy = false;
            Notify();
        }
    }

    /// <summary>The form goes away: its fields are empty from here.</summary>
    public void Close() => Clear();

    /// <summary>The owner's message in the chat that the form was opened from: the secret's name and reference, and who
    /// holds it. It names no value, because the app has none to name. English, as the Mac's: an agent reads it.</summary>
    internal static string Telling(SecretProgress progress)
    {
        var words = new List<string>
        {
            progress.Replaces
                ? $"I replaced the value of the API key {progress.Title} in the vault. The agents that hold it keep it."
                : $"I saved {(progress.Kind == SecretKind.ApiKey ? "the API key" : "the login")} {progress.Title} in the vault, as {progress.Login}.",
        };
        var given = progress.Given.Where(g => g.Grant is not null)
            .Select(g => $"{g.Agent} {(g.Grant == SecretGrant.Read ? "reads it as $" + progress.Title : "uses it through its vault")}").ToList();
        if (given.Count > 0) words.Add((given.Count == 1 ? given[0] : string.Join(", ", given.SkipLast(1)) + " and " + given[^1]) + ".");
        else if (!progress.Replaces) words.Add("No agent holds it yet.");
        return string.Join(" ", words);
    }

    /// <summary>What the owner must know after a grant: the agent's vault access, or when it reads the key.</summary>
    private (string? Note, bool Warning) NoteOf(GrantReceipt receipt, string title)
    {
        var name = label(receipt.Agent);
        if (receipt.Vault is { } vault)
            return vault.After == "broker" ? (VaultWords.UsesVault(name), false)
                : (VaultWords.NoVaultAccess(name, string.Join(" ", vault.Missing.Select(VaultWords.AccessReason))), true);
        return receipt is { Grant: SecretGrant.Read, Changed: true } ? (VaultWords.ReadsFromNextStart(name, title), false) : (null, false);
    }

    /// <summary>The store still shows the hub and the generation of this form, and its reading is current.</summary>
    private bool HasContext =>
        hub is not null && database is not null && calls.Hub == hub && calls.Database == database && calls.WritesNow && IsOffered(calls.Features);

    private SecretRequest? Asked =>
        Preset.Need is { } id && calls.Needs.FirstOrDefault(n => n.Id == id) is { } need ? SecretRequest.Of(need) : null;

    private string NoteWords => SecretRequest.OneLine(note, SecretRequest.NoteMost);

    /// <summary>The words hold what looks like a key, or the very value that the form's Key or Password field holds now.</summary>
    private bool HoldsKey(string words) => looksLikeKey(words) || SecretRequest.Holds(login.Password, words);

    /// <summary>The grants that the owner chose, in the hub's order of the agents. A login is never read.</summary>
    private IReadOnlyList<SaveGrant> Chosen() =>
        [.. calls.Holders.Where(access.ContainsKey).Select(a => new SaveGrant(a, login.Kind == SecretKind.Login ? SecretGrant.Use : access[a])),
         .. DoorGrant()];

    /// <summary>The door, where the request gives it the secret: it has no row, and Save gives it to the door with the
    /// owner's signed grant, as to an agent. A form that no request opened never gives the door anything.</summary>
    private IEnumerable<SaveGrant> DoorGrant() =>
        IsRequest && access.ContainsKey(VaultSigning.DoorHolder) ? [new SaveGrant(VaultSigning.DoorHolder, SecretGrant.Use)] : [];

    private IEnumerable<SaveGrant> Changes(CatalogEntry entry) =>
        SecretReplaceAccess.Changes(entry.Grants, calls.Holders, access, touched, proposed, raised).Select(c => new SaveGrant(c.Agent, c.Grant));

    /// <summary>A replace: each agent's level of now goes into the rows that the owner did not set.</summary>
    private void ShowLevels(string reference, CatalogEntry entry)
    {
        DropLevels();       // first his own rows again: the levels of a key that the rows showed before are no pick of his
        (access, touched, raised) = SecretReplaceAccess.Rows(entry.Grants, calls.Holders, access, touched, proposed);
        levelsOf = reference;
        levelsEntry = entry;
    }

    /// <summary>The name is no longer the key's whose levels the rows show: those levels leave the rows.</summary>
    private void DropLevels()
    {
        if (levelsOf is null) return;
        access = SecretReplaceAccess.Own(access, calls.Holders, touched, raised, Preset.Give, proposed);
        raised = [];
        levelsOf = null;
        levelsEntry = null;
    }

    /// <summary>The form as the preset opens it: the request's kind, name and address, and never a value.</summary>
    private LoginSecret Blank() => new()
    {
        Kind = Preset.Kind, Env = Preset.Env, Url = Preset.Url, Username = Preset.Kind == SecretKind.Login ? Preset.Account : "",
    };

    private void Clear()
    {
        Blank(login);
        login = Blank();
        sameName = null;
    }

    /// <summary>The value's fields of an object that the form lets go, emptied: the window may hold it still.</summary>
    private static void Blank(LoginSecret old)
    {
        old.Password = "";
        old.Totp = "";
        old.Username = "";
        old.Url = "";
        old.Env = "";
    }

    private void Say(string words)
    {
        Message = words;
        Notify();
    }

    private void Notify() => Changed?.Invoke();

    /// <summary>A call, a signature or a check of an answer that failed: each has its words in the form. Anything else is a
    /// fault of the app and goes on as one.</summary>
    private static bool IsCallFailure(Exception e) =>
        e is HubException or SignStop or CryptographicException or OperationCanceledException or InvalidOperationException or ArgumentException
            or System.IO.IOException or UnauthorizedAccessException;

    /// <summary>The words of a failure: the owner's own words of a stop, the hub's words of a refusal, and else one line.</summary>
    private static string Why(Exception error) => error switch
    {
        SignStop => error.Message,
        HubException { Kind: HubErrorKind.Refusal, HubWords.Length: > 0 } refused => HubException.Sentence(refused.HubWords!),
        HubException => error.Message,
        _ => VaultWords.HubDidNotAnswer,
    };
}

/// <summary>**What a key request's card in a chat draws for his save** (the Mac's <c>KeySaveLook</c>; the owner, 20 November
/// 2026: "no text needed, just a nice animation of loading and then a nice and smooth check").</summary>
public enum KeySaveLook
{
    /// <summary>His save runs: the card is its title and a ring.</summary>
    Goes,
    /// <summary>Every step is done: the ring becomes a check that draws itself.</summary>
    Saved,
    /// <summary>A step failed, or ended with words that he must read: the card stands whole, with the form's rows.</summary>
    Failed,
}

public static class KeySaveLooks
{
    /// <summary>The look of a form. <paramref name="done"/>: null while the key is not in the list, else whether every step
    /// after it is done. <paramref name="warned"/>: a done step left words that he must read. Null: the form shows its
    /// fields or a line of its own. **Every step done is the check at once**, also while the save's last read of the hub
    /// runs.</summary>
    public static KeySaveLook? Of(bool? done, bool warned, bool busy, bool saving)
    {
        if (done is null) return saving ? KeySaveLook.Goes : null;
        if (done.Value && !warned) return KeySaveLook.Saved;
        return busy || saving ? KeySaveLook.Goes : KeySaveLook.Failed;
    }
}

/// <summary>**The card around a key save** (the Mac's <c>KeySaveCard</c>): what it draws for its form's look, and when the
/// folded card takes its place.</summary>
public sealed class KeySaveCard
{
    /// <summary>The form's last look.</summary>
    public KeySaveLook? Look { get; private set; }
    /// <summary>The check of the save drew itself and went quiet: the folded card, which shows the same check, can take its
    /// place.</summary>
    public bool Settled { get; private set; }

    /// <summary>The form's look. A form that went after its save (null) leaves the check where it stands. False: nothing
    /// changed.</summary>
    public bool Take(KeySaveLook? look)
    {
        if (look is null && Look == KeySaveLook.Saved || look == Look) return false;
        Look = look;
        Settled = false;
        return true;
    }

    /// <summary>The check has drawn itself and gone quiet.</summary>
    public void Settle()
    {
        if (Look == KeySaveLook.Saved) Settled = true;
    }

    /// <summary>Done after a failed step or a warning, and every other end of the form.</summary>
    public void End()
    {
        Look = null;
        Settled = false;
    }

    /// <summary>The card is its title and the mark at its end, with no words. A card that he opened stays open.</summary>
    public bool Collapsed(bool expanded) => !expanded && Look is KeySaveLook.Goes or KeySaveLook.Saved;

    /// <summary>The folded card waits: a save runs, a failed step stands with its Try again, or the check still draws.</summary>
    public bool Holds => Look is KeySaveLook.Goes or KeySaveLook.Failed || Look == KeySaveLook.Saved && !Settled;

    /// <summary>The card folds: the request has its answer, he did not open it, and no save holds it.</summary>
    public bool Folds(bool answered, bool expanded) => answered && !expanded && !Holds;

    /// <summary>The form stands in the card: while the request is open, and while the save holds the card. Never on an
    /// answered request once its check settled.</summary>
    public bool ShowsForm(bool open) => open || Holds;
}
