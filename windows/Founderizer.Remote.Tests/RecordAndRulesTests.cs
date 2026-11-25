using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Remote.Tests;

/// <summary>The host key record and the call's rules, with no server.</summary>
[TestClass]
public sealed class RecordAndRulesTests
{
    /// <summary>A server at this host and port; <paramref name="owners"/>: the owner gave this port for this host.</summary>
    private static RemoteTarget At(string host, int port, bool owners = false) => new(host, port, "root", owners ? host : null);

    private static byte[] Blob(string type, byte fill)
    {
        var name = Encoding.ASCII.GetBytes(type);
        var blob = new byte[4 + name.Length + 4 + 32];
        blob[3] = (byte)name.Length;
        name.CopyTo(blob, 4);
        blob[4 + name.Length + 3] = 32;
        blob.AsSpan(8 + name.Length).Fill(fill);
        return blob;
    }

    /// <summary>
    /// A record that cannot be read takes no key, under TakeNew too, and is not written over; start again removes it.
    /// Bugs: a damaged file, or a newer build's file read by an older build, read as empty, so that every server's key
    /// is taken again with no check, and the old keys are lost.
    /// </summary>
    [TestMethod]
    public void A_record_that_cannot_be_read_takes_no_key_and_stays_until_start_again()
    {
        var folder = Local.Folder("founderizer-remote-record");
        try
        {
            var keys = new HostKeys(folder);
            File.WriteAllText(keys.Path, "{\"hosts\": {\"[203.0.113.9]:22\": 7}}");
            var before = File.ReadAllText(keys.Path);
            Assert.AreEqual(HostKeyVerdict.Changed, keys.Check(At("203.0.113.9", 22), Blob("ssh-ed25519", 1), HostKeyRule.TakeNew));
            Assert.AreEqual(HostKeyVerdict.Changed, keys.Check(At("198.51.100.4", 22), Blob("ssh-ed25519", 2), HostKeyRule.TakeNew));
            Assert.AreEqual(before, File.ReadAllText(keys.Path));

            keys.ForgetAll();
            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check(At("198.51.100.4", 22), Blob("ssh-ed25519", 2), HostKeyRule.TakeNew));
        }
        finally { Directory.Delete(folder, recursive: true); }
    }

    /// <summary>
    /// **Only port 22, or a port that the owner gave for this very host, keeps a new key; at any other port the server
    /// must show the key of the host's port 22** (the Mac's <c>hostKeyOptions</c> and <c>HostKeyAlias</c>, the hole of
    /// 22 November 2026). Bugs: a hub that is broken into names port 2222 of a server, where an agent's own small SSH
    /// server answers, and a TakeNew there keeps that program's key, so every later root call (the vault's steps, the
    /// owner's access line) takes its answer for root's; a line that an earlier build kept at "[host]:2222" opens the
    /// server; a port that the owner gave for the typed address counts at an address that the hub gives.
    /// </summary>
    [TestMethod]
    public void Only_port_22_or_the_owners_port_keeps_a_key_and_another_port_must_show_the_port_22_key()
    {
        var folder = Local.Folder("founderizer-remote-record");
        try
        {
            var keys = new HostKeys(folder);
            var hubs = At("203.0.113.9", 2222);
            foreach (var rule in new[] { HostKeyRule.TakeNew, HostKeyRule.Known })
                Assert.AreEqual(HostKeyVerdict.Unknown, keys.Check(hubs, Blob("ssh-ed25519", 1), rule), rule.ToString());
            Assert.IsNull(keys.Find("203.0.113.9", 2222), "no key kept at a port of the hub's record");
            Assert.IsNull(keys.Find("203.0.113.9", 22));

            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check(At("203.0.113.9", 22), Blob("ssh-ed25519", 1), HostKeyRule.TakeNew));
            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check(hubs, Blob("ssh-ed25519", 1), HostKeyRule.Known), "the port 22 key");
            Assert.AreEqual(HostKeyVerdict.Changed, keys.Check(hubs, Blob("ssh-ed25519", 2), HostKeyRule.TakeNew));
            Assert.AreEqual(keys.Find("203.0.113.9", 22), keys.Find(hubs));

            var owners = At("203.0.113.9", 2222, owners: true);
            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check(owners, Blob("ssh-ed25519", 2), HostKeyRule.TakeNew), "the owner's port");
            Assert.AreEqual(keys.Find("203.0.113.9", 2222), keys.Find(owners));
            Assert.AreEqual(HostKeyVerdict.Changed, keys.Check(hubs, Blob("ssh-ed25519", 2), HostKeyRule.Known),
                            "a line of [host]:2222 is not read at a port that the owner did not give");

            var moved = new RemoteTarget("100.80.1.7", 2222, "root", PortGivenFor: "203.0.113.9");
            Assert.AreEqual(HostKeyVerdict.Unknown, keys.Check(moved, Blob("ssh-ed25519", 3), HostKeyRule.TakeNew));
            Assert.IsNull(keys.Find("100.80.1.7", 2222));
        }
        finally { Directory.Delete(folder, recursive: true); }
    }

    /// <summary>
    /// The removal of a server takes its key away and keeps the others, so the same address with a new server can be
    /// added again. Bug: a reinstalled server stays refused as changed, with no way back.
    /// </summary>
    [TestMethod]
    public void Forget_takes_one_server_away_and_keeps_the_others()
    {
        var folder = Local.Folder("founderizer-remote-record");
        try
        {
            var keys = new HostKeys(folder);
            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check(At("203.0.113.9", 22), Blob("ssh-ed25519", 1), HostKeyRule.TakeNew));
            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check(At("Server.Example.COM", 2222, owners: true), Blob("ssh-ed25519", 2), HostKeyRule.TakeNew));
            Assert.AreEqual(HostKeyVerdict.Changed, keys.Check(At("203.0.113.9", 22), Blob("ssh-ed25519", 3), HostKeyRule.TakeNew));

            keys.Forget("203.0.113.9", 22);
            Assert.IsNull(keys.Find("203.0.113.9", 22));
            Assert.IsNotNull(keys.Find("server.example.com", 2222));
            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check(At("203.0.113.9", 22), Blob("ssh-ed25519", 3), HostKeyRule.TakeNew));
        }
        finally { Directory.Delete(folder, recursive: true); }
    }

    /// <summary>
    /// A call's text names its server and not its program, input or login. Bug: a call written to a log as a record
    /// prints its program, and a join line holds a one-time code.
    /// </summary>
    [TestMethod]
    public void A_call_prints_its_server_and_not_its_program()
    {
        var call = new RemoteCall(new RemoteTarget("203.0.113.9", 22, "root"), "join --code ONE-TIME-CODE-123",
                                  Encoding.UTF8.GetBytes("INPUT-SECRET"), new RemoteLogin.AppKey(), HostKeyRule.Known,
                                  RemoteCall.ConnectTimeout);
        var text = call.ToString();
        StringAssert.Contains(text, "203.0.113.9");
        Assert.IsFalse(text.Contains("ONE-TIME-CODE", StringComparison.Ordinal), text);
        Assert.IsFalse(text.Contains("join", StringComparison.Ordinal), text);
    }

    /// <summary>
    /// A program with a carriage return is refused before anything connects or reads the key. Bug: a C# string literal
    /// that a Windows checkout gave CRLF line ends reaches /bin/sh, which reads "\r" as part of each command.
    /// </summary>
    [TestMethod]
    public async Task A_program_with_a_carriage_return_is_refused_before_anything_connects()
    {
        await using var app = new App();
        var call = new RemoteCall(new RemoteTarget("127.0.0.1", 22, "root"), "set -e\r\necho one\r\n", null,
                                  new RemoteLogin.AppKey(), HostKeyRule.TakeNew, RemoteCall.ConnectTimeout);
        await Assert.ThrowsExactlyAsync<ArgumentException>(() => app.Remote.RunAsync(call, null, CancellationToken.None));
        Assert.AreEqual(0, app.KeyReads);
    }

    /// <summary>
    /// A call that no server may get (a rule that it breaks, or an SshRemote that was disposed) still clears the
    /// password and the owner's key that it was given, because the caller leaves that to the call. Bug: the owner's
    /// password or key stays in the PC's memory after a call that ended before it started.
    /// </summary>
    [TestMethod]
    public async Task A_call_that_ends_before_it_starts_clears_its_secrets()
    {
        var app = new App();
        var target = new RemoteTarget("127.0.0.1", 22, "root");
        var password = "Tést-password".ToCharArray();
        var file = Encoding.ASCII.GetBytes("-----BEGIN OPENSSH PRIVATE KEY-----\n");
        var passphrase = "Pâss-words".ToCharArray();
        foreach (var login in new RemoteLogin[] { new RemoteLogin.PasswordOnce(password), new RemoteLogin.KeyOnce(file, passphrase) })
        {
            var broken = new RemoteCall(target, "echo one\r\n", null, login, HostKeyRule.TakeNew, RemoteCall.ConnectTimeout);
            await Assert.ThrowsExactlyAsync<ArgumentException>(() => app.Remote.RunAsync(broken, null, CancellationToken.None));
        }
        Assert.IsTrue(password.All(c => c == '\0') && file.All(b => b == 0) && passphrase.All(c => c == '\0'),
                      "A call that broke a rule kept its secrets.");

        await app.DisposeAsync();
        password = "Tést-password".ToCharArray();
        file = Encoding.ASCII.GetBytes("-----BEGIN OPENSSH PRIVATE KEY-----\n");
        foreach (var login in new RemoteLogin[] { new RemoteLogin.PasswordOnce(password), new RemoteLogin.KeyOnce(file, null) })
        {
            var late = new RemoteCall(target, "echo one", null, login, HostKeyRule.TakeNew, RemoteCall.ConnectTimeout);
            await Assert.ThrowsExactlyAsync<ObjectDisposedException>(() => app.Remote.RunAsync(late, null, CancellationToken.None));
        }
        Assert.IsTrue(password.All(c => c == '\0') && file.All(b => b == 0), "A call after the end kept its secrets.");
    }
}
