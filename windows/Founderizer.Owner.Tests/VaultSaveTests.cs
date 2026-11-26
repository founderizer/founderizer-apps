using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Vault;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Owner.Tests;

/// <summary>**The save of a secret, the owner's signatures and their order** (piece L5), over a stand-in of the hub that
/// keeps each request in its order.</summary>
[TestClass]
public sealed class VaultSaveTests
{
    private const string Fleet = "0123456789abcdef", Held = "bws://00000003-0000-4000-8000-000000000003", Key = "sk-test-0123456789abcdefghij";
    private static readonly double HubTime = 1_763_700_000;
    private static readonly string VaultKey = Recipient(1), Recovery = Recipient(2), Other = Recipient(3);

    private static string Recipient(byte n) =>
        AgeSeal.Bech32("age", new Org.BouncyCastle.Crypto.Parameters.X25519PrivateKeyParameters(Enumerable.Repeat(n, 32).ToArray()).GeneratePublicKey().GetEncoded());

    /// <summary>An owner key that counts its signatures and writes each into the hub's log.</summary>
    private sealed class CountingKey(Hub hub) : IOwnerKey
    {
        private readonly SoftwareOwnerKey key = SoftwareOwnerKey.Create();
        public int Signed { get; private set; }
        public string PublicKey => key.PublicKey;

        public string Sign(string statement)
        {
            Signed++;
            using var said = JsonDocument.Parse(statement);
            hub.Log.Add(("SIGN " + said.RootElement.GetProperty("kind").GetString(), default));
            return key.Sign(statement);
        }
    }

    /// <summary>The stand-in of the hub, as the store gives its calls.</summary>
    private sealed class Hub : IVaultCalls
    {
        public List<(string Route, JsonElement Body)> Log { get; } = [];
        public Dictionary<string, Func<JsonElement, HubException?>> Refuse { get; } = [];
        public Uri? Address { get; set; } = new("http://100.64.0.1:8765/");
        Uri? IVaultCalls.Hub => Address;
        public string? Database { get; set; } = "db-1";
        public bool WritesNow { get; set; } = true;
        public IReadOnlyList<string> Features { get; set; } =
            ["secrets", "secret_grants", "central_vault", "signed_grants", "secret_replace", "key_table", "secret_notes", "secret_clarify"];
        public IReadOnlyList<OwnerNeed> Needs { get; set; } = [];
        public IReadOnlyList<string> Holders { get; set; } = ["atlas", "nova"];
        public DateTimeOffset Now { get; set; } = DateTimeOffset.FromUnixTimeSeconds((long)HubTime + 1);
        public string VaultsKey { get; set; } = VaultKey;
        public bool HasRecovery { get; set; } = true;
        public string Logins { get; set; } = "{}";
        public int Refreshes { get; private set; }
        public Action<string>? Before { get; set; }

        public IEnumerable<string> Routes => Log.Select(l => l.Route);
        public List<string> Writes => Log.Where(l => l.Route.StartsWith("POST", StringComparison.Ordinal)).Select(l => l.Route).ToList();
        public JsonElement Body(string route) => Log.Last(l => l.Route == route).Body;

        public Task<OwnerAnswer<JsonDocument>> GetAsync(string route, IReadOnlyList<(string Name, string Value)>? query, int limit, CancellationToken cancel)
        {
            Before?.Invoke("GET " + route);
            Log.Add(("GET " + route, default));
            if (Refuse.TryGetValue("GET " + route, out var refuse) && refuse(default) is { } refused) throw refused;
            var recovery = HasRecovery ? $", \"recovery\": \"{Recovery}\"" : "";
            var answer = route switch
            {
                "ui/vault" => $$"""{"db": "{{Database}}", "fleet": "{{Fleet}}", "machines": [], "held": {}, "central": {"ok": true, "recipient": "{{VaultsKey}}"{{recovery}} } }""",
                "ui/secrets/salts" => $$"""{"login": "{{query!.Single(q => q.Name == "login").Value}}", "password": "{{new string('a', 32)}}", "totp": "{{new string('b', 32)}}"}""",
                "ui/state" => $$"""{"db": "{{Database}}", "time": {{HubTime}}, "head": true}""",
                "ui/team" => $$"""
                    {"db": "{{Database}}", "revision": "{{new string('a', 40)}}", "sha256": "{{new string('b', 64)}}", "open_tasks": {}, "logins": {{Logins}},
                     "lines": [{"agent": "juno", "role": "manager"},
                               {"agent": "atlas", "role": "worker", "reports_to": "juno", "placement": {"machine": "worker-1"} },
                               {"agent": "nova", "role": "worker", "reports_to": "juno"}]}
                    """,
                _ => throw new InvalidOperationException(route),
            };
            return Task.FromResult(new OwnerAnswer<JsonDocument>(JsonDocument.Parse(answer)));
        }

        public Task<OwnerAnswer<JsonDocument>> PostAsync<TBody>(string route, TBody body, JsonTypeInfo<TBody> type, Guid requestId, CancellationToken cancel)
        {
            Before?.Invoke("POST " + route);
            using var parsed = JsonDocument.Parse(JsonSerializer.Serialize(body, type));
            var sent = parsed.RootElement.Clone();
            Log.Add(("POST " + route, sent));
            Ids.Add((route, requestId));
            if (Refuse.TryGetValue("POST " + route, out var refuse) && refuse(sent) is { } refused) throw refused;
            string Quoted(string name) => sent.TryGetProperty(name, out var value) ? value.GetRawText() : "null";
            var need = route.StartsWith("ui/needs/", StringComparison.Ordinal) ? route.Split('/')[2] : "0";
            var prints = sent.TryGetProperty("fingerprints", out var list) ? list.GetArrayLength() : 0;
            return Task.FromResult(new OwnerAnswer<JsonDocument>(JsonDocument.Parse(
                $$"""{"ok": true, "request_id": "{{requestId:D}}", "client": "c", "login": {{Quoted("login")}}, "agent": {{Quoted("agent")}}, "grant": {{Quoted("grant")}}, "changed": true, "stored": {{prints}}, "known": 0, "need": {{need}}, "answer": "x", "saved": "new"}""")));
        }

        public List<(string Route, Guid Id)> Ids { get; } = [];

        public Task RefreshAsync()
        {
            Refreshes++;
            return Task.CompletedTask;
        }
    }

    private sealed class Pins : ICentralVaultPins
    {
        public string? Kept { get; set; } = VaultKey;
        public bool Damaged { get; set; }
        public string? Recipient(Uri hub, string fleet) =>
            Damaged ? throw new InvalidDataException("the pins file does not read") : fleet == Fleet ? Kept : null;
        public string? Pin(string recipient, Uri hub, string fleet, bool setUp) => throw new InvalidOperationException("no form pins");
    }

    private static readonly HubException Busy = HubException.Refusal(503, null, "the central vault does not answer");

    private static OwnerNeed Request(long id, string secret)
    {
        using var json = JsonDocument.Parse(secret);
        return new OwnerNeed(id, "A key", "why", "todo", 1, "atlas", Kind: "secret", RawSecret: json.RootElement.Clone());
    }

    private static (SecretForm Form, Hub Hub, CountingKey Key, Pins Pins) Make(SecretPreset? preset = null, Hub? hub = null, Func<string, IOwnerKey?>? owner = null,
                                                                               Func<string, string, Task<bool>>? say = null)
    {
        hub ??= new Hub();
        var key = new CountingKey(hub);
        var pins = new Pins();
        var signing = new VaultSigning(hub, owner ?? (fleet => fleet == Fleet ? key : null), new MemoryClock());
        return (new SecretForm(preset ?? new SecretPreset(), hub, pins, signing, words => words.Contains("sk-", StringComparison.Ordinal), a => a, say), hub, key, pins);
    }

    private static void Type(SecretForm form) => form.Edit(l => { l.Env = "EXAMPLE_KEY"; l.Password = Key; l.Url = "https://api.example.com/v1/secret-path"; });

    // ---------------------------------------------------------------- the seal and the signatures

    /// <summary>**A seal is refused when the vault's key is not the pinned one**: the hub names another key, this PC pinned
    /// none, its pins file does not read, or the hub serves no vault. Nothing is sent, and nothing is sealed. A vault with no
    /// recovery key opens the form as the Mac's does: the hub decides (a vault with the list of the owner's devices takes
    /// none) and refuses a save that it does not take. Bug: a hub that is broken into names a key of its own, and the
    /// owner's next key is sealed to the attacker; or a form of a vault with a device list that stays closed.</summary>
    [TestMethod]
    public async Task A_seal_is_refused_when_the_vaults_key_is_not_the_pinned_one()
    {
        foreach (var spoil in new Action<Hub, Pins>[]
                 {
                     (hub, _) => hub.VaultsKey = Other, (_, pins) => pins.Kept = null, (_, pins) => pins.Damaged = true,
                     (hub, _) => hub.Features = hub.Features.Where(f => f != "central_vault").ToList(),
                 })
        {
            var (form, hub, key, pins) = Make();
            spoil(hub, pins);
            Type(form);
            await form.StartAsync();
            Assert.IsNull(form.Central);
            Assert.AreEqual(SecretFormPhase.NoVault, form.Phase);
            await form.SaveAsync();
            Assert.AreEqual(0, hub.Writes.Count);
            Assert.AreEqual(0, key.Signed);
            Assert.AreEqual(Key, form.Login.Password, "the fields keep what was typed");
        }
        var (good, _, _, _) = Make();
        await good.StartAsync();
        Assert.AreEqual(VaultKey, good.Central, "and with the pinned key the form saves");
        var (listed, noRecovery, _, _) = Make();
        noRecovery.HasRecovery = false;
        await listed.StartAsync();
        Assert.AreEqual(VaultKey, listed.Central, "a vault with no recovery key: the hub decides");
    }

    /// <summary>**No statement is signed while the clocks differ by more than an hour**: not a give, not a <c>pool</c> and not
    /// a replace, in either direction, and nothing is sent. An end does not wait for the clock. Bug: a PC with a wrong clock
    /// dates a grant ahead, and the vault refuses the owner's next change of it for a day.</summary>
    [TestMethod]
    public async Task No_statement_is_signed_while_the_clocks_differ_by_more_than_an_hour()
    {
        foreach (var seconds in new[] { -3601, 3601 })
        {
            var hub = new Hub { Now = DateTimeOffset.FromUnixTimeSeconds((long)HubTime + seconds) };
            var key = new CountingKey(hub);
            var signing = new VaultSigning(hub, _ => key, new MemoryClock());
            foreach (var act in new Func<Task>[]
                     {
                         () => signing.GrantAsync(SecretGrant.Use, Held, "atlas", "Atlas"), () => signing.PoolAsync(true, Held),
                         () => signing.ReplaceAsync(Held, "a sealed copy"), () => SecretAccess.ChangeAsync(hub, signing, Held, "atlas", "Atlas", SecretGrant.Read),
                     })
            {
                var stop = await Assert.ThrowsExactlyAsync<SignStop>(act);
                Assert.AreEqual(VaultPlan.ClockWords, stop.Message);
            }
            Assert.AreEqual(0, key.Signed);
            Assert.AreEqual(0, hub.Writes.Count);
            await signing.GrantAsync(null, Held, "atlas", "Atlas");
            await signing.PoolAsync(false, Held);
            Assert.AreEqual(2, key.Signed, "an end only narrows, so it does not wait");
        }
        var near = new Hub { Now = DateTimeOffset.FromUnixTimeSeconds((long)HubTime + 3600) };
        var good = new CountingKey(near);
        await new VaultSigning(near, _ => good, new MemoryClock()).GrantAsync(SecretGrant.Use, Held, "atlas", "Atlas");
        Assert.AreEqual(1, good.Signed, "an hour itself is no stop");
    }

    /// <summary>**The clock is read at the hub for each signature that waits for it**, and a hub that does not say its time
    /// signs nothing. Bug: a reading of an earlier start, which the hub answers with 304 for as long as nothing changes, and a
    /// clock that went wrong since.</summary>
    [TestMethod]
    public async Task A_hub_that_does_not_say_its_time_now_signs_nothing()
    {
        var (_, hub, key, _) = Make();
        hub.Refuse["GET ui/state"] = _ => HubException.NoAnswer();
        var signing = new VaultSigning(hub, _ => key, new MemoryClock());
        await Assert.ThrowsExactlyAsync<HubException>(() => signing.GrantAsync(SecretGrant.Use, Held, "atlas", "Atlas"));
        Assert.AreEqual(0, key.Signed);
        Assert.AreEqual(0, hub.Writes.Count);
    }

    /// <summary>**A grant is signed before its route, and an ungrant after it.** So the vault's signed grants always include
    /// the hub's. A give that this PC cannot sign never reaches the hub's grant, and a take-back that the hub refused ends no
    /// signed grant. Bug: the hub's list says that an agent has a key, and the vault never seals it for that agent; or the
    /// vault's grant goes and the list still has it.</summary>
    [TestMethod]
    public async Task A_grant_is_signed_before_its_route_and_an_ungrant_after_it()
    {
        var (_, hub, key, _) = Make();
        var signing = new VaultSigning(hub, _ => key, new MemoryClock());
        await SecretAccess.ChangeAsync(hub, signing, Held, "atlas", "Atlas", SecretGrant.Read);
        List<string> Steps() => hub.Routes.Where(r => r.StartsWith("SIGN", StringComparison.Ordinal) || r.StartsWith("POST", StringComparison.Ordinal)).ToList();
        CollectionAssert.AreEqual(new[] { "SIGN grant", "POST ui/vault/grant", "POST ui/secrets/grant" }, Steps());
        using (var said = JsonDocument.Parse(hub.Body("POST ui/vault/grant").GetProperty("statement").GetString()!))
        {
            Assert.AreEqual("worker-1", said.RootElement.GetProperty("machine").GetString(), "the machine that the hub names for the agent");
            Assert.AreEqual(Fleet, said.RootElement.GetProperty("fleet").GetString());
        }
        Assert.AreEqual("read", hub.Body("POST ui/secrets/grant").GetProperty("grant").GetString());
        hub.Log.Clear();
        await SecretAccess.ChangeAsync(hub, signing, Held, "atlas", "Atlas", null);
        CollectionAssert.AreEqual(new[] { "POST ui/secrets/grant", "SIGN ungrant", "POST ui/vault/grant" }, Steps());
        Assert.AreEqual(JsonValueKind.Null, hub.Body("POST ui/secrets/grant").GetProperty("grant").ValueKind, "a null grant is there: without it the hub takes nothing back");

        hub.Log.Clear();
        var unsigned = new VaultSigning(hub, _ => null, new MemoryClock());
        var stop = await Assert.ThrowsExactlyAsync<SignStop>(() => SecretAccess.ChangeAsync(hub, unsigned, Held, "atlas", "Atlas", SecretGrant.Use));
        Assert.AreEqual(VaultWords.NoOwnerKey, stop.Message);
        stop = await Assert.ThrowsExactlyAsync<SignStop>(() => SecretAccess.ChangeAsync(hub, signing, Held, "nova", "Nova", SecretGrant.Use));
        Assert.AreEqual(VaultWords.NoServer("Nova"), stop.Message);
        Assert.AreEqual(0, hub.Writes.Count, "no give that is not signed reaches the hub's grant");

        hub.Refuse["POST ui/secrets/grant"] = _ => Busy;
        hub.Log.Clear();
        await Assert.ThrowsExactlyAsync<HubException>(() => SecretAccess.ChangeAsync(hub, signing, Held, "atlas", "Atlas", null));
        CollectionAssert.AreEqual(new[] { "POST ui/secrets/grant" }, Steps(), "and a take-back that the hub refused ends no signed grant");
    }

    // ---------------------------------------------------------------- the save

    /// <summary>**A save sends the value only sealed, and the form lets it go once the hub has the reference**: the order of
    /// the steps, the fingerprints that the vault makes again, the table's address with no path, the signed grant and the
    /// answer. Bug: the key in a body, or a key that stays in the form's memory after the save.</summary>
    [TestMethod]
    public async Task A_save_sends_the_value_only_sealed_and_lets_it_go()
    {
        var hub = new Hub { Needs = [Request(7, """{"kind": "api_key", "env": "EXAMPLE_KEY", "site": "https://api.example.com/v1/secret-path", "give": {"atlas": "read"}}""")] };
        var (form, _, key, _) = Make(SecretPreset.Of(hub.Needs[0]), hub);
        await form.StartAsync();
        form.Edit(l => l.Password = Key);
        byte[]? item = form.Login.Value();
        await form.SaveAsync();
        CollectionAssert.AreEqual(new[] { "POST ui/secrets/add", "POST ui/vault/intake", "POST ui/vault/grant", "POST ui/secrets/grant", "POST ui/needs/7/secret" },
                                  hub.Writes);
        foreach (var (route, body) in hub.Log.Where(l => l.Body.ValueKind == JsonValueKind.Object))
            Assert.IsFalse(body.GetRawText().Contains(Key, StringComparison.Ordinal) || body.GetRawText().Contains("secret-path", StringComparison.Ordinal), route);
        var add = hub.Body("POST ui/secrets/add");
        Assert.AreEqual("https://api.example.com", add.GetProperty("address").GetString(), "a path can be a secret");
        Assert.AreEqual("EXAMPLE_KEY", add.GetProperty("env").GetString());
        var salts = new SecretSalts(add.GetProperty("login").GetString()!, new string('a', 32), new string('b', 32));
        var print = SecretFingerprint.Of(item, salts).Single();
        Assert.AreEqual(print.Hash, add.GetProperty("fingerprints")[0].GetProperty("hash").GetString());
        Assert.AreEqual(Key.Length, add.GetProperty("fingerprints")[0].GetProperty("len").GetInt32());
        var intake = hub.Body("POST ui/vault/intake");
        Assert.IsTrue(AgeSeal.IsSealed(intake.GetProperty("ciphertext").GetString()!));
        Assert.IsFalse(intake.TryGetProperty("statement", out _), "a new secret needs no replace");
        Assert.AreEqual(add.GetProperty("login").GetString(), hub.Body("POST ui/needs/7/secret").GetProperty("login").GetString());
        Assert.AreEqual(1, key.Signed);
        Assert.AreEqual("", form.Login.Password, "the form lets the value go");
        Assert.AreEqual(KeySaveLook.Saved, form.Look);
        Assert.IsTrue(form.Progress!.IsDone && form.Progress.InVault);
        Assert.AreEqual(VaultWords.ReadsFromNextStart("atlas", "EXAMPLE_KEY"), form.Progress.Grants[0].Note);
    }

    /// <summary>**A hub that did not confirm the reference keeps the fields, and Save again goes under the same one**, and a
    /// hub whose vault does not answer (503) takes nothing. Bug: a second entry of one key after a lost answer, or a typed key
    /// that is gone with nothing saved.</summary>
    [TestMethod]
    public async Task A_save_that_the_hub_did_not_confirm_goes_again_under_the_same_reference()
    {
        var (form, hub, _, _) = Make();
        Type(form);
        await form.StartAsync();
        hub.Refuse["POST ui/secrets/add"] = _ => HubException.NoAnswer();
        await form.SaveAsync();
        var first = hub.Body("POST ui/secrets/add").GetProperty("login").GetString();
        Assert.AreEqual(Key, form.Login.Password);
        Assert.AreEqual(SecretFormPhase.Form, form.Phase);
        StringAssert.StartsWith(form.Message, "The hub did not register this secret.");
        // the first entry did reach the catalog: it is this very save, and no other secret of the name
        hub.Logins = $$"""{"{{first}}": {"title": "EXAMPLE_KEY", "kind": "api_key", "env": "EXAMPLE_KEY"} }""";
        hub.Refuse.Clear();
        await form.SaveAsync();
        Assert.AreEqual(first, hub.Body("POST ui/secrets/add").GetProperty("login").GetString());
        Assert.AreEqual(SecretFormPhase.Saved, form.Phase);

        var (busy, down, _, _) = Make();
        Type(busy);
        await busy.StartAsync();
        down.Refuse["POST ui/secrets/add"] = _ => Busy;
        await busy.SaveAsync();
        Assert.AreEqual(SecretFormPhase.NoVault, busy.Phase);
        Assert.AreEqual(Key, busy.Login.Password);
        CollectionAssert.AreEqual(new[] { "POST ui/secrets/add" }, down.Writes);
    }

    /// <summary>**A request for a new value replaces it in one press, with the owner's statement about this very copy**: under
    /// the key's own reference, with its own title and no address, no access step, and the answer of each open request for
    /// that key. Bug: an address from an agent's request that moves where the key goes, an agent that loses the key, or a
    /// copy that the vault cannot tell from another one.</summary>
    [TestMethod]
    public async Task A_new_value_goes_under_the_keys_own_reference_with_the_owners_statement_about_this_copy()
    {
        var asked = """{"kind": "api_key", "env": "EXAMPLE_KEY", "site": "https://evil.example.com", "give": {"atlas": "use"}, "replaces": "HELD"}""".Replace("HELD", Held);
        var hub = new Hub
        {
            Needs = [Request(7, asked), Request(8, asked), Request(9, """{"kind": "api_key", "env": "EXAMPLE_KEY"}""")],
            Logins = $$"""{"{{Held}}": {"title": "EXAMPLE_KEY", "kind": "api_key", "env": "EXAMPLE_KEY", "grants": {"atlas": "read"} } }""",
        };
        var (form, _, key, _) = Make(SecretPreset.Of(hub.Needs[0]), hub);
        await form.StartAsync();
        Assert.AreEqual("", form.Login.Url, "a request for a new value gives no address");
        form.Edit(l => { l.Password = Key; l.Url = "https://typed.example.com"; });
        var bare = SecretValueReplace.Value(form.Login);
        Assert.IsFalse(Encoding.UTF8.GetString(bare).Contains("example.com", StringComparison.Ordinal), "and what is sealed names none, whatever the form holds");
        await form.SaveAsync();
        CollectionAssert.AreEqual(new[] { "POST ui/secrets/add", "POST ui/vault/intake", "POST ui/needs/7/secret", "POST ui/needs/8/secret" }, hub.Writes);
        var add = hub.Body("POST ui/secrets/add");
        Assert.AreEqual(Held, add.GetProperty("login").GetString());
        Assert.IsFalse(add.TryGetProperty("address", out _));
        var intake = hub.Body("POST ui/vault/intake");
        var statement = intake.GetProperty("statement").GetString()!;
        using var said = JsonDocument.Parse(statement);
        Assert.AreEqual("replace", said.RootElement.GetProperty("kind").GetString());
        Assert.AreEqual(OwnerStatement.Checksum(intake.GetProperty("ciphertext").GetString()!), said.RootElement.GetProperty("sha256").GetString());
        Assert.IsTrue(OwnerSignature.Verify(key.PublicKey, statement, intake.GetProperty("signature").GetString()!));
        var before = hub.Routes.ToList();
        Assert.IsTrue(before.IndexOf("SIGN replace") < before.IndexOf("POST ui/secrets/add"), "a PC that cannot sign sends nothing");
    }

    /// <summary>**A replace that this PC cannot sign, or that the vault does not take yet, sends nothing**, and the key of a
    /// name that the list has waits for a second Save, whose line says what it does; two keys of one name, a login of a
    /// title that the list has and a full list each have their own line, and only the second login goes at a second Save.
    /// Bug: new fingerprints registered for a value that the vault never gets, a key that is replaced at the first press, a
    /// second login with no word of the first, or a list that grows past what the hub takes.</summary>
    [TestMethod]
    public async Task A_name_that_the_list_has_waits_for_a_second_save_and_an_unsigned_replace_sends_nothing()
    {
        var hub = new Hub { Logins = $$"""{"{{Held}}": {"title": "EXAMPLE_KEY", "kind": "api_key", "env": "EXAMPLE_KEY", "grants": {"atlas": "read"} } }""" };
        var (form, _, key, _) = Make(hub: hub);
        Type(form);
        await form.StartAsync();
        await form.SaveAsync();
        Assert.AreEqual(VaultWords.Replaces("EXAMPLE_KEY"), form.Message);
        Assert.AreEqual(0, hub.Writes.Count);
        Assert.AreEqual(SecretGrant.Read, form.Access["atlas"], "the rows show who has the key now");
        await form.SaveAsync();
        CollectionAssert.AreEqual(new[] { "POST ui/secrets/add", "POST ui/vault/intake" }, hub.Writes, "the same agents keep the key, with no step");
        Assert.AreEqual(1, key.Signed);

        var late = new Hub { Logins = hub.Logins, Features = hub.Features.Where(f => f != "secret_replace").ToList() };
        var (waits, _, none, _) = Make(hub: late);
        Type(waits);
        await waits.StartAsync();
        await waits.SaveAsync();
        Assert.AreEqual(VaultWords.NotYet("EXAMPLE_KEY"), waits.Message);

        const string other = "bws://00000004-0000-4000-8000-000000000004";
        var twice = new Hub { Logins = $$"""{"{{Held}}": {"title": "EXAMPLE_KEY", "kind": "api_key", "env": "EXAMPLE_KEY"}, "{{other}}": {"title": "EXAMPLE_KEY", "kind": "api_key", "env": "EXAMPLE_KEY"} }""" };
        var (two, _, _, _) = Make(hub: twice);
        Type(two);
        await two.StartAsync();
        await two.SaveAsync();
        Assert.AreEqual(VaultWords.Twice("EXAMPLE_KEY"), two.Message);
        var login = new Hub { Logins = $$"""{"{{Held}}": {"title": "example.com · ana"} }""" };
        var (second, _, _, _) = Make(new SecretPreset { Kind = SecretKind.Login }, login);
        second.Edit(l => { l.Url = "https://example.com/in"; l.Username = "ana"; l.Password = "correct-horse-battery"; });
        await second.StartAsync();
        await second.SaveAsync();
        Assert.AreEqual(VaultWords.Second("example.com · ana"), second.Message);
        Assert.AreEqual(0, twice.Writes.Count + login.Writes.Count, "nothing goes at the first Save");
        await second.SaveAsync();
        Assert.AreEqual(SecretFormPhase.Saved, second.Phase, "the second Save adds a second login");
        var full = new Hub { Logins = "{" + string.Join(", ", Enumerable.Range(10, LoginSecret.MaxCatalog).Select(n => $$"""
            "bws://{{n:x8}}-0000-4000-8000-{{n:x12}}": {"title": "K{{n}}", "kind": "api_key", "env": "K{{n}}"}
            """)) + "}" };
        var (fullForm, _, _, _) = Make(hub: full);
        Type(fullForm);
        await fullForm.StartAsync();
        await fullForm.SaveAsync();
        Assert.AreEqual(VaultWords.Full(LoginSecret.MaxCatalog.ToString(System.Globalization.CultureInfo.InvariantCulture)), fullForm.Message);
        Assert.AreEqual(0, full.Writes.Count);

        var unsigned = new Hub { Logins = hub.Logins };
        var (cannot, _, _, _) = Make(hub: unsigned, owner: _ => null);
        Type(cannot);
        await cannot.StartAsync();
        await cannot.SaveAsync();
        await cannot.SaveAsync();
        Assert.AreEqual(VaultWords.NothingSent(VaultWords.NoOwnerKey), cannot.Message);
        Assert.AreEqual(0, late.Writes.Count + unsigned.Writes.Count + none.Signed);
        Assert.AreEqual(Key, cannot.Login.Password, "the fields keep what was typed");
    }

    /// <summary>**A step that failed runs again alone**: nothing follows a save before the vault has its value, Try again sends
    /// the same sealed copy and the same answer, and the steps that are done are not done again. Bug: an agent that is told of
    /// a key in no vault, or a second answer of one request.</summary>
    [TestMethod]
    public async Task A_step_that_failed_runs_again_alone()
    {
        var hub = new Hub { Needs = [Request(7, """{"kind": "api_key", "env": "EXAMPLE_KEY", "give": {"atlas": "use"}}""")] };
        var (form, _, _, _) = Make(SecretPreset.Of(hub.Needs[0]), hub);
        await form.StartAsync();
        form.Edit(l => l.Password = Key);
        hub.Refuse["POST ui/vault/intake"] = _ => Busy;
        await form.SaveAsync();
        CollectionAssert.AreEqual(new[] { "POST ui/secrets/add", "POST ui/vault/intake" }, hub.Writes);
        Assert.AreEqual(KeySaveLook.Failed, form.Look);
        Assert.IsFalse(form.Progress!.InVault);
        var copy = hub.Body("POST ui/vault/intake").GetProperty("ciphertext").GetString();
        hub.Refuse.Clear();
        hub.Refuse["POST ui/needs/7/secret"] = _ => HubException.NoAnswer();
        hub.Log.Clear();
        await form.TryAgainAsync();
        CollectionAssert.AreEqual(new[] { "POST ui/vault/intake", "POST ui/vault/grant", "POST ui/secrets/grant", "POST ui/needs/7/secret" }, hub.Writes);
        Assert.AreEqual(copy, hub.Body("POST ui/vault/intake").GetProperty("ciphertext").GetString());
        hub.Refuse["POST ui/needs/7/secret"] = _ => HubException.Refusal(409, null, "answered", "request_answered");
        hub.Log.Clear();
        await form.TryAgainAsync();
        CollectionAssert.AreEqual(new[] { "POST ui/needs/7/secret" }, hub.Writes);
        Assert.IsTrue(form.Progress.IsDone);
        Assert.AreEqual(VaultWords.HadAnswer, form.Progress.AnswerNote);
        Assert.AreEqual(KeySaveLook.Failed, form.Look, "words that he must read are no check");
        Assert.AreEqual(1, hub.Ids.Where(i => i.Route == "ui/needs/7/secret").Select(i => i.Id).Distinct().Count(), "one answer, sent again");
    }

    /// <summary>**The form sends to the hub and the generation that it was opened on**, and to no other. Bug: the owner changes
    /// the hub while a save runs, and a grant or an answer goes to another fleet.</summary>
    [TestMethod]
    public async Task The_form_sends_to_no_other_hub()
    {
        foreach (var move in new Action<Hub>[] { h => h.Database = "db-2", h => h.Address = new Uri("http://100.64.0.9:8765/"), h => h.WritesNow = false })
        {
            var (form, hub, _, _) = Make();
            Type(form);
            await form.StartAsync();
            move(hub);
            await form.SaveAsync();
            Assert.AreEqual(VaultWords.NoStatus, form.Message);
            Assert.AreEqual(0, hub.Writes.Count);
        }
        var need = Request(7, """{"kind": "api_key", "env": "EXAMPLE_KEY", "give": {"atlas": "use"}}""");
        var (midway, moving, _, _) = Make(SecretPreset.Of(need), new Hub { Needs = [need] });
        await midway.StartAsync();
        midway.Edit(l => l.Password = Key);
        moving.Before = route => { if (route == "POST ui/vault/intake") moving.Database = "db-2"; };
        await midway.SaveAsync();
        CollectionAssert.AreEqual(new[] { "POST ui/secrets/add", "POST ui/vault/intake" }, moving.Writes, "no grant and no answer after the move");
        // in the middle of one step: the hub changes after the salts, or after the statement was signed
        foreach (var (at, last) in new[] { ("GET ui/secrets/salts", "none"), ("POST ui/vault/grant", "POST ui/vault/grant") })
        {
            var (form, hub, _, _) = Make(SecretPreset.Of(need), new Hub { Needs = [need] });
            await form.StartAsync();
            form.Edit(l => l.Password = Key);
            hub.Before = route => { if (route == at) hub.Address = new Uri("http://100.64.0.9:8765/"); };
            await form.SaveAsync();
            Assert.AreEqual(last, hub.Writes.LastOrDefault() ?? "none", at);
        }
    }

    /// <summary>**The note's field holds what the hub takes, as the Mac's does**: a character typed into a full note does not
    /// go in, and a paste that is too long is cut at its end. Bug: a character typed in the middle of a full note that cuts
    /// its last word away, out of his sight.</summary>
    [TestMethod]
    public void A_note_holds_no_more_than_the_hub_takes()
    {
        var need = Request(7, """{"kind": "login", "site": "https://example.com/in", "note": "The second shop"}""");
        var (form, _, _, _) = Make(SecretPreset.Of(need), new Hub { Needs = [need] });
        var full = new string('a', 199) + "z";
        form.SetNote(full);
        Assert.AreEqual(full, form.Note);
        form.SetNote("a" + "b" + full[1..]);
        Assert.AreEqual(full, form.Note, "a typed character does not go in");
        form.SetNote(full + "xyz");
        Assert.AreEqual(full, form.Note, "a paste is cut at the end");
        form.SetNote(new string('…', 70));
        Assert.AreEqual(new string('…', 66), form.Note, "counted as the hub counts: one … is three");
    }

    /// <summary>**A note or words that hold a key stay here.** Bug: the owner's key in the fleet's settings, which each agent
    /// that holds the secret reads, or in a message.</summary>
    [TestMethod]
    public async Task A_note_or_words_that_hold_a_key_stay_here()
    {
        var hub = new Hub { Needs = [Request(7, """{"kind": "login", "site": "https://example.com/in", "account": "ana", "note": "The second shop"}""")] };
        var (form, _, _, _) = Make(SecretPreset.Of(hub.Needs[0]), hub);
        await form.StartAsync();
        Assert.AreEqual("ana", form.Login.Username, "the account of the request starts the User name field");
        form.Edit(l => l.Password = "correct-horse-battery");
        form.SetNote("it is correct-horse-battery");
        await form.SaveAsync();
        Assert.AreEqual(VaultWords.KeyInNote, form.Message);
        Assert.IsTrue(form.NoteOpened);
        Assert.IsFalse(await form.ClarifyAsync("try correct-horse-battery please"));
        Assert.AreEqual(VaultWords.KeyInWords, form.Message);
        Assert.IsFalse(await form.ClarifyAsync("the key is sk-live"));
        Assert.AreEqual(0, hub.Writes.Count);
        form.SetNote("The second shop");
        await form.SaveAsync();
        Assert.AreEqual("The second shop", hub.Body("POST ui/needs/7/secret").GetProperty("note").GetString(), "and a note with no key goes with the answer");
        Assert.IsTrue(await Make(SecretPreset.Of(hub.Needs[0]), hub).Form.ClarifyAsync("which shop?"));
        Assert.AreEqual("which shop?", hub.Body("POST ui/needs/7/secret").GetProperty("clarify").GetString());
        await Make(SecretPreset.Of(hub.Needs[0]), hub).Form.DeclineAsync();
        Assert.AreEqual("", hub.Body("POST ui/needs/7/secret").GetProperty("decline").GetString(), "a decline has no words, and the hub reads it as one");
    }

    /// <summary>**A key of a cluster's store gets no form and no new value here**: this PC writes no store. Bug: a store's key
    /// that only the vault gets, so the cluster runs on with the old value while every screen says that it changed.</summary>
    [TestMethod]
    public async Task A_key_of_a_clusters_store_gets_no_form_and_no_new_value()
    {
        foreach (var part in new[] { "\"store\": {\"store\": \"x\"}", "\"store_writer\": 3" })
            Assert.IsNull(SecretPreset.Of(Request(7, $$"""{"kind": "api_key", "env": "EXAMPLE_KEY", {{part}}}""")));
        Assert.IsNotNull(SecretPreset.Of(Request(7, """{"kind": "api_key", "env": "EXAMPLE_KEY", "store": null}""")));
        var hub = new Hub { Logins = $$"""{"{{Held}}": {"title": "EXAMPLE_KEY", "kind": "api_key", "env": "EXAMPLE_KEY", "store": {"need": 4} } }""" };
        var (form, _, key, _) = Make(new SecretPreset { Env = "EXAMPLE_KEY", Replace = Held }, hub);
        await form.StartAsync();
        form.Edit(l => l.Password = Key);
        await form.SaveAsync();
        Assert.AreEqual(0, hub.Writes.Count + key.Signed);
        Assert.IsFalse(SecretValueReplace.Offered(new CatalogEntry("EXAMPLE_KEY", "api_key", "EXAMPLE_KEY", HasStore: true)));
    }

    /// <summary>**A message of the chat names the secret and never its value**, and says who holds it. Bug: a chat that names
    /// the value that the form was opened to keep out of it.</summary>
    [TestMethod]
    public async Task The_message_of_a_form_that_a_chat_opened_names_no_value()
    {
        var said = new List<(string Agent, string Words)>();
        var (form, hub, _, _) = Make(new SecretPreset { Tell = "atlas", Key = Key }, say: (agent, words) => { said.Add((agent, words)); return Task.FromResult(true); });
        Assert.AreEqual(Key, form.Login.Password, "a key that he pasted into the chat is in the field");
        Assert.IsNull(form.Preset.TakeKey(), "and nowhere else");
        form.Edit(l => l.Env = "EXAMPLE_KEY");
        form.SetAccess("atlas", SecretGrant.Read);
        await form.StartAsync();
        await form.SaveAsync();
        var reference = hub.Body("POST ui/secrets/add").GetProperty("login").GetString();
        Assert.AreEqual(("atlas", $"I saved the API key EXAMPLE_KEY in the vault, as {reference}. atlas reads it as $EXAMPLE_KEY."), said.Single());
    }

    /// <summary>**A secret of the list answers a request**: the secrets of the list that fit it are offered, the agents of
    /// the rows (his change of the proposal wins) and the door that the request names get it, each grant signed first and the
    /// door's with its own name as the machine, then the request its answer; and a change of kind empties the value. Bug: a
    /// login offered for a key, a level that he took down that goes anyway, a door key sealed to a machine that the hub
    /// names, or a key that becomes a password.</summary>
    [TestMethod]
    public async Task A_secret_of_the_list_answers_a_request_with_its_rows_and_the_door()
    {
        var need = Request(7, """{"kind": "api_key", "env": "EXAMPLE_KEY", "give": {"atlas": "read", "door": "use"}}""");
        var hub = new Hub
        {
            Needs = [need],
            Logins = $$"""{"{{Held}}": {"title": "EXAMPLE_KEY", "kind": "api_key", "env": "EXAMPLE_KEY"}, "bws://00000004-0000-4000-8000-000000000004": {"title": "example.com · ana"} }""",
        };
        var (form, _, key, _) = Make(SecretPreset.Of(need), hub);
        await form.StartAsync();
        var fits = await form.FitsAsync();
        Assert.AreEqual(Held, fits.Single().Reference, "the key fits, and a login does not");
        form.Edit(l => l.Password = Key);
        form.SetKind(SecretKind.Login);
        Assert.AreEqual("", form.Login.Password, "a key never becomes a password");
        form.SetKind(SecretKind.ApiKey);
        form.SetAccess("atlas", SecretGrant.Use);
        await form.AnswerWithAsync(fits[0].Reference, fits[0].Entry);
        CollectionAssert.AreEqual(new[] { "POST ui/vault/grant", "POST ui/secrets/grant", "POST ui/vault/grant", "POST ui/secrets/grant", "POST ui/needs/7/secret" },
                                  hub.Writes);
        var grants = hub.Log.Where(l => l.Route == "POST ui/secrets/grant").Select(l => l.Body.GetProperty("agent").GetString() + "=" + l.Body.GetProperty("grant").GetString());
        CollectionAssert.AreEqual(new[] { "atlas=use", "door=use" }, grants.ToList());
        var statements = hub.Log.Where(l => l.Route == "POST ui/vault/grant").Select(l => l.Body.GetProperty("statement").GetString()!).ToList();
        using (var said = JsonDocument.Parse(statements[1]))
            Assert.AreEqual("door", said.RootElement.GetProperty("machine").GetString(), "the door's grant names its own key");
        Assert.AreEqual(Held, hub.Body("POST ui/needs/7/secret").GetProperty("login").GetString());
        Assert.AreEqual(2, key.Signed);
        Assert.IsTrue(form.Progress!.IsDone);
    }

    /// <summary>**No edit goes in while a step runs**: the value, the kind and the note stay as they were from the save's
    /// first read to its end. Bug: an edit between the save's first read and its read of the value seals value B under the
    /// name of A, or gives B to the agents that were chosen for A.</summary>
    [TestMethod]
    public async Task No_edit_goes_in_while_a_step_runs()
    {
        var need = Request(7, """{"kind": "api_key", "env": "EXAMPLE_KEY", "note": "The second shop", "give": {"atlas": "read"}}""");
        var hub = new Hub { Needs = [need] };
        var (form, _, _, _) = Make(SecretPreset.Of(need), hub);
        await form.StartAsync();
        form.Edit(l => l.Password = Key);
        var item = form.Login.Value();
        hub.Before = route =>
        {
            if (route != "GET ui/team") return;
            form.Edit(l => { l.Password = "sk-test-another-key-0123456789"; l.Env = "OTHER_KEY"; });
            form.SetKind(SecretKind.Login);
            form.SetAccess("atlas", null);
            form.SetNote("changed");
        };
        await form.SaveAsync();
        var add = hub.Body("POST ui/secrets/add");
        Assert.AreEqual("EXAMPLE_KEY", add.GetProperty("env").GetString());
        var salts = new SecretSalts(add.GetProperty("login").GetString()!, new string('a', 32), new string('b', 32));
        Assert.AreEqual(SecretFingerprint.Of(item, salts).Single().Hash, add.GetProperty("fingerprints")[0].GetProperty("hash").GetString(),
                        "the value of the first read is sealed");
        Assert.AreEqual("read", hub.Body("POST ui/secrets/grant").GetProperty("grant").GetString(), "the row stays");
        Assert.AreEqual("The second shop", hub.Body("POST ui/needs/7/secret").GetProperty("note").GetString(), "the note stays");
    }

    /// <summary>An owner key that gives no signature: a key store's fault.</summary>
    private sealed class BlankKey : IOwnerKey
    {
        public string PublicKey => "";
        public string Sign(string statement) => "";
    }

    /// <summary>A clock record whose file fails after <paramref name="keeps"/> writes, as a full disk or a file that another
    /// program holds.</summary>
    private sealed class FailingClock(int keeps) : IGrantClockRecord
    {
        private readonly MemoryClock kept = new();
        private int left = keeps;
        public long? Last(string fleet) => kept.Last(fleet);

        public void Keep(string fleet, long at)
        {
            if (left-- <= 0) throw new IOException("the disk is full");
            kept.Keep(fleet, at);
        }
    }

    /// <summary>A hub that gives one answer of a test's own to every call, with the call's request id in place of
    /// <c>{ID}</c>.</summary>
    private sealed class Answers : IVaultCalls
    {
        public string Answer { get; set; } = "{}";
        public Uri? Hub => new("http://100.64.0.1:8765/");
        public string? Database => "db-1";
        public bool WritesNow => true;
        public IReadOnlyList<string> Features => [];
        public IReadOnlyList<OwnerNeed> Needs => [];
        public IReadOnlyList<string> Holders => [];
        public DateTimeOffset Now => DateTimeOffset.FromUnixTimeSeconds((long)HubTime);

        public Task<OwnerAnswer<JsonDocument>> GetAsync(string route, IReadOnlyList<(string Name, string Value)>? query, int limit, CancellationToken cancel) =>
            Task.FromResult(new OwnerAnswer<JsonDocument>(JsonDocument.Parse(Answer)));

        public Task<OwnerAnswer<JsonDocument>> PostAsync<TBody>(string route, TBody body, JsonTypeInfo<TBody> type, Guid requestId, CancellationToken cancel) =>
            Task.FromResult(new OwnerAnswer<JsonDocument>(JsonDocument.Parse(Answer.Replace("{ID}", requestId.ToString("D"), StringComparison.Ordinal))));

        public Task RefreshAsync() => Task.CompletedTask;
    }

    /// <summary>**Each answer that is not the receipt of its own request is refused**, for every route of the vault and of the
    /// secrets: another generation, another reference, agent, grant or request, a receipt that says <c>"ok": false</c> or
    /// names another request, salts of another reference, and a field that the receipt must have. Each route takes its good
    /// answer. Bug: a reply to another call, or a hub that answers for another fleet, that the form reads as done, so a
    /// secret that the vault never got is shown as given.</summary>
    [TestMethod]
    public async Task Each_answer_that_is_not_the_receipt_of_its_request_is_refused()
    {
        const string other = "bws://00000004-0000-4000-8000-000000000004";
        static string Q(string text) => "\"" + text + "\"";
        static string F(params (string Name, string Json)[] fields) => string.Join(", ", fields.Select(f => Q(f.Name) + ": " + f.Json));
        static string Receipt(string fields, bool ok = true, string id = "{ID}") =>
            "{" + F(("ok", ok ? "true" : "false"), ("request_id", Q(id))) + (fields.Length > 0 ? ", " + fields : "") + "}";
        static string Salts(string login, string password) => "{" + F(("login", Q(login)), ("password", Q(password)), ("totp", Q(new string('b', 32)))) + "}";
        static string Team(string db) =>
            "{" + F(("db", Q(db)), ("revision", Q(new string('a', 40))), ("sha256", Q(new string('b', 64))), ("open_tasks", "{}"), ("logins", "{}"), ("lines", "[{\"agent\": \"juno\", \"role\": \"manager\"}]")) + "}";
        static string Grant(string login, string agent, string grant, string? more = ", \"changed\": true") =>
            F(("login", Q(login)), ("agent", Q(agent)), ("grant", Q(grant))) + more;
        IReadOnlyList<SecretFingerprint> prints = [new("password", new string('c', 64), 12)];
        var sealedCopy = AgeSeal.Seal("v"u8, VaultKey);
        var signature = Convert.ToBase64String(new byte[70]);
        var saved = F(("saved", Q("new")));
        var cases = new (string Name, Func<IVaultCalls, Task> Call, string Good, string[] Bad)[]
        {
            ("GET ui/vault", c => VaultRoutes.ReadingAsync(c), "{" + F(("db", Q("db-1"))) + "}",
             ["{" + F(("db", Q("db-2"))) + "}", "{" + F(("fleet", Q(Fleet))) + "}"]),
            ("GET ui/secrets/salts", c => VaultRoutes.SaltsAsync(c, Held), Salts(Held, new string('a', 32)), [Salts(other, new string('a', 32)), Salts(Held, "not hex")]),
            ("GET ui/state", c => VaultRoutes.ClockAsync(c), "{" + F(("db", Q("db-1")), ("time", "5")) + "}",
             ["{" + F(("db", Q("db-2")), ("time", "5")) + "}", "{" + F(("db", Q("db-1"))) + "}"]),
            ("GET ui/team", c => VaultRoutes.TeamAsync(c), Team("db-1"), [Team("db-2")]),
            ("POST ui/secrets/add", c => VaultRoutes.AddAsync(c, Held, "EXAMPLE_KEY", SecretKind.ApiKey, "EXAMPLE_KEY", null, prints, Guid.NewGuid()),
             Receipt(F(("login", Q(Held)), ("stored", "1"), ("known", "0"), ("changed", "true"))),
             [Receipt(F(("login", Q(other)), ("stored", "1"), ("known", "0"), ("changed", "true"))),
              Receipt(F(("login", Q(Held)), ("stored", "0"), ("known", "0"), ("changed", "true"))),
              Receipt(F(("login", Q(Held)), ("stored", "1"), ("known", "0")))]),
            ("POST ui/vault/intake", c => VaultRoutes.IntakeAsync(c, Held, sealedCopy, null, Guid.NewGuid()), Receipt(F(("login", Q(Held)))),
             [Receipt(F(("login", Q(other))))]),
            ("POST ui/vault/pin", c => VaultRoutes.PinAsync(c, "{\"v\":1}", signature, Guid.NewGuid()), Receipt(saved), []),
            ("POST ui/vault/recovery", c => VaultRoutes.RecoveryAsync(c, "{\"v\":1}", signature, Guid.NewGuid()), Receipt(saved), []),
            ("POST ui/vault/grant", c => VaultRoutes.SignedGrantAsync(c, "{\"v\":1}", signature, Guid.NewGuid()), Receipt(saved), []),
            ("POST ui/owner/devices/ana-phone/recovery", c => VaultRoutes.RecoveryCopyAsync(c, "ana-phone", "box", Guid.NewGuid()), Receipt(""), []),
            ("POST ui/secrets/grant", c => VaultRoutes.GrantAsync(c, Held, "atlas", SecretGrant.Read, Guid.NewGuid()), Receipt(Grant(Held, "atlas", "read")),
             [Receipt(Grant(other, "atlas", "read")), Receipt(Grant(Held, "nova", "read")), Receipt(Grant(Held, "atlas", "use")),
              Receipt(Grant(Held, "atlas", "read", "")), Receipt(Grant(Held, "atlas", "read", ", \"changed\": true, \"vault\": {\"before\": \"off\"}"))]),
            ("POST ui/needs/7/secret", c => VaultRoutes.AnswerAsync(c, 7, Held, null, Guid.NewGuid()), Receipt(F(("need", "7"), ("login", Q(Held)))),
             [Receipt(F(("need", "8"), ("login", Q(Held)))), Receipt(F(("need", "7"), ("login", Q(other))))]),
            ("POST a decline", c => VaultRoutes.DeclineAsync(c, 7, Guid.NewGuid()), Receipt(F(("need", "7"))),
             [Receipt(F(("need", "8"))), Receipt(F(("need", "7"), ("login", Q(Held))))]),
        };
        var calls = new Answers();
        foreach (var (name, call, good, bad) in cases)
        {
            calls.Answer = good;
            await call(calls);
            string[] refused = name.StartsWith("POST", StringComparison.Ordinal)
                ? [.. bad, good.Replace("\"ok\": true", "\"ok\": false", StringComparison.Ordinal), good.Replace("{ID}", Guid.NewGuid().ToString("D"), StringComparison.Ordinal)]
                : bad;
            foreach (var answer in refused)
            {
                calls.Answer = answer;
                var e = await Assert.ThrowsExactlyAsync<HubException>(() => call(calls), name + ": " + answer);
                Assert.AreEqual(HubErrorKind.InvalidResponse, e.Kind, name + ": " + answer);
            }
        }
    }

    /// <summary>**The pool statements that the hub's default owes go by the Mac's rules** (owner feature <c>pool_default</c>):
    /// at most 32 a round, the ends first; one read of the fleet and of the owner key; every statement signed before the
    /// first one goes; a <c>default_pool</c> only while the clocks agree, while an end goes also when they do not; a refusal
    /// of the vault goes on to the next statement and any other failure ends the batch; a failure of the clock's file, of the
    /// key store or of a signature's shape ends the round with its count and throws nothing; nothing without both features.
    /// Bug:
    /// a give by the hub's default that never reaches its agent on a fleet of PCs, an owed end that is never signed, a round
    /// of hundreds of statements, or a plain <c>pool</c> that undoes the owner's "Only you".</summary>
    [TestMethod]
    public async Task The_pool_statements_of_the_default_go_by_the_Macs_rules()
    {
        static string Ref(int n) => $"bws://{n:x8}-0000-4000-8000-{n:x12}";
        var due = Enumerable.Range(100, 35).Select(n => new VaultPoolDue(Ref(n), true))
                            .Concat(Enumerable.Range(200, 5).Select(n => new VaultPoolDue(Ref(n), false))).ToList();
        IReadOnlyList<string> features = [.. new Hub().Features, "pool_default"];
        var hub = new Hub { Features = features };
        var key = new CountingKey(hub);
        var reads = 0;
        var signing = new VaultSigning(hub, fleet => { reads++; return fleet == Fleet ? key : null; }, new MemoryClock());
        Assert.AreEqual(32, await signing.PoolsAsync(due));
        var steps = hub.Routes.ToList();
        CollectionAssert.AreEqual(Enumerable.Repeat("SIGN unpool", 5).Concat(Enumerable.Repeat("SIGN default_pool", 27)).ToList(),
                                  steps.Where(r => r.StartsWith("SIGN", StringComparison.Ordinal)).ToList(), "the ends first, and at most 32");
        Assert.AreEqual(1, reads, "one read of the owner key");
        Assert.AreEqual(1, steps.Count(r => r == "GET ui/vault"), "and of the fleet");
        Assert.AreEqual(32, hub.Writes.Count);
        Assert.IsTrue(steps.LastIndexOf("SIGN default_pool") < steps.IndexOf("POST ui/vault/grant"), "every statement is signed before the first one goes");

        var off = new Hub { Features = features, Now = DateTimeOffset.FromUnixTimeSeconds((long)HubTime + 7200) };
        var offKey = new CountingKey(off);
        Assert.AreEqual(5, await new VaultSigning(off, _ => offKey, new MemoryClock()).PoolsAsync(due));
        Assert.IsFalse(off.Routes.Contains("SIGN default_pool"), "no default_pool while the clocks differ, and the ends go");

        var refusing = new Hub { Features = features };
        var refusingKey = new CountingKey(refusing);
        static string? LoginOf(JsonElement body)
        {
            using var said = JsonDocument.Parse(body.GetProperty("statement").GetString()!);
            return said.RootElement.GetProperty("login").GetString();
        }
        refusing.Refuse["POST ui/vault/grant"] = body => LoginOf(body) == Ref(201) ? HubException.Refusal(400, null, "no value yet")
            : LoginOf(body) == Ref(203) ? HubException.NoAnswer() : null;
        Assert.AreEqual(2, await new VaultSigning(refusing, _ => refusingKey, new MemoryClock()).PoolsAsync(due),
                        "the ends of 200 and 202 went; the refusal of 201 went on, and no answer of 203 ended the batch");
        Assert.AreEqual(4, refusing.Writes.Count);

        // a clock's file that fails at the third statement: the signing ends there, and the two made before it go
        var failing = new Hub { Features = features };
        var failingKey = new CountingKey(failing);
        Assert.AreEqual(2, await new VaultSigning(failing, _ => failingKey, new FailingClock(2)).PoolsAsync(due));
        Assert.AreEqual(2, failing.Writes.Count);
        // a key that signs with nothing: the first send refuses its statement, the batch ends, and nothing throws
        var blank = new Hub { Features = features };
        Assert.AreEqual(0, await new VaultSigning(blank, _ => new BlankKey(), new MemoryClock()).PoolsAsync(due));
        Assert.AreEqual(0, blank.Writes.Count);
        // a key store that fails in a way of its own: nothing is signed, and nothing throws
        var broken = new Hub { Features = features };
        Assert.AreEqual(0, await new VaultSigning(broken, _ => throw new System.ComponentModel.Win32Exception(5), new MemoryClock()).PoolsAsync(due));
        Assert.AreEqual(0, broken.Writes.Count);

        foreach (var without in new[] { "pool_default", "signed_grants" })
        {
            var hubWithout = new Hub { Features = features.Where(f => f != without).ToList() };
            var keyWithout = new CountingKey(hubWithout);
            Assert.AreEqual(0, await new VaultSigning(hubWithout, _ => keyWithout, new MemoryClock()).PoolsAsync(due), without);
            Assert.AreEqual(0, hubWithout.Writes.Count + keyWithout.Signed, without);
        }
    }

    // ---------------------------------------------------------------- what is kept

    /// <summary>**Nothing that holds a value prints it or has a JSON form.** Bug: a class that becomes a record, whose own
    /// text then puts the owner's key, his recovery code or his access key into a log or a crash report.</summary>
    [TestMethod]
    public void Nothing_that_holds_a_value_prints_it()
    {
        var code = RecoveryCode.Make();
        var access = OwnerAccessKey.Make();
        var login = new LoginSecret { Password = Key, Totp = "JBSWY3DPEHPK3PXP" };
        var preset = new SecretPreset { Key = Key };
        var progress = new SecretProgress(Held, "EXAMPLE_KEY", SecretKind.ApiKey, [], null, sealedCopy: "the sealed copy");
        foreach (var text in new[] { $"{code}", $"{access}", $"{login}", $"{preset}", $"{progress}" })
            foreach (var value in new[] { code.Normalized, Convert.ToBase64String(access.Seed()), Key, "JBSWY3DPEHPK3PXP", "the sealed copy" })
                Assert.IsFalse(text.Contains(value, StringComparison.Ordinal), text);
        foreach (var type in new[] { typeof(LoginSecret), typeof(SecretPreset), typeof(SecretProgress), typeof(RecoveryCode), typeof(OwnerAccessKey) })
            Assert.IsNull(VaultJson.Default.GetTypeInfo(type), type.Name + " has no JSON form");
    }

    /// <summary>**The recovery code and the owner access key are made once for a fleet, and only in the box.** A box that does
    /// not keep one gives none. Bug: a backup sealed to a code that nobody has, or a line on every server whose key is
    /// lost.</summary>
    [TestMethod]
    public void The_recovery_code_and_the_access_key_are_made_once_and_read_back()
    {
        var box = new MemorySecretBox();
        var code = RecoveryKeeping.Kept(box, Fleet);
        Assert.AreEqual(code, RecoveryKeeping.Kept(box, Fleet));
        Assert.AreNotEqual(code, RecoveryKeeping.Kept(box, "0fedcba987654321"), "each fleet has its own, also one of the same first letter");
        var key = OwnerAccessKeeping.Kept(box, Fleet);
        Assert.AreNotEqual(key, OwnerAccessKeeping.Kept(box, "0fedcba987654321"), "each fleet has its own access key");
        Assert.AreEqual(key, OwnerAccessKeeping.Kept(box, Fleet));
        Assert.AreEqual(key, OwnerAccessKeeping.Key(box, Fleet));
        Assert.ThrowsExactly<ArgumentException>(() => RecoveryKeeping.Kept(box, "../owner-keys"));
        Assert.ThrowsExactly<SealException>(() => RecoveryKeeping.Kept(new Forgetful(), Fleet));
        Assert.ThrowsExactly<SealException>(() => OwnerAccessKeeping.Kept(new Forgetful(), Fleet));
    }

    /// <summary>**A new code or key is made only where the box says that none is there, and goes in only where the name
    /// holds none** (the Mac's rule since 24 November 2026): a value that does not read now, and a read that fails now, both
    /// throw and keep what is there; of two starts that both read "none", the second gives the first one's code and key; and a
    /// read that says "none" by mistake while a value is there writes over nothing. Bug: one passing error of the box, or a
    /// second start of the app, and every backup is sealed to a new code while the old backups lose theirs; or a new access
    /// key that no copy of the fleet holds.</summary>
    [TestMethod]
    public void A_value_that_does_not_read_now_is_kept_and_never_replaced()
    {
        var box = new MemorySecretBox();
        byte[] notACode = "not a code"u8.ToArray(), notAKey = new byte[31];
        box.Write(RecoveryKeeping.Name(Fleet), notACode);
        box.Write(OwnerAccessKeeping.Name(Fleet), notAKey);
        Assert.ThrowsExactly<SealException>(() => RecoveryKeeping.Kept(box, Fleet));
        Assert.ThrowsExactly<SealException>(() => OwnerAccessKeeping.Kept(box, Fleet));
        CollectionAssert.AreEqual(notACode, box.Read(RecoveryKeeping.Name(Fleet)), "the value that was there stays");
        CollectionAssert.AreEqual(notAKey, box.Read(OwnerAccessKeeping.Name(Fleet)));
        var locked = new Locked();
        Assert.ThrowsExactly<CryptographicException>(() => RecoveryKeeping.Kept(locked, Fleet));
        Assert.ThrowsExactly<CryptographicException>(() => OwnerAccessKeeping.Kept(locked, Fleet));
        Assert.AreEqual(0, locked.Writes, "a read that fails writes nothing");

        // another start keeps its code and key between this start's read and its write
        var first = new MemorySecretBox();
        var code = RecoveryKeeping.Kept(first, Fleet);
        var key = OwnerAccessKeeping.Kept(first, Fleet);
        var racing = new Racing(first);
        Assert.AreEqual(code, RecoveryKeeping.Kept(racing, Fleet), "the first start's code");
        Assert.AreEqual(key, OwnerAccessKeeping.Kept(racing, Fleet), "the first start's key");
        Assert.AreEqual(code, RecoveryKeeping.Code(first, Fleet), "and it stays in the box");
        Assert.AreEqual(key, OwnerAccessKeeping.Key(first, Fleet));
        // a read that says "none" while a value is there
        var hiding = new Hiding(first);
        Assert.ThrowsExactly<SealException>(() => RecoveryKeeping.Kept(hiding, Fleet));
        Assert.ThrowsExactly<SealException>(() => OwnerAccessKeeping.Kept(hiding, Fleet));
        Assert.AreEqual(code, RecoveryKeeping.Code(first, Fleet), "the code that was there stays");
        Assert.AreEqual(key, OwnerAccessKeeping.Key(first, Fleet));
    }

    /// <summary>A box whose first read of a name says "none" while another start keeps its value: the value is there at the
    /// write.</summary>
    private sealed class Racing(MemorySecretBox kept) : ISecretBox
    {
        private readonly HashSet<string> read = [];
        public byte[]? Read(string name) => read.Add(name) ? null : kept.Read(name);
        public void Write(string name, byte[] value) => kept.Write(name, value);
        public void Remove(string name) => kept.Remove(name);
        public bool WriteNew(string name, byte[] value) => kept.WriteNew(name, value);
    }

    /// <summary>A box whose read says "none" by mistake, as <c>File.Exists</c> can for a file that it cannot reach for a
    /// moment, while its value is there.</summary>
    private sealed class Hiding(MemorySecretBox kept) : ISecretBox
    {
        public byte[]? Read(string name) => null;
        public void Write(string name, byte[] value) => kept.Write(name, value);
        public void Remove(string name) => kept.Remove(name);
        public bool WriteNew(string name, byte[] value) => kept.WriteNew(name, value);
    }

    private sealed class Forgetful : ISecretBox
    {
        public byte[]? Read(string name) => null;
        public void Write(string name, byte[] value) { }
        public void Remove(string name) { }
    }

    /// <summary>A box whose kept values do not open now, as Windows' protection of the user's data can refuse.</summary>
    private sealed class Locked : ISecretBox
    {
        public int Writes { get; private set; }
        public byte[]? Read(string name) => throw new CryptographicException("the box does not open now");
        public void Write(string name, byte[] value) => Writes++;
        public void Remove(string name) { }
    }

    /// <summary>**A key that the vault's install printed becomes the pin only at the owner's Set up or at a first install**, as
    /// on the Mac (validation M2 of 23 November 2026). Bug: an update, or a hub that is broken into, prints another key, the PC
    /// pins it, and the owner's next secret is sealed to that key.</summary>
    [TestMethod]
    public void A_printed_key_becomes_the_pin_only_at_set_up_or_at_a_first_install()
    {
        Assert.IsNull(CentralVaultPin.Refusal(VaultKey, held: null, setUp: false), "a first install pins");
        Assert.IsNull(CentralVaultPin.Refusal(VaultKey, held: VaultKey, setUp: false), "the same key again");
        Assert.AreEqual(VaultPlan.OtherKey, CentralVaultPin.Refusal(Other, held: VaultKey, setUp: false), "an update keeps the pin");
        Assert.IsNull(CentralVaultPin.Refusal(Other, held: VaultKey, setUp: true), "the owner's Set up takes the vault over");
        // the pins file applies the rule itself at each pin
        var folder = Directory.CreateTempSubdirectory("founderizer-vault-pin-").FullName;
        try
        {
            var pins = new CentralVaultPinsFile(Path.Combine(folder, "pins.json"));
            Uri hub = new("http://100.64.0.1:8765/");
            Assert.IsNull(pins.Pin(VaultKey, hub, Fleet, setUp: false), "a first install pins");
            Assert.AreEqual(VaultPlan.OtherKey, pins.Pin(Other, hub, Fleet, setUp: false));
            Assert.AreEqual(VaultKey, pins.Recipient(hub, Fleet), "an update keeps the pin");
            Assert.IsNull(pins.Pin(Other, hub, Fleet, setUp: true));
            Assert.AreEqual(Other, pins.Recipient(hub, Fleet), "Set up takes the vault over");
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    /// <summary>**The pin of the vault's key and the clock of the statements are there at the next start**, each for its hub
    /// and its fleet. A pins file that does not read throws at a read and at a pin, and stays as it is, until the owner's Set
    /// up, which keeps a copy of it, a new one at each damage, and writes a new file with its one pin in its place; a Set up
    /// whose new file cannot be written leaves the damaged file; a clock file that does not read is no record. Bug: a pin of
    /// one hub that another hub's form seals to; a damaged pins file read as "no pin", so that an install pins a key with no
    /// Set up and writes away the other hubs' pins; a damaged pins file that stops even Set up for ever; a Set up that fails
    /// halfway and leaves no file, which reads as "no pin"; a second damage whose copy writes over the first one; or a
    /// damaged clock file that stops every start.</summary>
    [TestMethod]
    public void The_pin_and_the_clock_are_kept_between_starts()
    {
        var folder = Directory.CreateTempSubdirectory("founderizer-vault-kept-").FullName;
        try
        {
            string pins = Path.Combine(folder, "a", "pins.json"), clock = Path.Combine(folder, "a", "clock.json");
            Uri first = new("http://100.64.0.1:8765/"), second = new("http://100.64.0.2:8765/");
            new CentralVaultPinsFile(pins).Pin(VaultKey, first, Fleet, setUp: false);
            var read = new CentralVaultPinsFile(pins);
            Assert.AreEqual(VaultKey, read.Recipient(first, Fleet));
            Assert.IsNull(read.Recipient(second, Fleet));
            Assert.IsNull(read.Recipient(first, "fedcba9876543210"));
            Assert.ThrowsExactly<ArgumentException>(() => read.Pin("not a key", first, Fleet, setUp: false));
            var at = GrantClock.Next(Fleet, 100, new GrantClockFile(clock));
            Assert.AreEqual(at + 1, GrantClock.Next(Fleet, 100, new GrantClockFile(clock)));
            File.WriteAllText(pins, "{");
            File.WriteAllText(clock, "[]");
            Assert.ThrowsExactly<InvalidDataException>(() => read.Recipient(first, Fleet));
            Assert.ThrowsExactly<InvalidDataException>(() => read.Pin(VaultKey, second, Fleet, setUp: false));
            Assert.AreEqual("{", File.ReadAllText(pins), "a pin writes over no file that does not read");
            // a Set up whose new file cannot be written leaves the damaged file, never no file
            Directory.CreateDirectory(pins + ".new");
            Assert.Throws<Exception>(() => read.Pin(Other, second, Fleet, setUp: true));
            Assert.AreEqual("{", File.ReadAllText(pins), "the damaged file stays in its place");
            Assert.ThrowsExactly<InvalidDataException>(() => read.Recipient(first, Fleet), "and a read still throws");
            Directory.Delete(pins + ".new");
            Assert.IsNull(read.Pin(Other, second, Fleet, setUp: true), "the owner's Set up pins");
            Assert.AreEqual(Other, read.Recipient(second, Fleet));
            Assert.IsNull(read.Recipient(first, Fleet), "in a new file of its one pin");
            Assert.AreEqual("{", File.ReadAllText(read.Unreadable), "and the file that did not read is kept beside it");
            // a second damage keeps its own copy, and the first copy stays
            File.WriteAllText(pins, "[");
            Assert.IsNull(read.Pin(VaultKey, second, Fleet, setUp: true));
            Assert.AreEqual("{", File.ReadAllText(read.Unreadable), "the first copy stays");
            CollectionAssert.AreEquivalent(new[] { "{", "{", "[" },
                                           Directory.GetFiles(Path.GetDirectoryName(pins)!, "pins.json.unreadable*").Select(File.ReadAllText).ToList(),
                                           "each damage has its own copy");
            Assert.AreEqual(50, GrantClock.Next(Fleet, 50, new GrantClockFile(clock)));
            if (!OperatingSystem.IsWindows())
                Assert.AreEqual(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(clock));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
