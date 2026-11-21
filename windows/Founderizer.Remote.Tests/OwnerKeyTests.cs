using System;
using System.Collections.Generic;
using System.Formats.Asn1;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Remote.Tests;

/// <summary>
/// The owner's key, once (plan 5.5; piece L1a; the owner's "Choose key, as Mac" and "One field, only then" of 21
/// November 2026): <see cref="OwnerKeyFile.Check"/> and <see cref="RemoteLogin.KeyOnce"/>, against a scratch sshd that
/// each test starts. Each key is made by ssh-keygen in the test; no key is a file of the repository.
/// </summary>
[TestClass]
public sealed class OwnerKeyTests
{
    /// <summary>
    /// The owner's key opens a server that holds it and runs the program, and after the call the caller's two arrays
    /// hold nothing: the file's bytes and the passphrase are zero. The check before it changed neither. The passphrase
    /// is in no line, no output and no line of the server's log. Bugs: the owner's key kept in the PC's memory after
    /// its one use (the owner's words: "keeps nothing"); a check that clears the arrays, so the call gets zeros; the
    /// passphrase written where a page or a log reads it.
    /// </summary>
    [TestMethod]
    public async Task A_key_that_the_server_holds_runs_the_program_and_the_caller_keeps_nothing_of_it()
    {
        var passphrase = OwnerKeys.NewPassphrase();
        var owner = OwnerKeys.Make("ed25519", null, passphrase);
        await using var app = new App();
        using var sshd = new ScratchSshd([owner.PublicLine]);
        var file = (byte[])owner.File.Clone();
        var chars = passphrase.ToCharArray();
        Assert.AreEqual(OwnerKeyCheck.Usable, OwnerKeyFile.Check(file, chars));
        CollectionAssert.AreEqual(owner.File, file, "The check changed the file's bytes.");
        CollectionAssert.AreEqual(passphrase.ToCharArray(), chars, "The check changed the passphrase.");

        var (result, lines) = await app.Run(sshd.Target, "echo in; printf 'err\\n' >&2", login: new RemoteLogin.KeyOnce(file, chars));
        Assert.IsNull(result.Failure);
        Assert.AreEqual(0, result.ExitStatus);
        Assert.AreEqual("in\n", result.Output);
        Assert.AreEqual("err\n", result.Errors);
        Assert.IsTrue(Zero(file), "The caller's key file was not cleared.");
        Assert.IsTrue(Zero(chars), "The caller's passphrase was not cleared.");
        Assert.AreEqual(0, app.KeyReads, "The app's own key was read for a call with the owner's key.");
        var log = sshd.Log();
        StringAssert.Contains(log, "Accepted publickey");
        foreach (var text in lines.Append(result.Output).Append(result.Errors).Append(log))
            Assert.IsFalse(text.Contains(passphrase, StringComparison.Ordinal), "The passphrase is in: " + text);
    }

    /// <summary>
    /// A key that the server does not hold is LoginRefused, and the app's own key is not tried in that call: the server
    /// holds the app's key, so a fall back to it would log in. The caller's array is zero after the refusal. Bugs: a
    /// call with the owner's key that also offers the app's key (the step would then pass with the wrong key, and the
    /// owner's key would never be checked); the refusal read as no answer; the owner's key left after a refusal.
    /// </summary>
    [TestMethod]
    public async Task A_key_that_the_server_does_not_hold_is_LoginRefused_and_the_app_key_is_not_tried()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        var file = OwnerKeys.Make("ed25519", null, null).File;
        var (result, _) = await app.Run(sshd.Target, "echo in", login: new RemoteLogin.KeyOnce(file, null));
        Assert.AreEqual(RemoteFailure.LoginRefused, result.Failure);
        Assert.IsNull(result.ExitStatus);
        Assert.AreEqual("", result.Output);
        Assert.AreEqual(0, app.KeyReads, "The app's own key was read for a call with the owner's key.");
        Assert.IsTrue(Zero(file), "The caller's key file was not cleared after the refusal.");
        Assert.IsFalse(sshd.Log().Contains("Accepted", StringComparison.Ordinal), sshd.Log());
    }

    /// <summary>
    /// A cancel ends a call with the owner's key, and the caller's two arrays are zero after it. Bug: the key cleared
    /// only when the call ends with the program's end, so a canceled step keeps it.
    /// </summary>
    [TestMethod]
    public async Task A_canceled_call_with_a_key_keeps_nothing_of_it()
    {
        var passphrase = OwnerKeys.NewPassphrase();
        var owner = OwnerKeys.Make("ecdsa", null, passphrase);
        await using var app = new App();
        using var sshd = new ScratchSshd([owner.PublicLine]);
        var file = owner.File;
        var chars = passphrase.ToCharArray();
        using var cancel = new CancellationTokenSource();
        var (result, lines) = await app.Run(sshd.Target, "echo started; sleep 60; echo late", login: new RemoteLogin.KeyOnce(file, chars),
                                            cancel: cancel.Token, also: text => { if (text == "started") cancel.Cancel(); });
        Assert.AreEqual(RemoteFailure.Canceled, result.Failure);
        CollectionAssert.AreEqual(new[] { "started" }, lines);
        Assert.IsTrue(Zero(file), "The caller's key file was not cleared after the cancel.");
        Assert.IsTrue(Zero(chars), "The caller's passphrase was not cleared after the cancel.");
    }

    /// <summary>
    /// A file that is no usable key stops before any connection, with the check's word for it: random bytes, a public
    /// key, an empty file, a key padded past 64 KiB, an RSA key whose private numbers were changed (it reads, and its
    /// signature does not check), a key with a passphrase and none or an empty one (NeedsPassphrase), and a wrong
    /// passphrase (WrongPassphrase). The call with such a file throws, its exception holds no passphrase, its arrays are
    /// zero, and the server's log has no connection but the one of the rig's probe that waited for its port. Bugs: a wrong file or a wrong passphrase costs a login try
    /// at the server, which counts against the owner (MaxAuthTries, a ban by fail2ban); a key with a passphrase read as
    /// no key, so the field never shows; an empty field read as a passphrase.
    /// </summary>
    [TestMethod]
    public async Task A_file_that_does_not_open_stops_before_any_connection()
    {
        var passphrase = OwnerKeys.NewPassphrase();
        var locked = OwnerKeys.Make("ed25519", null, passphrase);
        var plain = OwnerKeys.Make("ed25519", null, null);
        await using var app = new App();
        using var sshd = new ScratchSshd([locked.PublicLine, plain.PublicLine, app.Key.PublicLine]);
        var padded = plain.File.Concat(Enumerable.Repeat((byte)'\n', OwnerKeyFile.MaxLength)).ToArray();
        var cases = new (string Name, byte[] File, char[]? Passphrase, OwnerKeyCheck State)[]
        {
            ("random bytes", RandomNumberGenerator.GetBytes(411), null, OwnerKeyCheck.NotAKey),
            ("a public key", Encoding.ASCII.GetBytes(plain.PublicLine + " owner@example.com\n"), null, OwnerKeyCheck.NotAKey),
            ("an empty file", [], null, OwnerKeyCheck.NotAKey),
            ("a key padded past 64 KiB", padded, null, OwnerKeyCheck.NotAKey),
            ("an RSA key whose private numbers changed", DamagedRsa(), null, OwnerKeyCheck.NotAKey),
            ("a key with a passphrase, none given", locked.File, null, OwnerKeyCheck.NeedsPassphrase),
            ("a key with a passphrase, an empty one", locked.File, [], OwnerKeyCheck.NeedsPassphrase),
            ("a wrong passphrase", locked.File, (passphrase + "x").ToCharArray(), OwnerKeyCheck.WrongPassphrase),
        };
        Assert.AreEqual(OwnerKeyCheck.Usable, OwnerKeyFile.Check(plain.File, null), "the same key, not padded");
        foreach (var (name, bytes, given, state) in cases)
        {
            Assert.AreEqual(state, OwnerKeyFile.Check(bytes, given), name);
            var file = (byte[])bytes.Clone();
            var chars = (char[]?)given?.Clone();
            var call = new RemoteCall(sshd.Target, "echo in", null, new RemoteLogin.KeyOnce(file, chars), HostKeyRule.TakeNew,
                                      RemoteCall.ConnectTimeout);
            var thrown = await Assert.ThrowsExactlyAsync<ArgumentException>(() => app.Remote.RunAsync(call, null, CancellationToken.None), name);
            Assert.IsFalse(thrown.ToString().Contains(passphrase, StringComparison.Ordinal), name + ": " + thrown);
            Assert.IsTrue(Zero(file), name + ": the caller's key file was not cleared.");
            if (chars is not null) Assert.IsTrue(Zero(chars), name + ": the caller's passphrase was not cleared.");
        }
        await Task.Delay(500);
        var log = sshd.Log();
        Assert.AreEqual(1, log.Split('\n').Count(l => l.StartsWith("Connection from ", StringComparison.Ordinal)), log);
        Assert.AreEqual(0, app.KeyReads);
    }

    /// <summary>
    /// Each format of this machine's ssh-keygen opens, with and without a passphrase, and logs in: OpenSSH's own
    /// (Ed25519, RSA, ECDSA; bcrypt and AES-256-CTR with a passphrase), PEM (PKCS#1 RSA; traditional AES-128-CBC with a
    /// passphrase) and PKCS#8 (RSA; PBES2 with a passphrase). A key with no passphrase is usable whatever the field
    /// holds. Bugs: a format that the library does not read (plan 5.5 gave it as an estimate, not measured); an
    /// encrypted PKCS#8 key read as no key, because its reader says nothing of a missing passphrase; a passphrase with a
    /// letter outside ASCII turned into other bytes than ssh-keygen used. (ECDSA in PEM: the container's test, because
    /// this machine's ssh-keygen with LibreSSL writes its curve as numbers, which SSH.NET does not read.)
    /// </summary>
    [TestMethod]
    public async Task Each_key_format_of_ssh_keygen_opens_with_and_without_a_passphrase()
    {
        var passphrase = OwnerKeys.NewPassphrase();
        var made = new List<(string Name, OwnerKeys.Made Key, string? Passphrase, string Head)>();
        foreach (var (type, format, plainHead, lockedHead) in new (string, string?, string, string)[]
                 {
                     ("ed25519", null, "-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN OPENSSH PRIVATE KEY-----"),
                     ("rsa", null, "-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN OPENSSH PRIVATE KEY-----"),
                     ("ecdsa", null, "-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN OPENSSH PRIVATE KEY-----"),
                     ("rsa", "PEM", "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED"),
                     ("rsa", "PKCS8", "-----BEGIN PRIVATE KEY-----", "-----BEGIN ENCRYPTED PRIVATE KEY-----"),
                 })
        {
            var label = $"{type} {format ?? "OpenSSH"}";
            made.Add((label + ", no passphrase", OwnerKeys.Make(type, format, null), null, plainHead));
            made.Add((label + ", a passphrase", OwnerKeys.Make(type, format, passphrase), passphrase, lockedHead));
        }
        await using var app = new App();
        using var sshd = new ScratchSshd(made.Select(m => m.Key.PublicLine));
        foreach (var (name, key, given, head) in made)
        {
            Assert.IsTrue(Encoding.ASCII.GetString(key.File).StartsWith(head, StringComparison.Ordinal), name + " is not the format named.");
            await Opens(app, sshd.Target, name, key, given);
        }
    }

    /// <summary>
    /// An RSA key never signs with SHA-1 (ssh-rsa), as the Mac's ssh (OpenSSH 10) never does: a server that takes only
    /// that way refuses the key. Bug: SSH.NET offers ssh-rsa first, and on an old server the owner's key signs with
    /// SHA-1.
    /// </summary>
    [TestMethod]
    public async Task An_RSA_key_never_signs_with_SHA1()
    {
        var owner = OwnerKeys.Make("rsa", "PEM", null);
        await using var app = new App();
        using var sshd = new ScratchSshd([owner.PublicLine], extra: "PubkeyAcceptedAlgorithms ssh-rsa");
        var (result, _) = await app.Run(sshd.Target, "echo in", login: new RemoteLogin.KeyOnce(owner.File, null));
        Assert.AreEqual(RemoteFailure.LoginRefused, result.Failure, sshd.Log());
    }

    /// <summary>What the check says of a key with this passphrase or none, and a call with it that runs.</summary>
    internal static async Task Opens(App app, RemoteTarget target, string name, OwnerKeys.Made key, string? passphrase)
    {
        if (passphrase is null)
        {
            Assert.AreEqual(OwnerKeyCheck.Usable, OwnerKeyFile.Check(key.File, null), name);
            Assert.AreEqual(OwnerKeyCheck.Usable, OwnerKeyFile.Check(key.File, "not-asked-for".ToCharArray()), name);
        }
        else
        {
            Assert.AreEqual(OwnerKeyCheck.NeedsPassphrase, OwnerKeyFile.Check(key.File, null), name);
            Assert.AreEqual(OwnerKeyCheck.WrongPassphrase, OwnerKeyFile.Check(key.File, (passphrase + "x").ToCharArray()), name);
            Assert.AreEqual(OwnerKeyCheck.Usable, OwnerKeyFile.Check(key.File, passphrase.ToCharArray()), name);
        }
        var (result, _) = await app.Run(target, "echo in", login: new RemoteLogin.KeyOnce((byte[])key.File.Clone(), passphrase?.ToCharArray()));
        Assert.IsNull(result.Failure, name);
        Assert.AreEqual(0, result.ExitStatus, name);
        Assert.AreEqual("in\n", result.Output, name);
    }

    internal static bool Zero(byte[] bytes) => bytes.All(b => b == 0);

    internal static bool Zero(char[] chars) => chars.All(c => c == '\0');

    /// <summary>
    /// An RSA key in PKCS#1 PEM whose private exponent and first CRT exponent were changed by one bit: it reads as a
    /// key, and no signature that it makes checks with its public half.
    /// </summary>
    private static byte[] DamagedRsa()
    {
        using var rsa = RSA.Create(2048);
        var p = rsa.ExportParameters(includePrivateParameters: true);
        p.D![^1] ^= 0x02;
        p.DP![^1] ^= 0x02;
        var writer = new AsnWriter(AsnEncodingRules.DER);
        using (writer.PushSequence())
        {
            writer.WriteInteger(0);
            foreach (var part in new[] { p.Modulus!, p.Exponent!, p.D, p.P!, p.Q!, p.DP, p.DQ!, p.InverseQ! })
                writer.WriteIntegerUnsigned(part);
        }
        return Encoding.ASCII.GetBytes(PemEncoding.WriteString("RSA PRIVATE KEY", writer.Encode()) + "\n");
    }
}

/// <summary>
/// The owner's keys of two other tools, made in a container of the test image that each key's run removes: PuTTY's
/// puttygen 0.81 (<c>.ppk</c>), and Ubuntu's ssh-keygen (OpenSSH 9.6 with OpenSSL 3: ECDSA in PEM and PKCS#8, with its
/// curve by name, as OpenSSL writes it; and DSA, which OpenSSH 10 no longer makes).
/// </summary>
[TestClass]
[TestCategory("Container")]
public sealed class OtherToolsKeyTests
{
    /// <summary>
    /// PuTTY's keys open, with and without a passphrase, in both versions of the format, and log in: version 3
    /// (puttygen's default since 0.75, Argon2id with a passphrase) for Ed25519 and RSA, version 2 (older PuTTY; its
    /// key derivation is SHA-1) for ECDSA and RSA, and a version-3 key whose lines end in CR LF, as a file that went
    /// through a Windows editor. Bugs: the format that many owners of a PC have read as no key (plan 5.5 gave it as an
    /// estimate, not measured); Argon2 given other bytes of the passphrase than puttygen used.
    /// </summary>
    [TestMethod]
    public async Task PuTTY_keys_of_both_versions_open_with_and_without_a_passphrase()
    {
        var passphrase = OwnerKeys.NewPassphrase();
        var made = new List<(string Name, OwnerKeys.Made Key, string? Passphrase)>
        {
            ("ed25519, version 3, no passphrase", OwnerKeys.Puttygen("ed25519", null, 3, null), null),
            ("ed25519, version 3, a passphrase", OwnerKeys.Puttygen("ed25519", null, 3, passphrase), passphrase),
            ("rsa, version 3, a passphrase", OwnerKeys.Puttygen("rsa", 3072, 3, passphrase), passphrase),
            ("ecdsa, version 2, no passphrase", OwnerKeys.Puttygen("ecdsa", 256, 2, null), null),
            ("rsa, version 2, a passphrase", OwnerKeys.Puttygen("rsa", 2048, 2, passphrase), passphrase),
        };
        var crlf = made[1].Key with { File = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(made[1].Key.File).Replace("\n", "\r\n")) };
        made.Add(("ed25519, version 3, a passphrase, CR LF", crlf, passphrase));
        await using var app = new App();
        using var sshd = new ScratchSshd(made.Select(m => m.Key.PublicLine));
        foreach (var (name, key, given) in made)
        {
            var version = name.Contains("version 3", StringComparison.Ordinal) ? "3" : "2";
            Assert.IsTrue(Encoding.ASCII.GetString(key.File).StartsWith("PuTTY-User-Key-File-" + version + ": ", StringComparison.Ordinal), name);
            await OwnerKeyTests.Opens(app, sshd.Target, name, key, given);
        }
    }

    /// <summary>
    /// A DSA key, which SSH.NET does not take (nor OpenSSH 10), is no key, also with a passphrase: the step shows no
    /// passphrase field for it, and its right passphrase does not read as a wrong one. Keys of OpenSSH 9.6's ssh-keygen
    /// and of puttygen, each with and without a passphrase. Bug: an encrypted key of a type that the app cannot use asks
    /// for its passphrase and then says that it is wrong, for ever (SSH.NET finds the type only after it decrypts).
    /// </summary>
    [TestMethod]
    public void A_DSA_key_is_no_key_with_or_without_its_passphrase()
    {
        var passphrase = OwnerKeys.NewPassphrase();
        var made = new List<(string Name, OwnerKeys.Made Key, string? Passphrase)>
        {
            ("ssh-keygen, no passphrase", OwnerKeys.KeygenInImage("dsa", null, null), null),
            ("ssh-keygen, a passphrase", OwnerKeys.KeygenInImage("dsa", null, passphrase), passphrase),
            ("puttygen, no passphrase", OwnerKeys.Puttygen("dsa", 1024, 3, null), null),
            ("puttygen, a passphrase", OwnerKeys.Puttygen("dsa", 1024, 3, passphrase), passphrase),
        };
        foreach (var (name, key, given) in made)
        {
            Assert.IsTrue(key.PublicLine.StartsWith("ssh-dss ", StringComparison.Ordinal), name);
            Assert.AreEqual(OwnerKeyCheck.NotAKey, OwnerKeyFile.Check(key.File, null), name);
            if (given is not null) Assert.AreEqual(OwnerKeyCheck.NotAKey, OwnerKeyFile.Check(key.File, given.ToCharArray()), name);
        }
    }

    /// <summary>
    /// ECDSA keys in PEM that OpenSSL writes open, with and without a passphrase, and log in: SEC 1
    /// (<c>EC PRIVATE KEY</c>; traditional AES-128-CBC with a passphrase) and PKCS#8 (PBES2 with a passphrase), the
    /// curve by its name. Bugs: SEC 1 or PKCS#8 for ECDSA not read; an encrypted PKCS#8 key read as no key.
    /// </summary>
    [TestMethod]
    public async Task ECDSA_keys_in_PEM_of_OpenSSL_open_with_and_without_a_passphrase()
    {
        var passphrase = OwnerKeys.NewPassphrase();
        var made = new List<(string Name, OwnerKeys.Made Key, string? Passphrase, string Head)>
        {
            ("SEC 1, no passphrase", OwnerKeys.KeygenInImage("ecdsa", "PEM", null), null, "-----BEGIN EC PRIVATE KEY-----"),
            ("SEC 1, a passphrase", OwnerKeys.KeygenInImage("ecdsa", "PEM", passphrase), passphrase,
             "-----BEGIN EC PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED"),
            ("PKCS#8, no passphrase", OwnerKeys.KeygenInImage("ecdsa", "PKCS8", null), null, "-----BEGIN PRIVATE KEY-----"),
            ("PKCS#8, a passphrase", OwnerKeys.KeygenInImage("ecdsa", "PKCS8", passphrase), passphrase, "-----BEGIN ENCRYPTED PRIVATE KEY-----"),
        };
        await using var app = new App();
        using var sshd = new ScratchSshd(made.Select(m => m.Key.PublicLine));
        foreach (var (name, key, given, head) in made)
        {
            Assert.IsTrue(Encoding.ASCII.GetString(key.File).StartsWith(head, StringComparison.Ordinal), name + " is not the format named.");
            await OwnerKeyTests.Opens(app, sshd.Target, name, key, given);
        }
    }
}
