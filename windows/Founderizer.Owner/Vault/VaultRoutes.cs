using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;

namespace Founderizer.Owner.Vault;

/// <summary>The JSON context of the vault's routes and of its small records. The answers are read by hand
/// (<see cref="VaultReading"/> and the receipts), as the Mac's own decoders read them. <see cref="LoginSecret"/> is not in
/// it on purpose: a value has no JSON form but the item that is sealed.</summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    NumberHandling = JsonNumberHandling.Strict,
    GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(JsonDocument))]
[JsonSerializable(typeof(Dictionary<string, string>))]
[JsonSerializable(typeof(Dictionary<string, long>))]
[JsonSerializable(typeof(AddBody))]
[JsonSerializable(typeof(IntakeBody))]
[JsonSerializable(typeof(SignedBody))]
[JsonSerializable(typeof(GrantBody))]
[JsonSerializable(typeof(AnswerBody))]
[JsonSerializable(typeof(RecoveryCopyBody))]
internal sealed partial class VaultJson : JsonSerializerContext;

/// <summary>One salted fingerprint of a body.</summary>
internal sealed record PrintBody(string Kind, string Hash, int Len);

/// <summary>The body of POST /ui/secrets/add: no value and no salt is in it. <c>env</c> for an API key only, and
/// <c>address</c> too.</summary>
internal sealed record AddBody(string Login, string Title, string Kind, IReadOnlyList<PrintBody> Fingerprints, string? Env, string? Address);

/// <summary>The body of POST /ui/vault/intake: the sealed copy, and the owner's signed replace of a value, both or neither.</summary>
internal sealed record IntakeBody(string Login, string Ciphertext, string? Statement, string? Signature);

/// <summary>The body of POST /ui/vault/pin, /recovery and /grant: one statement and the owner's signature of it.</summary>
internal sealed record SignedBody(string Statement, string Signature);

/// <summary>The body of POST /ui/secrets/grant: a null <c>grant</c> takes the grant back, so it is always there.</summary>
internal sealed record GrantBody(string Login, string Agent, [property: JsonIgnore(Condition = JsonIgnoreCondition.Never)] string? Grant);

/// <summary>The body of POST /ui/needs/&lt;id&gt;/secret: one of <c>login</c>, <c>decline</c> and <c>clarify</c>.</summary>
internal sealed record AnswerBody(string? Login, string? Decline, string? Note, string? Clarify);

/// <summary>The body of POST /ui/owner/devices/&lt;device&gt;/recovery.</summary>
internal sealed record RecoveryCopyBody(string Sealed);

/// <summary>What the vault's core needs of the store: the calls of the owner's computer, and what it last read of the
/// hub. The window gives the store's (<see cref="VaultCalls.Of"/>), a test a stand-in.</summary>
public interface IVaultCalls
{
    Uri? Hub { get; }
    /// <summary>The generation of the reading that the app shows.</summary>
    string? Database { get; }
    /// <summary>The app's reading is current, so a control writes now (the Mac's <c>writesNow</c>).</summary>
    bool WritesNow { get; }
    /// <summary>The hub's <c>ui_features</c>.</summary>
    IReadOnlyList<string> Features { get; }
    IReadOnlyList<OwnerNeed> Needs { get; }
    /// <summary>The workers and the leads, in the hub's order: the rows of "Who can use it".</summary>
    IReadOnlyList<string> Holders { get; }
    /// <summary>This PC's clock.</summary>
    DateTimeOffset Now { get; }
    Task<OwnerAnswer<JsonDocument>> GetAsync(string route, IReadOnlyList<(string Name, string Value)>? query, int limit, CancellationToken cancel);
    Task<OwnerAnswer<JsonDocument>> PostAsync<TBody>(string route, TBody body, JsonTypeInfo<TBody> type, Guid requestId, CancellationToken cancel);
    /// <summary>The app reads the fleet again.</summary>
    Task RefreshAsync();

    /// <summary>**These calls, held to the place that they show now**: each one goes with that hub's key and that
    /// generation, and none goes once the store shows another hub or generation, also when the store moves between the
    /// check and the send. A form takes them as it opens. Calls whose place cannot change between a check and a send (a
    /// test's stand-in) give themselves.</summary>
    IVaultCalls Held() => this;
}

/// <summary>The calls of an <see cref="OwnerStore"/> as the owner's computer.</summary>
public static class VaultCalls
{
    public static IVaultCalls Of(OwnerStore store) => new StoreCalls(store);

    private sealed class StoreCalls(OwnerStore store) : IVaultCalls
    {
        public Uri? Hub => store.State.Hub;
        public string? Database => store.State.Fleet?.Db;
        public bool WritesNow => store.State.AnswersWrites(Now);
        public IReadOnlyList<string> Features => store.State.Fleet?.UiFeatures ?? [];
        public IReadOnlyList<OwnerNeed> Needs => store.State.Fleet?.Needs ?? [];
        public IReadOnlyList<string> Holders =>
            store.State.Fleet?.Agents.Where(a => a.Role is "worker" or "lead").Select(a => a.Name).ToList() ?? [];
        public DateTimeOffset Now => DateTimeOffset.UtcNow;

        public Task<OwnerAnswer<JsonDocument>> GetAsync(string route, IReadOnlyList<(string Name, string Value)>? query, int limit,
                                                        CancellationToken cancel) =>
            store.OwnerGetAsync(route, VaultJson.Default.JsonDocument, query, limit, cancel);

        public Task<OwnerAnswer<JsonDocument>> PostAsync<TBody>(string route, TBody body, JsonTypeInfo<TBody> type, Guid requestId,
                                                                CancellationToken cancel) =>
            store.OwnerPostAsync(route, body, type, VaultJson.Default.JsonDocument, requestId, cancel);

        public Task RefreshAsync() => store.RefreshAsync();

        public IVaultCalls Held() => store.Call() is { } call ? new HeldCalls(store, call) : this;
    }

    /// <summary>The store's calls held to one <see cref="OwnerCall"/>: a call goes only while the store's own call is of the
    /// same hub and generation, and it goes as that very call, read once for the check and the send.</summary>
    private sealed class HeldCalls(OwnerStore store, OwnerCall held) : IVaultCalls
    {
        public Uri? Hub => store.State.Hub;
        public string? Database => store.State.Fleet?.Db;
        public bool WritesNow => store.State.AnswersWrites(Now);
        public IReadOnlyList<string> Features => store.State.Fleet?.UiFeatures ?? [];
        public IReadOnlyList<OwnerNeed> Needs => store.State.Fleet?.Needs ?? [];
        public IReadOnlyList<string> Holders =>
            store.State.Fleet?.Agents.Where(a => a.Role is "worker" or "lead").Select(a => a.Name).ToList() ?? [];
        public DateTimeOffset Now => DateTimeOffset.UtcNow;

        public Task<OwnerAnswer<JsonDocument>> GetAsync(string route, IReadOnlyList<(string Name, string Value)>? query, int limit,
                                                        CancellationToken cancel) =>
            Same() is { } call ? store.OwnerGetAsync(call, route, VaultJson.Default.JsonDocument, query, limit, cancel)
                               : Task.FromResult(OwnerAnswer<JsonDocument>.GenerationChanged);

        public Task<OwnerAnswer<JsonDocument>> PostAsync<TBody>(string route, TBody body, JsonTypeInfo<TBody> type, Guid requestId,
                                                                CancellationToken cancel) =>
            Same() is { } call ? store.OwnerPostAsync(call, route, body, type, VaultJson.Default.JsonDocument, requestId, cancel)
                               : Task.FromResult(OwnerAnswer<JsonDocument>.GenerationChanged);

        public Task RefreshAsync() => store.RefreshAsync();

        public IVaultCalls Held() => this;

        /// <summary>The store's call now, when it is of the held hub and generation: the one that goes.</summary>
        private OwnerCall? Same() => store.Call() is { } now && now.Hub == held.Hub && now.Database == held.Database ? now : null;
    }
}

/// <summary>**The calls of one hub and one generation**, for a form that was opened there: each call asks first that the
/// store still shows them, and no call goes out otherwise. The store gives its calls with the hub and the generation that it
/// shows at that moment, so a save whose owner changed the hub meanwhile would go on at the other one.</summary>
internal sealed class CallsOfOnePlace(IVaultCalls calls, Uri? hub, string? database) : IVaultCalls
{
    public Uri? Hub => calls.Hub;
    public string? Database => calls.Database;
    public bool WritesNow => calls.WritesNow;
    public IReadOnlyList<string> Features => calls.Features;
    public IReadOnlyList<OwnerNeed> Needs => calls.Needs;
    public IReadOnlyList<string> Holders => calls.Holders;
    public DateTimeOffset Now => calls.Now;

    public Task<OwnerAnswer<JsonDocument>> GetAsync(string route, IReadOnlyList<(string Name, string Value)>? query, int limit, CancellationToken cancel) =>
        Moved ? Task.FromResult(OwnerAnswer<JsonDocument>.GenerationChanged) : calls.GetAsync(route, query, limit, cancel);

    public Task<OwnerAnswer<JsonDocument>> PostAsync<TBody>(string route, TBody body, JsonTypeInfo<TBody> type, Guid requestId, CancellationToken cancel) =>
        Moved ? Task.FromResult(OwnerAnswer<JsonDocument>.GenerationChanged) : calls.PostAsync(route, body, type, requestId, cancel);

    public Task RefreshAsync() => calls.RefreshAsync();

    private bool Moved => hub is null || database is null || calls.Hub != hub || calls.Database != database;
}

/// <summary>The receipt of POST /ui/secrets/grant, as far as the form reads it: the hub changed the grant, and the agent's
/// vault access when the grant had something to do with it.</summary>
public sealed record GrantReceipt(string Agent, SecretGrant? Grant, bool Changed, VaultAccess? Vault);

/// <summary>An agent's vault access after a grant: turned on (<c>broker</c>), or still off with the codes of why.</summary>
public sealed record VaultAccess(string Before, string After, IReadOnlyList<string> Missing);

/// <summary>**The routes of the vault and of the secrets**, as the Mac's <c>VaultClient</c>, <c>SecretsClient</c> and
/// <c>HubClient.secretSalts</c> call them: each write goes at once and is never kept in the outbox, because the hub's
/// receipt is the record, and each answer is checked to be the one of this request. A changed generation is the hub's own
/// refusal of it, so a caller has one way to meet a refusal. No body holds a value: a value goes only as a copy that is
/// sealed to the central vault.</summary>
public static class VaultRoutes
{
    /// <summary>The owner features.</summary>
    public const string CentralVaultFeature = "central_vault", ReplaceFeature = "secret_replace", KeyTableFeature = "key_table",
                        NotesFeature = "secret_notes", ClarifyFeature = "secret_clarify", SecretsFeature = "secrets",
                        GrantsFeature = "secret_grants";

    /// <summary>The Mac's cap of its reads of the vault and of the secrets.</summary>
    public const int ReadLimit = 1_048_576;
    private const int StatementMost = 1024;

    /// <summary>GET /ui/vault, or null from a hub that does not serve it (404): that hub has no central vault.</summary>
    public static async Task<VaultReading?> ReadingAsync(IVaultCalls calls, CancellationToken cancel = default)
    {
        var database = Database(calls);
        JsonDocument answer;
        try
        {
            answer = await GetAsync(calls, "ui/vault", null, ReadLimit, cancel).ConfigureAwait(false);
        }
        catch (HubException e) when (e is { Kind: HubErrorKind.Refusal, Status: 404 })
        {
            return null;
        }
        using (answer)
        {
            return VaultReading.Read(answer.RootElement) is { } reading && reading.Db == database
                ? reading : throw HubException.InvalidResponse("GET /ui/vault", "the answer is no reading of this generation's vault");
        }
    }

    /// <summary>GET /ui/secrets/salts: the salts for the fingerprints of one login reference.</summary>
    public static async Task<SecretSalts> SaltsAsync(IVaultCalls calls, string reference, CancellationToken cancel = default)
    {
        if (!VaultIds.IsReference(reference)) throw new ArgumentException("not a login reference", nameof(reference));
        using var answer = await GetAsync(calls, "ui/secrets/salts", [("login", reference)], ReadLimit, cancel).ConfigureAwait(false);
        return SecretSalts.Read(answer.RootElement) is { IsValid: true } salts && salts.Login == reference
            ? salts : throw HubException.InvalidResponse("GET /ui/secrets/salts", "the answer holds no salts of this reference");
    }

    /// <summary>GET /ui/team: the lines (an agent's machine) and the catalog of the secrets, or a null catalog from a hub
    /// that gives none.</summary>
    public static async Task<(TeamReading Team, Dictionary<string, CatalogEntry>? Catalog)> TeamAsync(IVaultCalls calls,
                                                                                                        CancellationToken cancel = default)
    {
        const string read = "GET /ui/team";
        var database = Database(calls);
        using var answer = await GetAsync(calls, "ui/team", null, OwnerReads.TeamLimit, cancel).ConfigureAwait(false);
        try
        {
            var team = answer.RootElement.Deserialize(ReadsJson.Default.TeamReading) ?? throw HubException.InvalidResponse(read, "no answer");
            if (team.Problem(database) is { } why) throw HubException.InvalidResponse(read, why);
            return (team, CatalogEntry.Read(answer.RootElement));
        }
        catch (Exception e) when (e is JsonException or FormatException)
        {
            throw HubException.InvalidResponse(read, e.Message, e);
        }
    }

    /// <summary>**The hub's clock and this PC's, read now** (GET /ui/state?head=1, owner API 1.256). The Mac compares the
    /// clock of its last read of the state, which is seconds old. This PC's own reading of the fleet can be old: the hub
    /// answers 304 while nothing changes, and a kept reading of an earlier start has the clocks of that time.</summary>
    public static async Task<HubClock> ClockAsync(IVaultCalls calls, CancellationToken cancel = default)
    {
        var database = Database(calls);
        using var answer = await GetAsync(calls, "ui/state", [("head", "1")], HubClient.OwnerReadLimit, cancel).ConfigureAwait(false);
        return Lossy.Text(answer.RootElement, "db") == database && Lossy.Number(answer.RootElement, "time") is { } time
            ? new HubClock(time, calls.Now.ToUnixTimeMilliseconds() / 1000.0)
            : throw HubException.InvalidResponse("GET /ui/state?head=1", "the answer is no head of this generation's state");
    }

    /// <summary>POST /ui/secrets/add: the fingerprints of a made item, then its catalog entry, in one command.</summary>
    public static async Task AddAsync(IVaultCalls calls, string reference, string title, SecretKind kind, string? variable, string? address,
                                      IReadOnlyList<SecretFingerprint> fingerprints, Guid requestId, CancellationToken cancel = default)
    {
        const string write = "POST /ui/secrets/add";
        title = FoundationText.Trim(title);
        if (!VaultIds.IsReference(reference) || SecretRequest.CodePoints(title) is < 1 or > LoginSecret.MaxLabel ||
            title.Any(FoundationText.IsNewline) || (kind == SecretKind.ApiKey) != (variable is not null) ||
            variable is not null && (!LoginSecret.IsVariable(variable) || LoginSecret.IsReserved(variable)) ||
            fingerprints.Count > 0 && !SecretFingerprint.AreValid(fingerprints) ||
            address is not null && (kind != SecretKind.ApiKey || !IsTableAddress(address)))
            throw new ArgumentException("the entry is of no valid shape");
        var body = new AddBody(reference, title, kind.Word(), fingerprints.Select(f => new PrintBody(f.Kind, f.Hash, f.Len)).ToList(), variable, address);
        using var answer = await PostAsync(calls, "ui/secrets/add", body, VaultJson.Default.AddBody, requestId, cancel).ConfigureAwait(false);
        var receipt = answer.RootElement;
        if (Lossy.Text(receipt, "login") != reference || Lossy.Whole(receipt, "stored") is not { } stored || stored < 0 ||
            Lossy.Whole(receipt, "known") is not { } known || known < 0 || stored + known != fingerprints.Count ||
            Lossy.Field(receipt, "changed") is not { ValueKind: JsonValueKind.True or JsonValueKind.False })
            throw HubException.InvalidResponse(write, "the answer is not the receipt of this entry");
    }

    /// <summary>POST /ui/vault/intake: the value of a secret of the catalog, sealed to the central vault's key. With
    /// <paramref name="signed"/>, the owner's signed replace of the value under a reference that the vault holds.</summary>
    public static async Task IntakeAsync(IVaultCalls calls, string reference, string sealedCopy, (string Statement, string Signature)? signed,
                                         Guid requestId, CancellationToken cancel = default)
    {
        if (!VaultIds.IsReference(reference) || !AgeSeal.IsSealed(sealedCopy) || sealedCopy.Length > AgeSeal.MaxCopy)
            throw new ArgumentException("not a sealed copy for a reference");
        if (signed is { } pair) CheckSigned(pair.Statement, pair.Signature);
        using var answer = await PostAsync(calls, "ui/vault/intake", new IntakeBody(reference, sealedCopy, signed?.Statement, signed?.Signature),
                                           VaultJson.Default.IntakeBody, requestId, cancel).ConfigureAwait(false);
        if (Lossy.Text(answer.RootElement, "login") != reference)
            throw HubException.InvalidResponse("POST /ui/vault/intake", "the answer is not the receipt of this reference");
    }

    /// <summary>A pin (or an unpin) of one server's vault key, signed by the owner (POST /ui/vault/pin).</summary>
    public static Task PinAsync(IVaultCalls calls, string statement, string signature, Guid requestId, CancellationToken cancel = default) =>
        SignedAsync(calls, "ui/vault/pin", statement, signature, requestId, cancel);

    /// <summary>The recovery key the central vault seals its backup to, signed by the owner (POST /ui/vault/recovery).</summary>
    public static Task RecoveryAsync(IVaultCalls calls, string statement, string signature, Guid requestId, CancellationToken cancel = default) =>
        SignedAsync(calls, "ui/vault/recovery", statement, signature, requestId, cancel);

    /// <summary>A grant of one secret to one agent, its end, or the secret into the pool or out of it, signed by the owner
    /// (POST /ui/vault/grant, owner feature <c>signed_grants</c>).</summary>
    public static Task SignedGrantAsync(IVaultCalls calls, string statement, string signature, Guid requestId, CancellationToken cancel = default) =>
        SignedAsync(calls, "ui/vault/grant", statement, signature, requestId, cancel);

    /// <summary>The recovery code, sealed to one phone's own recovery key (<see cref="RecoverySeal"/>, POST
    /// /ui/owner/devices/&lt;device&gt;/recovery, owner feature <c>recovery_copy</c>).</summary>
    public static async Task RecoveryCopyAsync(IVaultCalls calls, string device, string sealedCode, Guid requestId, CancellationToken cancel = default)
    {
        if (!VaultIds.IsDevice(device))
            throw new ArgumentException("not a device's name", nameof(device));
        using var answer = await PostAsync(calls, $"ui/owner/devices/{device}/recovery", new RecoveryCopyBody(sealedCode),
                                           VaultJson.Default.RecoveryCopyBody, requestId, cancel).ConfigureAwait(false);
    }

    /// <summary>POST /ui/secrets/grant: one agent's grant of one secret; null takes it back.</summary>
    public static async Task<GrantReceipt> GrantAsync(IVaultCalls calls, string reference, string agent, SecretGrant? grant, Guid requestId,
                                                      CancellationToken cancel = default)
    {
        if (!VaultIds.IsReference(reference) || !VaultIds.IsAgent(agent)) throw new ArgumentException("not a reference or an agent");
        using var answer = await PostAsync(calls, "ui/secrets/grant", new GrantBody(reference, agent, grant?.Word()),
                                           VaultJson.Default.GrantBody, requestId, cancel).ConfigureAwait(false);
        var receipt = answer.RootElement;
        if (Lossy.Text(receipt, "login") != reference || Lossy.Text(receipt, "agent") != agent || Lossy.Text(receipt, "grant") != grant?.Word() ||
            Lossy.Field(receipt, "changed") is not { ValueKind: JsonValueKind.True or JsonValueKind.False } changed)
            throw HubException.InvalidResponse("POST /ui/secrets/grant", "the answer is not the receipt of this grant");
        VaultAccess? vault = null;
        if (Lossy.Field(receipt, "vault") is { } access)
            vault = Lossy.Text(access, "before") is { } before && Lossy.Text(access, "after") is { } after
                ? new VaultAccess(before, after, Lossy.Texts(access, "missing") ?? [])
                : throw HubException.InvalidResponse("POST /ui/secrets/grant", "the vault access is of no valid shape");
        return new GrantReceipt(agent, grant, changed.GetBoolean(), vault);
    }

    /// <summary>The answer of one secret request with a secret of the catalog (POST /ui/needs/&lt;id&gt;/secret). The same
    /// <paramref name="requestId"/> again gives the same answer, so a retry after no reply is safe.</summary>
    public static Task AnswerAsync(IVaultCalls calls, long need, string reference, string? note, Guid requestId, CancellationToken cancel = default)
    {
        if (!VaultIds.IsReference(reference)) throw new ArgumentException("not a login reference", nameof(reference));
        note = note is null ? null : FoundationText.TrimBlanks(note);
        if (note is not null && (SecretRequest.NoteLength(note) > SecretRequest.NoteMost || note.Any(FoundationText.IsNewline)))
            throw new ArgumentException("the note is too long or not one line", nameof(note));
        return NeedAsync(calls, need, new AnswerBody(reference, null, note, null), requestId, cancel);
    }

    /// <summary>The owner says no to one secret request, with no words (the Mac's Decline).</summary>
    public static Task DeclineAsync(IVaultCalls calls, long need, Guid requestId, CancellationToken cancel = default) =>
        NeedAsync(calls, need, new AnswerBody(null, "", null, null), requestId, cancel);

    /// <summary>**Needs clarification** (owner feature <c>secret_clarify</c>): the owner's words about one secret request, in
    /// place of an answer. They close it and go to the agent that asked.</summary>
    public static Task ClarifyAsync(IVaultCalls calls, long need, string words, Guid requestId, CancellationToken cancel = default)
    {
        words = FoundationText.Trim(words);
        if (words.Length == 0 || SecretRequest.CodePoints(words) > SecretRequest.ClarifyMost) throw new ArgumentException("no words, or too many", nameof(words));
        return NeedAsync(calls, need, new AnswerBody(null, null, null, words), requestId, cancel);
    }

    /// <summary>The address that a save sends with a secret: only to a hub that names <c>key_table</c>, only for an API
    /// key, and with no path, no query and no fragment.</summary>
    public static string? AddressFor(LoginSecret secret, IReadOnlyList<string> features) =>
        features.Contains(KeyTableFeature) ? secret.TableAddress : null;

    /// <summary>An address that a command carries: an https address of a host and an optional port only.</summary>
    private static bool IsTableAddress(string address) =>
        WebAddress.Parse(address) is { Scheme: "https", HasUser: false, AsciiHost: { Length: > 0 } host } parts &&
        address == "https://" + host + (parts.Port is { } port ? ":" + port : "");

    /// <summary>The Mac's shape of a signed statement: one line of at most 1024 bytes, and the base64 of a DER signature.</summary>
    private static void CheckSigned(string statement, string signature)
    {
        if (statement.Length == 0 || Encoding.UTF8.GetByteCount(statement) > StatementMost || statement.Any(FoundationText.IsNewline) ||
            !Base64Strict.TryDecode(signature, out var der) || der.Length is < 8 or > 80)
            throw new ArgumentException("not a signed statement");
    }

    private static async Task SignedAsync(IVaultCalls calls, string route, string statement, string signature, Guid requestId, CancellationToken cancel)
    {
        CheckSigned(statement, signature);
        using var answer = await PostAsync(calls, route, new SignedBody(statement, signature), VaultJson.Default.SignedBody, requestId, cancel)
            .ConfigureAwait(false);
    }

    private static async Task NeedAsync(IVaultCalls calls, long need, AnswerBody body, Guid requestId, CancellationToken cancel)
    {
        var route = $"ui/needs/{need}/secret";
        using var answer = await PostAsync(calls, route, body, VaultJson.Default.AnswerBody, requestId, cancel).ConfigureAwait(false);
        if (Lossy.Whole(answer.RootElement, "need") != need || Lossy.Text(answer.RootElement, "login") != body.Login)
            throw HubException.InvalidResponse("POST /" + route, "the answer is not the receipt of this request");
    }

    private static string Database(IVaultCalls calls) =>
        calls.Database ?? throw new InvalidOperationException("no generation of the hub is read yet");

    private static async Task<JsonDocument> GetAsync(IVaultCalls calls, string route, IReadOnlyList<(string, string)>? query, int limit, CancellationToken cancel) =>
        (await calls.GetAsync(route, query, limit, cancel).ConfigureAwait(false)).Value ?? throw Changed();

    /// <summary>One write, whose answer must be the receipt of this very request.</summary>
    private static async Task<JsonDocument> PostAsync<TBody>(IVaultCalls calls, string route, TBody body, JsonTypeInfo<TBody> type, Guid requestId,
                                                             CancellationToken cancel)
    {
        var answer = (await calls.PostAsync(route, body, type, requestId, cancel).ConfigureAwait(false)).Value ?? throw Changed();
        if (Lossy.True(answer.RootElement, "ok") &&
            string.Equals(Lossy.Text(answer.RootElement, "request_id"), requestId.ToString("D"), StringComparison.OrdinalIgnoreCase))
            return answer;
        answer.Dispose();
        throw HubException.InvalidResponse("POST /" + route, "the answer is not the receipt of this request");
    }

    /// <summary>The hub's refusal of a generation that changed, with the Mac's English of its code.</summary>
    private static HubException Changed() => HubException.Refusal(409, null, "hub generation changed; refresh state", "hub_changed");
}
