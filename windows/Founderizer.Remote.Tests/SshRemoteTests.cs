using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Remote.Tests;

/// <summary>SshRemote against a scratch sshd of this machine: each test starts its own and stops it.</summary>
[TestClass]
public sealed class SshRemoteTests
{
    /// <summary>
    /// What the installer reads from each step: standard output and standard error apart, the exit status, and each
    /// line as it comes. With no input the program reads an end of file at once (the Mac's /dev/null), so a step that
    /// reads its standard input does not hang. Bugs: the two streams mixed or lost, a status of 0 for a failed step, a
    /// call that waits for ever on a program that reads its input.
    /// </summary>
    [TestMethod]
    public async Task A_program_gives_its_output_its_errors_its_status_and_its_lines()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        var (result, lines) = await app.Run(sshd.Target, "cat; printf 'one\\ntwo\\n'; printf 'warn\\n' >&2; exit 3");
        Assert.IsNull(result.Failure);
        Assert.AreEqual(3, result.ExitStatus);
        Assert.AreEqual("one\ntwo\n", result.Output);
        Assert.AreEqual("warn\n", result.Errors);
        CollectionAssert.AreEquivalent(new[] { "one", "two", "warn" }, lines);
    }

    /// <summary>
    /// The installer gives a step its Tailscale key, a script or a bundle on standard input. Bugs: input cut at the
    /// channel's window (2 MiB), bytes read as text (a NUL or a byte over 127 changed), no end of file after it.
    /// </summary>
    [TestMethod]
    public async Task The_input_arrives_whole()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        var input = RandomNumberGenerator.GetBytes(3 * 1024 * 1024 + 17);
        input[0] = 0; input[1] = 0xff; input[^1] = (byte)'\n';
        var (result, _) = await app.Run(sshd.Target,
            "if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi", input);
        Assert.IsNull(result.Failure);
        Assert.AreEqual(0, result.ExitStatus);
        Assert.AreEqual(Convert.ToHexStringLower(SHA256.HashData(input)), result.Output.Split(' ')[0]);
    }

    /// <summary>
    /// A program that prints without end (a log, a loop) keeps the first 1 MiB, as the Mac's LocalShell, and still ends.
    /// Bugs: the PC's memory fills; or reading stops at the bound, the server's window fills, and the program never ends.
    /// </summary>
    [TestMethod]
    public async Task Output_is_bounded_and_the_program_still_ends()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        var (result, _) = await app.Run(sshd.Target, "head -c 5000000 /dev/zero | tr '\\0' a; echo done >&2");
        Assert.IsNull(result.Failure);
        Assert.AreEqual(0, result.ExitStatus);
        Assert.AreEqual(1 << 20, result.Output.Length);
        Assert.AreEqual("done\n", result.Errors);
    }

    /// <summary>
    /// TakeNew keeps the server's key as OpenSSH's own line of it, and Known then takes that server. No file of the app's
    /// folder holds the app key's private half in any form. Bugs: a key kept in a form that never matches again (every
    /// later call refused), a key not kept (every call takes whatever it is shown), the private key written beside it.
    /// </summary>
    [TestMethod]
    public async Task TakeNew_keeps_the_key_Known_then_takes_it_and_no_file_holds_the_private_key()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        var (first, _) = await app.Run(sshd.Target, "echo first", rule: HostKeyRule.TakeNew);
        Assert.IsNull(first.Failure);
        Assert.AreEqual(sshd.HostKeyLine, app.HostKeys.Find("127.0.0.1", sshd.Port));
        var (second, _) = await app.Run(sshd.Target, "echo second", rule: HostKeyRule.Known);
        Assert.IsNull(second.Failure);
        Assert.AreEqual("second\n", second.Output);

        var secret = app.Key.PrivateKey;
        var forms = new[] { Convert.ToBase64String(secret), Convert.ToHexStringLower(secret), Convert.ToHexString(secret), "PRIVATE KEY" };
        foreach (var file in Directory.EnumerateFiles(app.Folder, "*", SearchOption.AllDirectories))
        {
            var bytes = File.ReadAllBytes(file);
            var text = Encoding.UTF8.GetString(bytes);
            Assert.IsFalse(bytes.AsSpan().IndexOf(secret) >= 0, file);
            foreach (var form in forms) Assert.IsFalse(text.Contains(form, StringComparison.Ordinal), file);
        }
    }

    /// <summary>
    /// Under Known, a server with no key on record is refused before the login: no key, no program, no input reaches
    /// it, and no key is kept. Bugs: Known read as TakeNew, or the check after the login.
    /// </summary>
    [TestMethod]
    public async Task An_unknown_host_under_Known_is_refused_and_nothing_is_sent()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        var marker = Path.Combine(sshd.Folder, "ran");
        var (result, _) = await app.Run(sshd.Target, $"touch '{marker}'", Encoding.UTF8.GetBytes("input"), HostKeyRule.Known);
        Assert.AreEqual(RemoteFailure.HostKeyUnknown, result.Failure);
        Assert.IsNull(result.ExitStatus);
        Assert.IsFalse(File.Exists(marker));
        Assert.IsNull(app.HostKeys.Find("127.0.0.1", sshd.Port));
        NoLoginIn(sshd.Log());
    }

    /// <summary>
    /// A server that shows another key than the one on record is refused under both rules, before the login, and the
    /// record keeps the first key. Bugs: TakeNew takes the new key over the old one; the login, and so a password,
    /// goes to a server that is not the one the owner set up.
    /// </summary>
    [TestMethod]
    public async Task A_changed_host_key_is_refused_under_both_rules_and_nothing_is_sent()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        var (first, _) = await app.Run(sshd.Target, "true");
        Assert.IsNull(first.Failure);
        var kept = app.HostKeys.Find("127.0.0.1", sshd.Port);

        sshd.Restart("ed25519");
        var from = sshd.LogLength;
        var marker = Path.Combine(sshd.Folder, "ran");
        foreach (var rule in new[] { HostKeyRule.TakeNew, HostKeyRule.Known })
        {
            var (result, _) = await app.Run(sshd.Target, $"touch '{marker}'", Encoding.UTF8.GetBytes("input"), rule);
            Assert.AreEqual(RemoteFailure.HostKeyChanged, result.Failure, rule.ToString());
        }
        Assert.IsFalse(File.Exists(marker));
        Assert.AreEqual(kept, app.HostKeys.Find("127.0.0.1", sshd.Port));
        NoLoginIn(sshd.Log(from));
    }

    /// <summary>
    /// A server whose key on record is Ed25519 and that now shows only an ECDSA key has a changed key, also under
    /// TakeNew. Bug: a key of a type with no record taken as new (OpenSSH's accept-new can do so), which lets anyone who
    /// stands in the way with a key of another type in.
    /// </summary>
    [TestMethod]
    public async Task A_key_of_another_type_is_a_changed_key()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine], hostKeyType: "ed25519");
        Assert.IsNull((await app.Run(sshd.Target, "true")).Result.Failure);
        sshd.Restart("ecdsa");
        var (result, _) = await app.Run(sshd.Target, "true", rule: HostKeyRule.TakeNew);
        Assert.AreEqual(RemoteFailure.HostKeyChanged, result.Failure);
        StringAssert.StartsWith(app.HostKeys.Find("127.0.0.1", sshd.Port), "ssh-ed25519 ");
    }

    /// <summary>
    /// A server that does not have the app's key is LoginRefused, and no other key is offered. Bugs: a refusal read as
    /// no answer (the page then says the server is down), the owner's own keys tried.
    /// </summary>
    [TestMethod]
    public async Task A_wrong_key_is_LoginRefused()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([AppSshKey.Make().PublicLine]);
        var (result, _) = await app.Run(sshd.Target, "true");
        Assert.AreEqual(RemoteFailure.LoginRefused, result.Failure);
        Assert.IsNull(result.ExitStatus);
    }

    /// <summary>
    /// A connection that ends while the program runs ends the call as Dropped, with what came before it. Bugs: the call
    /// waits for ever, or reads as a program that failed with a status.
    /// </summary>
    [TestMethod]
    public async Task A_connection_that_ends_is_Dropped()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        using var relay = new Relay(sshd.Port);
        var started = new TaskCompletionSource();
        var target = new RemoteTarget("127.0.0.1", relay.Port, sshd.User, PortGivenFor: "127.0.0.1");
        var call = app.Run(target, "echo started; sleep 60", also: text => { if (text == "started") started.TrySetResult(); });
        await started.Task.WaitAsync(TimeSpan.FromSeconds(30));
        relay.Cut();
        var (result, _) = await call.WaitAsync(TimeSpan.FromSeconds(15));
        Assert.AreEqual(RemoteFailure.Dropped, result.Failure);
        Assert.IsNull(result.ExitStatus);
        Assert.AreEqual("started\n", result.Output);
    }

    /// <summary>A cancel ends the call at once, as Canceled. Bug: the call waits for the program's end.</summary>
    [TestMethod]
    public async Task A_cancel_ends_the_call()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        using var cancel = new CancellationTokenSource();
        var call = app.Run(sshd.Target, "echo started; sleep 60; echo late", cancel: cancel.Token,
                           also: text => { if (text == "started") cancel.Cancel(); });
        var (result, lines) = await call.WaitAsync(TimeSpan.FromSeconds(15));
        Assert.AreEqual(RemoteFailure.Canceled, result.Failure);
        Assert.IsNull(result.ExitStatus);
        CollectionAssert.AreEqual(new[] { "started" }, lines);
    }

    /// <summary>
    /// Each way of not reaching a server has its own failure, because the Mac says a sentence for each
    /// (ServerCheck.unreached(_:said:)): a name not found, a port that refused, a server that closed the connection before
    /// any login, and a server that took the connection and said nothing, the last within the call's time to connect.
    /// Bugs: all four read as one "could not reach" (the report of 13 November 2026: it told nobody where to look); a
    /// silent address that holds the install for ever.
    /// </summary>
    [TestMethod]
    public async Task Each_way_of_not_reaching_a_server_has_its_own_failure()
    {
        ScratchSshd.RequireOrSkip();
        await using var app = new App();
        var (unknown, _) = await app.Run(new RemoteTarget("no-such-server.invalid", 22, "nobody"), "true");
        Assert.AreEqual(RemoteFailure.NotFound, unknown.Failure);

        var (refused, _) = await app.Run(new RemoteTarget("127.0.0.1", Local.FreePort(), "nobody"), "true");
        Assert.AreEqual(RemoteFailure.Refused, refused.Failure);

        using var closing = new Closing();
        var (closed, _) = await app.Run(new RemoteTarget("127.0.0.1", closing.Port, "nobody"), "true");
        Assert.AreEqual(RemoteFailure.Closed, closed.Failure);

        using var silent = new Silent();
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var (quiet, _) = await app.Run(new RemoteTarget("127.0.0.1", silent.Port, "nobody"), "true",
                                       connect: TimeSpan.FromSeconds(2), seconds: 15);
        Assert.AreEqual(RemoteFailure.NoAnswer, quiet.Failure);
        Assert.IsTrue(watch.Elapsed < TimeSpan.FromSeconds(8), watch.Elapsed.ToString());
    }

    /// <summary>
    /// A call ends at its limit as TimedOut, with what came before it, as the Mac's LocalShell ends its ssh. Bug: a
    /// server whose network answers while its programs stand still holds the install for ever, because SSH.NET's
    /// keep-alive asks for no answer.
    /// </summary>
    [TestMethod]
    public async Task A_call_past_its_limit_is_TimedOut()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var (result, _) = await app.Run(sshd.Target, "echo started; sleep 60", limit: TimeSpan.FromSeconds(3), seconds: 15);
        Assert.AreEqual(RemoteFailure.TimedOut, result.Failure);
        Assert.IsNull(result.ExitStatus);
        Assert.AreEqual("started\n", result.Output);
        Assert.IsTrue(watch.Elapsed < TimeSpan.FromSeconds(8), watch.Elapsed.ToString());
    }

    /// <summary>
    /// A password login to a server that takes keys only is LoginNotOffered, and the password was not sent: the Mac
    /// says "takes SSH keys only, so a password cannot open it" (PasswordOnce.refusal). Bug: read as a wrong password,
    /// so the owner types it again and again.
    /// </summary>
    [TestMethod]
    public async Task A_password_to_a_server_that_takes_keys_only_is_LoginNotOffered()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine]);
        var password = "not-asked-for".ToCharArray();
        var (result, _) = await app.Run(sshd.Target, "true", login: new RemoteLogin.PasswordOnce(password));
        Assert.AreEqual(RemoteFailure.LoginNotOffered, result.Failure);
        Assert.IsTrue(password.All(c => c == '\0'), "The caller's password array was not cleared.");
    }

    /// <summary>The scratch sshd's log has no login of any kind, and no session.</summary>
    private static void NoLoginIn(string log)
    {
        foreach (var word in new[] { "publickey", "Accepted", "Postponed", "Starting session" })
            Assert.IsFalse(log.Contains(word, StringComparison.Ordinal), $"The log has \"{word}\":\n{log}");
    }
}
