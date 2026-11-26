using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Founderizer.Core;
using Founderizer.Owner.Vault;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Owner.Tests;

/// <summary>The shared vectors of app/vectors, which the build copies beside the tests.</summary>
internal static class Vectors
{
    public static JsonElement Read(string name)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "vectors", name)));
        return document.RootElement.Clone();
    }

    public static string? Text(this JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetString();
    public static string? Text(this JsonElement value, string name) => value.GetProperty(name).Text();
    public static List<string> Texts(this JsonElement value) => value.EnumerateArray().Select(v => v.GetString()!).ToList();
    public static byte[] Hex(this JsonElement value, string name) => Convert.FromHexString(value.GetProperty(name).GetString()!);
    public static double? Number(this JsonElement value, string name) =>
        value.GetProperty(name) is { ValueKind: JsonValueKind.Number } number ? number.GetDouble() : null;

    /// <summary>A sentence of the Mac with the PC's word (windows-app-plan-v2.md, rule 14).</summary>
    public static string? Pc(string? mac) => mac is null ? null : Regex.Replace(mac, @"\bMac\b", "PC");
}

/// <summary>**The vault's core gives what the Mac gives** (piece L5), held to <c>vault-seal.json</c>, which FleetCore's own
/// code makes (<c>VaultVectorsTests.swift</c>), and to <c>owner-replace.json</c>, which the vault's own code makes.</summary>
[TestClass]
public sealed class VaultVectorTests
{
    private static readonly JsonElement All = Vectors.Read("vault-seal.json");

    private static Func<int, byte[]> Given(params byte[][] parts)
    {
        var rest = new Queue<byte[]>(parts);
        return count =>
        {
            var next = rest.Dequeue();
            Assert.AreEqual(count, next.Length);
            return next;
        };
    }

    /// <summary>**A seal with the vector's fixed keys gives the vector's bytes**: the header, the wrapped key, the HMAC and
    /// each chunk of the payload. Bug: one byte of age's format that differs, so no vault opens what the PC sealed and the
    /// owner's key is gone with the form.</summary>
    [TestMethod]
    public void A_seal_with_the_vectors_fixed_keys_gives_the_vectors_bytes()
    {
        var seal = All.GetProperty("seal");
        foreach (var row in seal.GetProperty("seals").EnumerateArray())
        {
            var name = row.Text("name")!;
            var value = row.TryGetProperty("value_b64", out var given) ? Convert.FromBase64String(given.GetString()!)
                : Enumerable.Range(0, row.GetProperty("length").GetInt32()).Select(i => (byte)(i % 251)).ToArray();
            var made = AgeSeal.Seal(value, row.Text("recipient")!,
                                    Given(row.Hex("file_key_hex"), row.Hex("ephemeral_hex"), row.Hex("nonce_hex")));
            if (row.TryGetProperty("sealed", out var whole)) Assert.AreEqual(whole.GetString(), made, name);
            Assert.AreEqual(row.Text("sealed_sha256"), Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(made))), name);
            Assert.AreEqual(made.Length, AgeSeal.SealedLength(value.Length), name);
        }
        Assert.AreEqual(AgeSeal.MaxCopy, seal.GetProperty("max_copy").GetInt32());
        Assert.AreEqual(seal.GetProperty("longest_sealed").GetInt32(), AgeSeal.LongestSealed(AgeSeal.MaxCopy));
        foreach (var row in seal.GetProperty("sealed_lengths").EnumerateArray())
            Assert.AreEqual(row.GetProperty("length").GetInt32(), AgeSeal.SealedLength(row.GetProperty("count").GetInt32()));
        foreach (var row in seal.GetProperty("is_sealed").EnumerateArray())
            Assert.AreEqual(row.GetProperty("sealed").GetBoolean(), AgeSeal.IsSealed(row.Text("text")!), row.Text("text"));
        foreach (var row in seal.GetProperty("recipients").EnumerateArray())
            Assert.AreEqual(row.Text("public_key_hex"),
                            AgeSeal.PublicKeyOf(row.Text("text")!) is { } key ? Convert.ToHexStringLower(key) : null, row.Text("text"));
    }

    /// <summary>**No value is sealed to a key that opens for nobody or for anybody**: a recipient of low order (an all-zero
    /// shared secret) and a text that is no recipient. Bug: a broken hub's key of zeros, whose shared secret everyone
    /// knows.</summary>
    [TestMethod]
    public void No_value_is_sealed_to_a_key_of_low_order_or_to_no_key()
    {
        var zeros = AgeSeal.Bech32("age", new byte[32]);
        Assert.IsNotNull(AgeSeal.PublicKeyOf(zeros), "its shape is a recipient's");
        Assert.ThrowsExactly<SealException>(() => AgeSeal.Seal("value"u8, zeros));
        Assert.ThrowsExactly<SealException>(() => AgeSeal.Seal("value"u8, "age1nope"));
    }

    /// <summary>**The recovery code gives the vector's recipient and identity**, and reads back as the owner may type it.
    /// Bug: another key than the Mac's from the same code, so a code that a Mac made opens no backup of a PC, or the
    /// reverse.</summary>
    [TestMethod]
    public void The_recovery_code_gives_the_vectors_recipient()
    {
        var recovery = All.GetProperty("recovery");
        foreach (var row in recovery.GetProperty("codes").EnumerateArray())
        {
            var code = RecoveryCode.Make(Given(row.Hex("random_hex")));
            Assert.AreEqual(row.Text("normalized"), code.Normalized);
            Assert.AreEqual(row.Text("grouped"), code.Grouped);
            Assert.AreEqual(row.Text("recipient"), code.Recipient);
            Assert.AreEqual(row.Text("identity_sha256"), Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(code.Identity))));
        }
        foreach (var row in recovery.GetProperty("typed").EnumerateArray())
            Assert.AreEqual(row.Text("normalized"), RecoveryCode.Read(row.Text("text")!)?.Normalized, row.Text("text"));
    }

    /// <summary>**The recovery code's copy for a phone is the Mac's box**, it opens with that phone's key and name alone, and
    /// a new one opens too. Bug: a box that the phone's app does not open, so a lost PC takes the code with it.</summary>
    [TestMethod]
    public void The_recovery_box_is_the_vectors_and_opens_for_its_phone_alone()
    {
        var row = All.GetProperty("recovery").GetProperty("seal");
        var code = Encoding.UTF8.GetBytes(row.Text("code")!);
        string device = row.Text("device")!, key = row.Text("phone_public")!;
        Assert.AreEqual(row.Text("box"), RecoverySeal.Seal(code, key, device, row.Hex("ephemeral_private_hex"), row.Hex("nonce_hex")));
        Assert.AreEqual(RecoverySeal.Info, row.Text("info"));
        var phone = row.Hex("phone_private_hex");
        CollectionAssert.AreEqual(code, RecoverySeal.Open(row.Text("box")!, device, phone));
        CollectionAssert.AreEqual(code, RecoverySeal.Open(RecoverySeal.Seal(code, key, device), device, phone));
        Assert.ThrowsExactly<SealException>(() => RecoverySeal.Open(row.Text("box")!, "another-phone", phone));
        Assert.ThrowsExactly<SealException>(() => RecoverySeal.Seal(code, Convert.ToBase64String(new byte[65]), device));
    }

    /// <summary>**The fingerprints equal the vector's**, which the maker holds to the vault's own <c>fingerprints</c>: the
    /// central vault keeps a value only when its own fingerprints are the registered ones. Bug: a length in UTF-16 units, or
    /// a seed in another form, and no key with an emoji or with a 2FA seed can be saved from a PC.</summary>
    [TestMethod]
    public void The_fingerprints_equal_the_vectors()
    {
        var secrets = All.GetProperty("secrets");
        using var given = JsonDocument.Parse(secrets.Text("salts")!);
        var salts = SecretSalts.Read(given.RootElement)!;
        Assert.IsTrue(salts.IsValid);
        var count = 0;
        foreach (var row in secrets.GetProperty("secrets").EnumerateArray().Where(r => r.Text("value") is not null))
        {
            var made = SecretFingerprint.Of(Encoding.UTF8.GetBytes(row.Text("value")!), salts);
            CollectionAssert.AreEqual(row.GetProperty("fingerprints").EnumerateArray()
                                         .Select(f => new SecretFingerprint(f.Text("kind")!, f.Text("hash")!, f.GetProperty("len").GetInt32())).ToList(),
                                      made.ToList(), row.Text("name"));
            count++;
        }
        Assert.IsTrue(count >= 12, "the vector has values");
        foreach (var row in secrets.GetProperty("seeds").EnumerateArray())
            Assert.AreEqual(row.Text("seed"), SecretFingerprint.CanonicalSeed(row.Text("value")!), row.Text("value"));
        CollectionAssert.AreEqual(All.GetProperty("reading").GetProperty("trims").GetProperty("python_space").EnumerateArray().Select(v => v.GetInt32()).ToList(),
                                  Enumerable.Range(0, 0x10000).Where(v => Rune.IsValid(v) && SecretFingerprint.IsWhitespace(new Rune(v))).ToList());
    }

    /// <summary>**A secret of the form is the Mac's**: its title, its variable, the address for the hub's table, its problems
    /// in the Mac's words, and the bytes of the item that the vault opens; an AI provider's sign-in site in capitals and with
    /// a dot at its end, and a value too long, are the vector's own rows. A paste with a lone surrogate, which no line holds,
    /// is the Mac's too-long line (its <c>try? line(fields)</c>) and throws nothing. Bug: a key that the PC refuses or takes
    /// where the Mac does not, a path (which can be a secret) in the table's address, an item that the vault reads otherwise,
    /// or a malformed paste that stops the app with the typed key in its dump.</summary>
    [TestMethod]
    public void A_secret_of_the_form_is_the_Macs()
    {
        var secrets = All.GetProperty("secrets");
        Assert.AreEqual(secrets.GetProperty("max_value_bytes").GetInt32(), LoginSecret.MaxValueBytes);
        Assert.AreEqual(LoginSecret.MaxLabel, secrets.GetProperty("max_label").GetInt32());
        foreach (var row in secrets.GetProperty("secrets").EnumerateArray())
        {
            var name = row.Text("name");
            var made = new LoginSecret
            {
                Kind = row.Text("kind") == "login" ? SecretKind.Login : SecretKind.ApiKey, Url = row.Text("url")!, Username = row.Text("username")!,
                Password = row.Text("password")!, Totp = row.Text("totp")!, Env = row.Text("env")!,
            };
            Assert.AreEqual(row.Text("kind"), made.Kind.Word(), name);
            Assert.AreEqual(row.Text("title"), made.Title, name);
            Assert.AreEqual(row.Text("variable"), made.Variable, name);
            Assert.AreEqual(row.Text("table_address"), made.TableAddress, name);
            Assert.AreEqual(row.Text("problem"), made.Problem, name);
            Assert.AreEqual(row.Text("vault_problem"), made.VaultProblem, name);
            Assert.AreEqual(row.Text("value"), made.Problem is null ? Encoding.UTF8.GetString(made.Value()) : null, name);
        }
        var said = secrets.GetProperty("secrets").EnumerateArray().SelectMany(r => new[] { r.Text("problem"), r.Text("vault_problem") }).ToHashSet();
        foreach (var sentence in new[] { LoginSecret.ProviderLogin, LoginSecret.ProviderKey, LoginSecret.NoFingerprint, LoginSecret.TooLong(LoginSecret.MaxValueBytes) })
            Assert.IsTrue(said.Contains(sentence), "the vector holds the Mac's sentence: " + sentence);
        var lone = new LoginSecret { Kind = SecretKind.ApiKey, Env = "EXAMPLE_KEY", Password = "sk-test-" + (char)0xD800 + "0123456789abcdef" };
        Assert.AreEqual(LoginSecret.TooLong(LoginSecret.MaxValueBytes), lone.Problem);
        Assert.IsNull(lone.VaultProblem);
        Assert.ThrowsExactly<InvalidOperationException>(() => lone.Value());
    }

    /// <summary>**An address and a blank read as the Mac's fields read them.** Bug: an address with a user part or with no
    /// host that the form takes, or a pasted zero-width space that stays at the end of a user name.</summary>
    [TestMethod]
    public void An_address_and_a_blank_read_as_the_Macs_fields_read_them()
    {
        var reading = All.GetProperty("reading");
        foreach (var row in reading.GetProperty("addresses").EnumerateArray())
        {
            var text = row.Text("text")!;
            var isAddress = row.GetProperty("is_address").GetBoolean();
            Assert.AreEqual(isAddress, LoginSecret.IsAddress(text), text);
            if (!isAddress) continue;
            Assert.AreEqual(row.Text("host"), WebAddress.Parse(text)?.Host, text);
            var table = new LoginSecret { Kind = SecretKind.ApiKey, Url = text, Password = "sk-test-0123456789abcdefghij", Env = "EXAMPLE_KEY" }.TableAddress;
            // The one difference, written in TableAddress: a host beyond ASCII gives no address for the table.
            if (row.Text("host")!.All(char.IsAscii)) Assert.AreEqual(row.Text("table"), table, text);
            else Assert.IsNull(table, text);
        }
        var trims = reading.GetProperty("trims");
        List<int> Where(string name) => trims.GetProperty(name).EnumerateArray().Select(v => v.GetInt32()).ToList();
        List<int> Ours(Func<string, string> trim) => Enumerable.Range(0, 0x3100).Where(v => trim((char)v + "x") == "x").ToList();
        CollectionAssert.AreEqual(Where("whitespaces_and_newlines"), Ours(FoundationText.Trim));
        CollectionAssert.AreEqual(Where("whitespaces"), Ours(FoundationText.TrimBlanks));
        CollectionAssert.AreEqual(Where("newlines"), Enumerable.Range(0, 0x3100).Where(v => FoundationText.IsNewline((char)v)).ToList());
        CollectionAssert.AreEqual(reading.GetProperty("provider_sites").Texts(), ProviderSites.Sites);
        CollectionAssert.AreEqual(reading.GetProperty("provider_key_sites").Texts(), ProviderSites.KeySites);
        foreach (var code in reading.GetProperty("access_reasons").EnumerateObject())
            Assert.AreEqual(code.Value.GetString(), VaultWords.AccessReason(code.Name), code.Name);
    }

    /// <summary>**The owner access key is the Mac's**: its line, its fingerprint and its OpenSSH file, byte for byte, and a
    /// file of a copy reads back exactly where the Mac's reads it: a file whose public half, check numbers or private half
    /// do not belong together is no key, and a changed comment or padding, which the Mac does not check, is still the key.
    /// Bug: a file that <c>ssh -i</c> does not take, found on the day that the PC is lost; or a copy that the Mac restores
    /// and the PC does not.</summary>
    [TestMethod]
    public void The_owner_access_key_is_the_vectors()
    {
        var access = All.GetProperty("owner_access");
        var key = OwnerAccessKey.Of(access.Hex("seed_hex"))!;
        Assert.AreEqual(access.Text("public_line"), key.PublicLine);
        Assert.AreEqual(access.Text("fingerprint"), key.Fingerprint);
        Assert.AreEqual(Armored(access.Text("private_file")!), key.PrivateFile());
        Assert.IsNull(OwnerAccessKey.Read(Armored(access.Text("private_file")!)[5..]), "a broken first line");
        var refused = 0;
        foreach (var row in access.GetProperty("read").EnumerateArray())
        {
            var want = row.Text("seed_hex");
            Assert.AreEqual(want, OwnerAccessKey.Read(Armored(row.Text("text")!)) is { } read ? Convert.ToHexStringLower(read.Seed()) : null, row.Text("name"));
            if (want is null) refused++;
        }
        Assert.IsTrue(refused >= 4, "the vector has files that the Mac refuses");
    }

    /// <summary>A key file of the vector with its two armor lines back: the vector has <c>{BEGIN}</c> and <c>{END}</c> in their
    /// place, because the public copy of the apps refuses a text with the form of a private key.</summary>
    private static string Armored(string file) =>
        file.Replace("{BEGIN}", "-----BEGIN OPENSSH PRIVATE KEY-----", StringComparison.Ordinal)
            .Replace("{END}", "-----END OPENSSH PRIVATE KEY-----", StringComparison.Ordinal);

    /// <summary>**A reading of the vault decides as the Mac's**: what the decoder keeps of the hub's answer (a pin or a hub of
    /// a field of another type is none, a whole number written 22.0 is 22), the pool statements that it owes, and the key
    /// that a value is sealed to, or why none. Bug: a later hub's field of another type that fails the whole reading, a key
    /// that is not the pinned one that a form would seal to, a hub's machine that the Mac does not read, or a pool statement
    /// that the Mac does not owe.</summary>
    [TestMethod]
    public void A_reading_of_the_vault_decides_as_the_Macs()
    {
        foreach (var row in All.GetProperty("vault").GetProperty("readings").EnumerateArray())
        {
            var name = row.Text("name");
            using var answer = JsonDocument.Parse(row.Text("json")!);
            var reading = VaultReading.Read(answer.RootElement)!;
            Assert.AreEqual(row.Text("fleet_id"), reading.FleetId, name);
            Assert.AreEqual(row.GetProperty("program_behind").GetBoolean(), reading.ProgramBehind, name);
            var pin = All.GetProperty("seal").GetProperty("recipients")[0].Text("text")!;
            Assert.AreEqual(row.Text("trusted"), reading.Trusted(pin), name);
            var central = row.GetProperty("central");
            Assert.AreEqual(central.ValueKind == JsonValueKind.Null, reading.Central is null, name);
            if (reading.Central is { } c)
            {
                Assert.AreEqual(central.GetProperty("ok").GetBoolean(), c.Ok, name);
                Assert.AreEqual(central.Text("recipient"), c.Recipient, name);
                Assert.AreEqual(central.Text("fleet"), c.Fleet, name);
                Assert.AreEqual(central.Text("recovery"), c.Recovery, name);
                Assert.AreEqual(central.Text("source"), c.Source, name);
                Assert.AreEqual(central.Number("owner_keys"), (double?)c.OwnerKeys, name);
                Assert.AreEqual(central.Number("items"), (double?)c.Items, name);
                CollectionAssert.AreEqual(central.GetProperty("pool").Texts(), c.Pool.ToList(), name);
                CollectionAssert.AreEquivalent(central.GetProperty("pins").EnumerateObject().Select(p => p.Name).ToList(), c.Pins.Keys.ToList(), name);
                CollectionAssert.AreEqual(central.GetProperty("grants").EnumerateArray().Select(g => new CentralGrant(g.Text("login")!, g.Text("agent")!, g.Text("machine")!)).ToList(),
                                          c.Grants.ToList(), name);
            }
            var machines = row.GetProperty("machines").EnumerateArray().ToList();
            CollectionAssert.AreEqual(machines.Select(m => m.Text("machine")).ToList(), reading.Machines.Select(m => m.Machine).ToList(), name);
            foreach (var (want, got) in machines.Zip(reading.Machines))
            {
                Assert.AreEqual(want.Text("carrier"), got.Carrier, name);
                Assert.AreEqual(want.Text("broker_recipient"), got.BrokerRecipient, name);
                Assert.AreEqual(want.Text("pinned"), got.Pinned, name);
                Assert.AreEqual(want.Number("kept_pin_at"), (double?)got.KeptPinAt, name);
                Assert.AreEqual(want.GetProperty("kept_pin_known").GetBoolean(), got.KeptPinKnown, name);
                Assert.AreEqual(want.GetProperty("is_trusted").GetBoolean(), got.IsTrusted, name);
                Assert.AreEqual(want.GetProperty("can_be_trusted").GetBoolean(), got.CanBeTrusted, name);
                CollectionAssert.AreEqual(want.GetProperty("missing").Texts(), got.Missing.ToList(), name);
            }
            foreach (var held in row.GetProperty("held").EnumerateObject())
                CollectionAssert.AreEqual(held.Value.Texts(), reading.Held[held.Name].ToList(), name);
            var hub = row.GetProperty("hub");
            Assert.AreEqual(hub.ValueKind == JsonValueKind.Null, reading.Hub is null, name);
            if (reading.Hub is { } h)
                Assert.AreEqual(new VaultHub(hub.Text("machine")!, hub.Text("address"), hub.Text("user"), (long?)hub.Number("port")), h, name);
            CollectionAssert.AreEqual(row.GetProperty("pool_due").EnumerateArray().Select(d => new VaultPoolDue(d.Text("login")!, d.GetProperty("in").GetBoolean())).ToList(),
                                      reading.PoolDue.ToList(), name);
            string Key(bool served, string? given) => VaultSealKey.Of(reading, served, given) switch
            {
                { State: SealKeyState.Key, Key: { } key } => key,
                { State: SealKeyState.NoVault } => "no_vault",
                { State: SealKeyState.NoPin } => "no_pin",
                { State: SealKeyState.OtherKey } => "other_key",
                _ => "no_recovery",
            };
            var keys = row.GetProperty("seal_key");
            Assert.AreEqual(keys.Text("served, pinned"), Key(true, pin), name);
            Assert.AreEqual(keys.Text("not served"), Key(false, pin), name);
            Assert.AreEqual(keys.Text("no pin"), Key(true, null), name);
            Assert.AreEqual(keys.Text("another pin"), Key(true, AgeSeal.Bech32("age", new byte[32])), name);
        }
    }

    /// <summary>**What this PC does about the vault is the Mac's plan**, for each of the vector's facts, with "PC" for "Mac".
    /// Bug: a second computer that takes the vault over by itself, a step that runs for ever, or a server that the owner
    /// removed and that gets a pin again.</summary>
    [TestMethod]
    public void The_plan_is_the_Macs()
    {
        var vault = All.GetProperty("vault");
        var readings = vault.GetProperty("readings").EnumerateArray().ToDictionary(r => r.Text("name")!, r =>
        {
            using var answer = JsonDocument.Parse(r.Text("json")!);
            return VaultReading.Read(answer.RootElement);
        });
        VaultTries? Tries(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null
            : new VaultTries(value.GetProperty("failures").GetInt32(), value.GetProperty("last").GetDouble(), value.Text("reason")!);
        var seen = new HashSet<string>();
        foreach (var row in vault.GetProperty("plans").EnumerateArray())
        {
            var f = row.GetProperty("facts");
            var facts = new VaultFacts
            {
                KeyHeld = f.GetProperty("key_held").GetBoolean(), Pin = f.Text("pin"), HubOnRecord = f.GetProperty("hub_on_record").GetBoolean(),
                OtherOwner = f.GetProperty("other_owner").GetBoolean(), ConfirmedRecovery = f.Text("confirmed_recovery"),
                ConfirmedPins = f.GetProperty("confirmed_pins").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!),
                SignedAt = f.GetProperty("signed_at").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetDouble()),
                Install = Tries(f.GetProperty("install")), Recovery = Tries(f.GetProperty("recovery")), Update = Tries(f.GetProperty("update")),
                Servers = f.GetProperty("servers").EnumerateObject().ToDictionary(p => p.Name, p => Tries(p.Value)!),
                Removed = f.GetProperty("removed").Texts().ToHashSet(), RemovedKnown = f.GetProperty("removed_known").GetBoolean(),
                UpdateKnown = f.GetProperty("update_known").GetBoolean(), Now = f.GetProperty("now").GetDouble(),
            };
            var plan = VaultPlan.Of(row.Text("reading") is { } name ? readings[name] : null, facts);
            var want = row.GetProperty("plan");
            VaultStep Step(JsonElement value) => value.Text("step") switch
            {
                "trust" => new VaultStep.Trust(value.GetProperty("machines").Texts()),
                "install" => VaultStep.Install, "recover" => VaultStep.Recover, "update" => VaultStep.Update, "take_over" => VaultStep.TakeOver,
                _ => VaultStep.Nothing,
            };
            var need = want.GetProperty("vault");
            VaultNeed? wantNeed = need.ValueKind == JsonValueKind.Null ? null
                : need.TryGetProperty("retry", out var retry) ? new VaultNeed.Retry(Step(retry), need.Text("reason")!)
                : new VaultNeed.SetUp(Vectors.Pc(need.Text("set_up")));
            Assert.AreEqual(new VaultPlan(Step(want), wantNeed, want.GetProperty("servers").EnumerateArray()
                                              .Select(s => new VaultServerNeed(s.Text("machine")!, Vectors.Pc(s.Text("reason"))!)).ToList()),
                            plan, row.Text("name"));
            seen.Add(want.Text("step")!);
        }
        Assert.AreEqual(6, seen.Count, "the vector has each step");
        // another PC's owner key on this PC (the Mac's keyOtherMac of 25 November 2026, 61b264f33; the writer has no row of
        // it yet): no install, only Set up
        Assert.AreEqual(new VaultPlan(VaultStep.TakeOver, new VaultNeed.SetUp(null)),
                        VaultPlan.Of(readings["no vault"], new VaultFacts { KeyHeld = false, Pin = null, HubOnRecord = true, KeyOtherPc = true, Now = 1_763_700_000 }));
        Assert.AreEqual(VaultPlan.PinRefresh, vault.GetProperty("pin_refresh").GetDouble());
        Assert.AreEqual(VaultPlan.ResignWait, vault.GetProperty("resign_wait").GetDouble());
        Assert.AreEqual(VaultPlan.RetryEvery, vault.GetProperty("retry_every").GetDouble());
        Assert.AreEqual(VaultTries.Wait, vault.GetProperty("tries_wait").GetDouble());
        Assert.AreEqual(VaultTries.Most, vault.GetProperty("tries_most").GetInt32());
    }

    /// <summary>**The times of the statements and the clock's limit are the Mac's.** Bug: two changes of one grant in one
    /// second of which the vault keeps only the first, or a clock that once ran ahead that dates every later statement a day
    /// ahead, so that the vault refuses each one.</summary>
    [TestMethod]
    public void The_times_of_the_statements_and_the_clocks_limit_are_the_Macs()
    {
        var record = new MemoryClock();
        foreach (var row in All.GetProperty("grant_clock").EnumerateArray())
            Assert.AreEqual(row.GetProperty("at").GetInt64(), GrantClock.Next(row.Text("fleet")!, row.GetProperty("now").GetInt64(), record));
        Assert.AreEqual(GrantClock.Ahead, All.GetProperty("vault").GetProperty("grant_clock_ahead").GetInt64());
        foreach (var row in All.GetProperty("vault").GetProperty("clock").EnumerateArray())
            Assert.AreEqual(Vectors.Pc(row.Text("problem")), VaultPlan.ClockProblem(row.Number("hub_time"), row.Number("read_at")));
    }

    /// <summary>**The owner's replace and the pool statements of the hub's default are the statements that the vault
    /// reads**: their canonical texts, with the login in small letters and, for a replace, the SHA-256 of the sealed copy;
    /// the Mac's writer makes the pool's, and the maker holds them to the vault's own fields. Bug: a replace that the vault
    /// refuses as not canonical or that is about another copy, or a <c>pool</c> where the default's <c>default_pool</c>
    /// goes, which would end the owner's own "Only you".</summary>
    [TestMethod]
    public void The_owners_statements_are_the_ones_that_the_vault_reads()
    {
        var statements = All.GetProperty("vault").GetProperty("statements").EnumerateArray().ToList();
        Assert.AreEqual(2, statements.Count);
        foreach (var row in statements)
        {
            string fleet = row.Text("fleet")!, login = row.Text("login")!;
            var at = row.GetProperty("at").GetInt64();
            Assert.AreEqual(row.Text("statement"), row.Text("kind") == "default_pool" ? OwnerStatement.DefaultPool(fleet, login, at) : OwnerStatement.Unpool(fleet, login, at));
        }
        var vector = Vectors.Read("owner-replace.json");
        var fields = vector.GetProperty("fields");
        var sha256 = OwnerStatement.Checksum(vector.Text("sealed")!);
        Assert.AreEqual(fields.Text("sha256"), sha256);
        var statement = OwnerStatement.Replace(fields.Text("fleet")!, vector.Text("login_given")!, sha256, fields.GetProperty("at").GetInt64());
        Assert.AreEqual(vector.Text("statement"), statement);
        Assert.IsTrue(OwnerSignature.Verify(vector.Text("public_key")!, statement, vector.Text("signature")!));
    }

    /// <summary>**A request, its note and what it fits are the Mac's.** Bug: a request for a new value whose site would move
    /// the key's address, a made-up reference that the card's Replace would write under, a note that the hub refuses as too
    /// long, or the form's own password in a note that each agent reads.</summary>
    [TestMethod]
    public void A_request_its_note_and_what_it_fits_are_the_Macs()
    {
        var request = All.GetProperty("request");
        var entries = request.GetProperty("entries").EnumerateArray()
            .Select(e => new CatalogEntry(e.Text("title")!, e.Text("kind"), e.Text("env"), Note: e.Text("note"))).ToList();
        foreach (var row in request.GetProperty("requests").EnumerateArray())
        {
            var text = row.Text("json");
            using var json = JsonDocument.Parse(text!);
            var asked = SecretRequest.Read(json.RootElement);
            Assert.AreEqual(row.Text("kind"), asked.Kind.Word(), text);
            Assert.AreEqual(row.Text("env"), asked.Env, text);
            Assert.AreEqual(row.Text("site"), asked.Site, text);
            Assert.AreEqual(row.Text("saved"), asked.Saved, text);
            Assert.AreEqual(row.Text("note"), asked.Note, text);
            Assert.AreEqual(row.Text("account"), asked.Account, text);
            Assert.AreEqual(row.Text("replaces"), asked.Replaces, text);
            Assert.AreEqual(row.Text("form_address"), SecretValueReplace.FormAddress(asked), text);
            CollectionAssert.AreEquivalent(row.GetProperty("give").EnumerateObject().Select(g => g.Name + g.Value.GetString()).ToList(),
                                           asked.Proposal.Select(g => g.Key + g.Value.Word()).ToList(), text);
            CollectionAssert.AreEqual(row.GetProperty("note_goes").EnumerateArray().Select(v => v.GetBoolean()).ToList(),
                                      entries.Select(asked.NoteGoes).ToList(), text);
            CollectionAssert.AreEqual(row.GetProperty("fits").EnumerateArray().Select(v => v.GetBoolean()).ToList(),
                                      entries.Select(e => asked.Fits(e.Name)).ToList(), text);
        }
        foreach (var row in request.GetProperty("notes").EnumerateArray())
        {
            var text = row.Text("text")!;
            Assert.AreEqual(row.GetProperty("length").GetInt32(), SecretRequest.CodePoints(text), text);
            Assert.AreEqual(row.GetProperty("note_length").GetInt32(), SecretRequest.NoteLength(text), text);
            Assert.AreEqual(row.Text("one_line"), SecretRequest.OneLine(text, 200), text);
            Assert.AreEqual(row.Text("cut_note"), SecretRequest.Cut(text, 30, note: true), text);
            Assert.AreEqual(row.Text("cut"), SecretRequest.Cut(text, 30), text);
        }
        foreach (var row in request.GetProperty("holds").EnumerateArray())
            Assert.AreEqual(row.GetProperty("holds").GetBoolean(), SecretRequest.Holds(row.Text("value")!, row.Text("words")!), row.Text("words"));
    }

    /// <summary>**"Who can use it" of a replace is the Mac's**, for every level of now, choice of his and proposal. Bug: a
    /// Replace that takes a key back from an agent, or that gives a level that nobody chose.</summary>
    [TestMethod]
    public void The_rows_of_a_replace_are_the_Macs()
    {
        var rows = All.GetProperty("rows");
        var holders = rows.GetProperty("holders").Texts();
        static Dictionary<string, SecretGrant> Levels(JsonElement value) =>
            value.EnumerateObject().ToDictionary(p => p.Name, p => SecretGrants.Of(p.Value.GetString())!.Value);
        static string Print(IEnumerable<KeyValuePair<string, SecretGrant>> levels) =>
            string.Join(",", levels.OrderBy(l => l.Key, StringComparer.Ordinal).Select(l => l.Key + "=" + l.Value.Word()));
        static string Steps(JsonElement value) => string.Join(",", value.EnumerateArray().Select(s => s[0].GetString() + "=" + (s[1].Text() ?? "none")));
        static string Made(IEnumerable<(string Agent, SecretGrant? Grant)> steps) =>
            string.Join(",", steps.Select(s => s.Agent + "=" + (s.Grant?.Word() ?? "none")));
        foreach (var row in rows.GetProperty("cases").EnumerateArray())
        {
            var now = row.GetProperty("now") is { ValueKind: JsonValueKind.Object } held
                ? held.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!) : null;
            var touched = row.GetProperty("touched").Texts().ToHashSet();
            var proposed = row.GetProperty("proposed").Texts().ToHashSet();
            var shown = SecretReplaceAccess.Rows(now, holders, Levels(row.GetProperty("set")), touched, proposed);
            var what = row.GetRawText();
            Assert.AreEqual(Print(Levels(row.GetProperty("rows"))), Print(shown.Rows), what);
            Assert.AreEqual(string.Join(",", row.GetProperty("kept").Texts()), string.Join(",", shown.Touched.Order(StringComparer.Ordinal)), what);
            Assert.AreEqual(Print(Levels(row.GetProperty("raised"))), Print(shown.Raised), what);
            Assert.AreEqual(Print(Levels(row.GetProperty("own"))),
                            Print(SecretReplaceAccess.Own(shown.Rows, holders, shown.Touched, shown.Raised, Levels(row.GetProperty("proposal")), proposed)), what);
            Assert.AreEqual(Steps(row.GetProperty("changes")), Made(SecretReplaceAccess.Changes(now, holders, shown.Rows, shown.Touched, proposed, shown.Raised)), what);
            Assert.AreEqual(Steps(row.GetProperty("later")),
                            Made(SecretReplaceAccess.Changes(new Dictionary<string, string> { ["nova"] = "read" }, holders, shown.Rows, shown.Touched, proposed, shown.Raised)), what);
        }
    }

    /// <summary>**A key card's look is the Mac's**, for every state of its form and through the life of a card. Bug: a check
    /// over a step that failed, or a card that folds while its Try again is needed.</summary>
    [TestMethod]
    public void A_key_cards_look_is_the_Macs()
    {
        var look = All.GetProperty("look");
        static KeySaveLook? Of(JsonElement value) => value.Text() switch
        {
            "goes" => KeySaveLook.Goes, "saved" => KeySaveLook.Saved, "failed" => KeySaveLook.Failed, _ => null,
        };
        foreach (var row in look.GetProperty("looks").EnumerateArray())
            Assert.AreEqual(Of(row.GetProperty("look")),
                            KeySaveLooks.Of(row.GetProperty("done").ValueKind == JsonValueKind.Null ? null : row.GetProperty("done").GetBoolean(),
                                            row.GetProperty("warned").GetBoolean(), row.GetProperty("busy").GetBoolean(), row.GetProperty("saving").GetBoolean()),
                            row.GetRawText());
        var card = new KeySaveCard();
        foreach (var row in look.GetProperty("card").EnumerateArray())
        {
            switch (row.Text("act"))
            {
                case "take": Assert.AreEqual(row.GetProperty("took").GetBoolean(), card.Take(Of(row.GetProperty("given"))), row.GetRawText()); break;
                case "settle": card.Settle(); break;
                default: card.End(); break;
            }
            var what = row.GetRawText();
            Assert.AreEqual(Of(row.GetProperty("look")), card.Look, what);
            Assert.AreEqual(row.GetProperty("settled").GetBoolean(), card.Settled, what);
            Assert.AreEqual(row.GetProperty("collapsed").GetBoolean(), card.Collapsed(false), what);
            Assert.AreEqual(row.GetProperty("collapsed_expanded").GetBoolean(), card.Collapsed(true), what);
            Assert.AreEqual(row.GetProperty("holds").GetBoolean(), card.Holds, what);
            Assert.AreEqual(row.GetProperty("folds").GetBoolean(), card.Folds(true, false), what);
            Assert.AreEqual(row.GetProperty("folds_open").GetBoolean(), card.Folds(false, false), what);
            Assert.AreEqual(row.GetProperty("folds_expanded").GetBoolean(), card.Folds(true, true), what);
            Assert.AreEqual(row.GetProperty("form_open").GetBoolean(), card.ShowsForm(true), what);
            Assert.AreEqual(row.GetProperty("form_answered").GetBoolean(), card.ShowsForm(false), what);
        }
    }

    /// <summary>**Each copied sentence is a sentence of the Mac's catalog today**, with "PC" for "Mac" and <c>%@</c> for a
    /// slot. Bug: a Mac lane that changes a line of the secure form, and the PC that keeps the old words, unseen; or a
    /// sentence of the PC's own that has no yes of the owner.</summary>
    [TestMethod]
    public void Each_copied_sentence_is_in_the_Macs_catalog()
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "catalog", "Localizable.xcstrings")));
        var keys = document.RootElement.GetProperty("strings").EnumerateObject().Select(p => Regex.Replace(Vectors.Pc(p.Name)!, "%lld|%@", "%@"))
                           .ToHashSet(StringComparer.Ordinal);
        var texts = new List<string>();
        foreach (var type in new[] { typeof(VaultWords), typeof(VaultPlan) })
            texts.AddRange(type.GetFields().Where(f => f is { IsLiteral: true, FieldType.Name: "String" }).Select(f => (string)f.GetRawConstantValue()!));
        foreach (var method in typeof(VaultWords).GetMethods().Where(m => m is { IsStatic: true, Name: not "AccessReason" }))
            texts.Add((string)method.Invoke(null, method.GetParameters().Select(_ => (object)"%@").ToArray())!);
        texts.Add(VaultPlan.CentralBehind("%@"));
        Assert.IsTrue(texts.Count >= 35, "the test reads the texts: " + texts.Count);
        var missing = texts.Where(t => !keys.Contains(t)).ToList();
        Assert.AreEqual(0, missing.Count, "not in the Mac's catalog:\n" + string.Join("\n", missing));
    }
}

/// <summary>A clock record in memory.</summary>
internal sealed class MemoryClock : IGrantClockRecord
{
    private readonly Dictionary<string, long> kept = [];
    public long? Last(string fleet) => kept.TryGetValue(fleet, out var at) ? at : null;
    public void Keep(string fleet, long at) => kept[fleet] = at;
}
