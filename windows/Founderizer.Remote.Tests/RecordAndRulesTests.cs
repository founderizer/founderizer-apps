using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Remote.Tests;

/// <summary>The host key record and the call's rules, with no server.</summary>
[TestClass]
public sealed class RecordAndRulesTests
{
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
            Assert.AreEqual(HostKeyVerdict.Changed, keys.Check("203.0.113.9", 22, Blob("ssh-ed25519", 1), HostKeyRule.TakeNew));
            Assert.AreEqual(HostKeyVerdict.Changed, keys.Check("198.51.100.4", 22, Blob("ssh-ed25519", 2), HostKeyRule.TakeNew));
            Assert.AreEqual(before, File.ReadAllText(keys.Path));

            keys.ForgetAll();
            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check("198.51.100.4", 22, Blob("ssh-ed25519", 2), HostKeyRule.TakeNew));
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
            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check("203.0.113.9", 22, Blob("ssh-ed25519", 1), HostKeyRule.TakeNew));
            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check("Server.Example.COM", 2222, Blob("ssh-ed25519", 2), HostKeyRule.TakeNew));
            Assert.AreEqual(HostKeyVerdict.Changed, keys.Check("203.0.113.9", 22, Blob("ssh-ed25519", 3), HostKeyRule.TakeNew));

            keys.Forget("203.0.113.9", 22);
            Assert.IsNull(keys.Find("203.0.113.9", 22));
            Assert.IsNotNull(keys.Find("server.example.com", 2222));
            Assert.AreEqual(HostKeyVerdict.Trusted, keys.Check("203.0.113.9", 22, Blob("ssh-ed25519", 3), HostKeyRule.TakeNew));
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
}
