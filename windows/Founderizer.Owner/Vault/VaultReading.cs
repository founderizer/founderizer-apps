using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace Founderizer.Owner.Vault;

/// <summary>The lossy reads of the vault's answers, each the Mac's <c>try? decodeIfPresent</c>: a field of another
/// type, or a field that is no key or id of its shape, is read as missing, and the rest of the reading stays.</summary>
internal static class Lossy
{
    public static JsonElement? Field(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var field) && field.ValueKind != JsonValueKind.Null
            ? field : null;

    public static string? Text(JsonElement value, string name) =>
        Field(value, name) is { ValueKind: JsonValueKind.String } field ? field.GetString() : null;

    public static bool True(JsonElement value, string name) => Field(value, name) is { ValueKind: JsonValueKind.True };

    /// <summary>A whole number as Swift's <c>Int</c> reads it, in 64 bits: also one written with a fraction of zero or an
    /// exponent (22.0 and 1e3, measured on Foundation's JSONDecoder), and never one with a fraction (22.5).</summary>
    public static long? Whole(JsonElement value, string name)
    {
        if (Field(value, name) is not { ValueKind: JsonValueKind.Number } field) return null;
        if (field.TryGetInt64(out var number)) return number;
        return field.TryGetDouble(out var real) && real == Math.Floor(real) && real >= -9.2233720368547758E18 && real < 9.2233720368547758E18
            ? (long)real : null;
    }

    public static double? Number(JsonElement value, string name) =>
        Field(value, name) is { ValueKind: JsonValueKind.Number } field && field.TryGetDouble(out var number) ? number : null;

    /// <summary>A list of texts, or null when the field is no such list (one entry of another type spoils it, as in Swift).</summary>
    public static List<string>? Texts(JsonElement value, string name)
    {
        if (Field(value, name) is not { ValueKind: JsonValueKind.Array } list) return null;
        var texts = new List<string>();
        foreach (var item in list.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String) return null;
            texts.Add(item.GetString()!);
        }
        return texts;
    }

    /// <summary>A field that Swift's <c>decodeIfPresent</c> of a type of this kind reads: missing, null, or of that kind. A
    /// field of another kind fails the decode of the whole object that holds it.</summary>
    public static bool Fits(JsonElement value, string name, JsonValueKind kind) => Field(value, name) is not { } field || field.ValueKind == kind;

    /// <summary>An <c>age1…</c> recipient, or null: a field that is not one is read as missing.</summary>
    public static string? Recipient(JsonElement value, string name) =>
        Text(value, name) is { } text && AgeSeal.PublicKeyOf(text) is not null ? text : null;
}

/// <summary>The central vault's own status, as the hub last read it (the Mac's <c>CentralStatus</c>). It holds keys and
/// counts, never a value.</summary>
public sealed record CentralStatus(bool Ok, string? Recipient, string? StoreRecipient, string? Fleet, long? OwnerKeys,
                                   IReadOnlyDictionary<string, CentralPin> Pins, string? Recovery, IReadOnlyList<CentralGrant> Grants,
                                   IReadOnlyList<string> Pool, long? Items, string? Source)
{
    public static CentralStatus? Read(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object) return null;
        var pins = new Dictionary<string, CentralPin>(StringComparer.Ordinal);
        if (Lossy.Field(value, "pins") is { ValueKind: JsonValueKind.Object } given)
            foreach (var pin in given.EnumerateObject())
                if (pin.Value.ValueKind == JsonValueKind.Object && Lossy.Fits(pin.Value, "recipient", JsonValueKind.String) &&
                    Lossy.Fits(pin.Value, "at", JsonValueKind.Number))
                    pins[pin.Name] = new CentralPin(Lossy.Text(pin.Value, "recipient"), Lossy.Number(pin.Value, "at"));
        var grants = new List<CentralGrant>();
        if (Lossy.Field(value, "grants") is { ValueKind: JsonValueKind.Array } list)
            foreach (var grant in list.EnumerateArray())
                if (Lossy.Text(grant, "login") is { } login && Lossy.Text(grant, "agent") is { } agent &&
                    Lossy.Text(grant, "machine") is { } machine && VaultIds.IsReference(login))
                    grants.Add(new CentralGrant(login, agent, machine));
        return new CentralStatus(Lossy.True(value, "ok"), Lossy.Recipient(value, "recipient"), Lossy.Recipient(value, "store_recipient"),
                                 Lossy.Text(value, "fleet") is { } fleet && VaultIds.IsFleet(fleet) ? fleet : null,
                                 Lossy.Whole(value, "owner_keys"), pins, Lossy.Recipient(value, "recovery"), grants,
                                 (Lossy.Texts(value, "pool") ?? []).Where(VaultIds.IsReference).ToList(), Lossy.Whole(value, "items"),
                                 Lossy.Text(value, "source") is { } source && VaultIds.IsProgram(source) ? source : null);
    }
}

/// <summary>One server the owner signed, by machine. Its recipient is kept as the hub gives it.</summary>
public sealed record CentralPin(string? Recipient, double? At);

/// <summary>One grant that the owner signed and has not taken back (owner feature <c>signed_grants</c>).</summary>
public sealed record CentralGrant(string Login, string Agent, string Machine);

/// <summary>One pool statement that the owner's computer owes the central vault (the Mac's <c>VaultPoolDue</c>):
/// <paramref name="In"/> true for a secret that the fleet manager may give by the standing that counts and that the vault's
/// signed pool lacks, false for one of that pool that is the owner's alone now.</summary>
public sealed record VaultPoolDue(string Login, bool In);

/// <summary>The central vault's machine, which is the hub's own, as <c>GET /ui/vault</c> names it.</summary>
public sealed record VaultHub(string Machine, string? Address, string? User, long? Port);

/// <summary>One machine with a worker or a lead, as the central vault sees it (the Mac's <c>VaultMachine</c>).</summary>
public sealed record VaultMachine(string Machine, string? Carrier, string? BrokerRecipient, string? Pinned, bool Matches,
                                  IReadOnlyList<string> Missing, long? KeptPinAt, bool KeptPinKnown)
{
    /// <summary>The central vault seals for this machine now: its vault reports a key, and the owner pinned that very key.</summary>
    public bool IsTrusted => Carrier is not null && BrokerRecipient is not null && Pinned == BrokerRecipient && Matches;

    /// <summary>A machine whose key the owner can pin: its helper carries copies, and its vault reports its key.</summary>
    public bool CanBeTrusted => Carrier is not null && BrokerRecipient is not null && VaultIds.IsMachine(Machine);

    /// <summary>The machine of the hub's answer, or null when it names no machine (the Mac's decode then drops it).</summary>
    public static VaultMachine? Read(JsonElement value)
    {
        if (Lossy.Field(value, "machine") is not { ValueKind: JsonValueKind.String } machine) return null;
        return new VaultMachine(machine.GetString()!, Lossy.Text(value, "carrier"), Lossy.Recipient(value, "broker_recipient"),
                                Lossy.Recipient(value, "pinned"), Lossy.True(value, "matches"), Lossy.Texts(value, "missing") ?? [],
                                Lossy.Whole(value, "kept_pin_at"),
                                value.ValueKind == JsonValueKind.Object && value.TryGetProperty("kept_pin_at", out _));
    }
}

/// <summary>**GET /ui/vault** (the Mac's <c>VaultReading</c>): the central vault's status (null while there is none), the
/// hub's last word about reading it, each machine's pin, and which secrets each machine holds now. <c>fleet</c> comes even
/// without a central vault. A field the app cannot read is left out; nothing in it is a value.</summary>
public sealed record VaultReading(string Db, string? Fleet, CentralStatus? Central, double? ReadAt, string? Error,
                                  IReadOnlyList<VaultMachine> Machines, IReadOnlyDictionary<string, IReadOnlyList<string>> Held,
                                  string? Program, VaultHub? Hub)
{
    /// <summary>The reading of an answer, with the Mac's checks: a <c>db</c> as text, no machine twice. Null for an
    /// answer that is not one.</summary>
    public static VaultReading? Read(JsonElement value)
    {
        if (Lossy.Field(value, "db") is not { ValueKind: JsonValueKind.String } db) return null;
        var machines = new List<VaultMachine>();
        if (Lossy.Field(value, "machines") is { ValueKind: JsonValueKind.Array } list)
            foreach (var item in list.EnumerateArray())
                if (VaultMachine.Read(item) is { } machine) machines.Add(machine);
        var held = new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal);
        if (Lossy.Field(value, "held") is { ValueKind: JsonValueKind.Object } given)
        {
            foreach (var entry in given.EnumerateObject())
            {
                if (Lossy.Texts(given, entry.Name) is not { } texts) { held.Clear(); break; }      // one bad entry: none, as in Swift
                held[entry.Name] = texts.Where(VaultIds.IsReference).ToList();
            }
        }
        VaultHub? hub = null;
        if (Lossy.Field(value, "hub") is { ValueKind: JsonValueKind.Object } named && Lossy.Text(named, "machine") is { } name &&
            VaultIds.IsMachine(name) && Lossy.Fits(named, "address", JsonValueKind.String) && Lossy.Fits(named, "ssh", JsonValueKind.Object))
        {
            var ssh = Lossy.Field(named, "ssh");
            // Swift's Int: a whole number of 64 bits, or the hub is dropped
            if (ssh is not { } s || Lossy.Fits(s, "user", JsonValueKind.String) && (Lossy.Field(s, "port") is null || Lossy.Whole(s, "port") is not null))
                hub = new VaultHub(name, Lossy.Text(named, "address"), ssh is { } u ? Lossy.Text(u, "user") : null,
                                   ssh is { } t ? Lossy.Whole(t, "port") : null);
        }
        var due = new List<VaultPoolDue>();
        if (Lossy.Field(value, "standing") is { ValueKind: JsonValueKind.Object } standing &&
            Lossy.Field(standing, "due") is { ValueKind: JsonValueKind.Array } owed)
            foreach (var one in owed.EnumerateArray())
                if (Lossy.Text(one, "login") is { } login && VaultIds.IsReference(login) &&
                    Lossy.Field(one, "in") is { ValueKind: JsonValueKind.True or JsonValueKind.False } flag)
                    due.Add(new VaultPoolDue(login, flag.GetBoolean()));
        var reading = new VaultReading(db.GetString()!, Lossy.Text(value, "fleet") is { } fleet && VaultIds.IsFleet(fleet) ? fleet : null,
                                       Lossy.Field(value, "central") is { } central ? CentralStatus.Read(central) : null,
                                       Lossy.Number(value, "read_at"), Lossy.Text(value, "error"), machines, held,
                                       Lossy.Text(value, "program") is { } program && VaultIds.IsProgram(program) ? program : null, hub)
        {
            PoolDue = due,
        };
        return reading.Machines.Select(m => m.Machine).Distinct(StringComparer.Ordinal).Count() == reading.Machines.Count ? reading : null;
    }

    /// <summary>The central vault runs another program than the <c>vault.py</c> of the hub's release, as both of them say.
    /// A side that says nothing is not behind.</summary>
    public bool ProgramBehind => Central is { Ok: true, Source: { } running } && Program is { } release && running != release;

    /// <summary>The fleet this reading is about: the hub's own word, else the vault's.</summary>
    public string? FleetId => Fleet ?? Central?.Fleet;

    /// <summary>**The pool statements that this computer owes the central vault** (owner feature <c>pool_default</c>, owner
    /// API 1.328, the Mac's <c>poolDue</c>): <c>standing.due</c>, which the hub gives only with a fresh status read after
    /// the last statement that it passed on, so a statement on its way is never owed twice. An entry that is no reference
    /// with a true or false <c>in</c> is left out. Empty from a hub that does not say.</summary>
    public IReadOnlyList<VaultPoolDue> PoolDue { get; init; } = [];

    /// <summary>The central vault's key, only while the vault answers and the key is the one this computer pinned at Set
    /// up: the one key a save seals to. Any other key, or none, is null.</summary>
    public string? Trusted(string? pin) => Central is { Ok: true, Recipient: { } recipient } && recipient == pin ? recipient : null;
}

/// <summary>**The key that a new secret is sealed to, or why nothing is sealed now** (the Mac's <c>VaultSealKey</c>). A
/// value is sealed only to the central vault's own key, and only while that key is the one that this computer pinned at
/// the vault's Set up: a hub that is broken into can name a key of its own, and a value sealed to it would be the
/// attacker's.</summary>
public enum SealKeyState { Key, NoVault, NoPin, OtherKey, NoRecovery }

public sealed record VaultSealKey(SealKeyState State, string? Key = null)
{
    /// <summary>The order: no vault, then no pin, then another key, then no recovery key. <paramref name="served"/>: the
    /// hub's features name <c>central_vault</c>. <paramref name="pin"/>: the key this computer pinned for this hub and
    /// the reading's fleet.</summary>
    public static VaultSealKey Of(VaultReading? reading, bool served, string? pin)
    {
        if (!served || reading?.FleetId is null || reading.Central is not { Ok: true } central) return new(SealKeyState.NoVault);
        if (pin is null) return new(SealKeyState.NoPin);
        if (reading.Trusted(pin) is not { } recipient) return new(SealKeyState.OtherKey);
        if (central.Recovery is null) return new(SealKeyState.NoRecovery);
        return new(SealKeyState.Key, recipient);
    }
}

/// <summary>**The central vault's key as this computer pinned it** (the Mac's <c>CentralVaultPins</c>), by hub address
/// and fleet: the recipient that the install printed on the hub's own machine, which reached this computer over its own
/// SSH connection and not through the hub. A public key, so a plain file of the app's folder is the place for it.</summary>
public interface ICentralVaultPins
{
    /// <summary>The pin of this hub and fleet, or null where none is kept. Throws for a record that does not read.</summary>
    string? Recipient(Uri hub, string fleet);

    /// <summary>Pins the key that the install printed, **only where <see cref="CentralVaultPin.Refusal"/> lets it**: at the
    /// owner's Set up (<paramref name="setUp"/>), where no pin is kept, or for the same key again. Null when the key is the
    /// pin now; else the words of why not, and nothing is written.</summary>
    string? Pin(string recipient, Uri hub, string fleet, bool setUp);
}

/// <summary>**When a key that the central vault's install printed may become the pin** (the Mac's
/// <c>CentralVaultPins.refusal</c>, the validation of 23 November 2026, M2): the one copy of the rule, which
/// <see cref="ICentralVaultPins.Pin"/> applies and L6's <c>VaultInstall.PinRefusal</c> gives.</summary>
public static class CentralVaultPin
{
    /// <summary>Why <paramref name="printed"/> may not become the pin, or null when it may. The vault's keys never change in an
    /// install or an update: its install makes a key only where there is none, and keeps what it finds. So at an update, or
    /// at the app's own install, a key that is not the pin that this PC holds (<paramref name="held"/>) comes only from a
    /// fault, and the pin stays, with the words of a hub that names another key, whose way out is Set up. Only the owner's
    /// Set up (<paramref name="setUp"/>) and a first install, with no pin held, write a pin.</summary>
    public static string? Refusal(string printed, string? held, bool setUp) =>
        setUp || held is null || held == printed ? null : VaultPlan.OtherKey;
}

/// <summary>The pins in one JSON file, written whole or not at all: <c>{"&lt;hub&gt;|&lt;fleet&gt;": "age1…"}</c>, the
/// Mac's names. **A file that does not read throws** (<see cref="InvalidDataException"/>), at a read and at a pin that
/// is not the owner's Set up: a damaged file is not "no pin", which would let an install pin a key with no Set up. Nothing
/// is sealed until the file reads again or a new Set up writes a new one: **the owner's Set up keeps a copy of the file that
/// does not read** (<c>&lt;file&gt;.unreadable</c>, then <c>-2</c> and on: the other hubs' pins for a person to read) and
/// writes a new file with its one pin in the damaged one's place.</summary>
public sealed class CentralVaultPinsFile(string path) : ICentralVaultPins
{
    private readonly object gate = new();

    public string? Recipient(Uri hub, string fleet)
    {
        lock (gate) return Read().GetValueOrDefault(Name(hub, fleet));
    }

    public string? Pin(string recipient, Uri hub, string fleet, bool setUp)
    {
        if (AgeSeal.PublicKeyOf(recipient) is null || !VaultIds.IsFleet(fleet)) throw new ArgumentException("not a vault key or a fleet");
        lock (gate)
        {
            Dictionary<string, string> all;
            try
            {
                all = Read();
            }
            catch (InvalidDataException) when (setUp)
            {
                // A copy first, and then the new file takes the damaged one's place in one step (KeptFile.Write moves over
                // it): the path holds the damaged file, which throws, or the new one, and never no file, which would read as
                // "no pin". A copy that fails changes nothing.
                File.Copy(path, NextUnreadable(), overwrite: false);
                all = [];
            }
            if (CentralVaultPin.Refusal(recipient, all.GetValueOrDefault(Name(hub, fleet)), setUp) is { } refused) return refused;
            all[Name(hub, fleet)] = recipient;
            KeptFile.Write(path, JsonSerializer.SerializeToUtf8Bytes(all, VaultJson.Default.DictionaryStringString));
            return null;
        }
    }

    private static string Name(Uri hub, string fleet) => $"{hub.AbsoluteUri}|{fleet}";

    /// <summary>Where a Set up keeps the first copy of a pins file that does not read; a later copy has a number after it.</summary>
    public string Unreadable => path + ".unreadable";

    /// <summary>The name of a new copy of a pins file that does not read: <see cref="Unreadable"/>, or for a later one
    /// <c>-2</c>, <c>-3</c> and on after it, so that no copy writes over an earlier one, which can be the only record of
    /// the other hubs' pins.</summary>
    private string NextUnreadable()
    {
        var name = Unreadable;
        for (var n = 2; File.Exists(name); n++) name = $"{Unreadable}-{n}";
        return name;
    }

    private Dictionary<string, string> Read()
    {
        byte[] bytes;
        try
        {
            bytes = File.ReadAllBytes(path);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            return [];          // only a file that is not there is no pin: any other failure of the read throws
        }
        try
        {
            return JsonSerializer.Deserialize(bytes, VaultJson.Default.DictionaryStringString)
                   ?? throw new InvalidDataException("the pins file holds no pins");
        }
        catch (JsonException e)
        {
            throw new InvalidDataException("the pins file does not read", e);
        }
    }
}

/// <summary>A small file of the app's own records, written whole or not at all (a new file, then moved over the old one),
/// and on a system with file modes for this user alone.</summary>
internal static class KeptFile
{
    public static void Write(string path, byte[] bytes)
    {
        if (Path.GetDirectoryName(Path.GetFullPath(path)) is { } folder) Directory.CreateDirectory(folder);
        var temporary = path + ".new";
        var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using (var stream = new FileStream(temporary, options))
        {
            stream.Write(bytes);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temporary, path, overwrite: true);
    }
}
