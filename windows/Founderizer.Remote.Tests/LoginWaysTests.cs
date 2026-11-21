using System;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Remote.Tests;

/// <summary>
/// **The ways in that a server still takes** (<see cref="RemoteResult.LoginWays"/>; plan 5.5 and piece L4c, the owner's
/// "Key row here too" of 21 November 2026): from the server's refusal of the app's key, against a scratch sshd that takes
/// keys only and the same sshd with the password ways on. The first run reads the list to choose between the password's
/// page and the stop of a server that takes keys only, so the list must be the server's own, and no call may send a
/// password to learn it: each server's log says that none came.
/// </summary>
[TestClass]
public sealed class LoginWaysTests
{
    /// <summary>
    /// The password ways on. A Match block, because sshd keeps the first value of a keyword, and the scratch sshd's own
    /// lines say no to both before its <c>extra</c>.
    /// </summary>
    private const string PasswordWaysOn = "Match all\n  PasswordAuthentication yes\n  KbdInteractiveAuthentication yes";

    /// <summary>A try of a password way, as the scratch sshd logs it (LogLevel VERBOSE: "Failed password for …").</summary>
    private static readonly Regex PasswordTry =
        new(@"\b(Failed|Accepted|Postponed|Partial) (password|keyboard-interactive)", RegexOptions.CultureInvariant);

    /// <summary>
    /// A server that takes keys only refuses the app's key with "publickey" alone, as LoginRefused. Bugs: no list (the
    /// first run then asks for a password that the server never takes, the owner's first wall of 21 November 2026); a
    /// list that names a password way it does not take.
    /// </summary>
    [TestMethod]
    public async Task A_server_that_takes_keys_only_names_publickey_alone()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([AppSshKey.Make().PublicLine]);
        var (result, _) = await app.Run(sshd.Target, "true");
        Assert.AreEqual(RemoteFailure.LoginRefused, result.Failure);
        CollectionAssert.AreEqual(new[] { "publickey" }, result.LoginWays?.ToArray(), sshd.Log());
        Assert.AreEqual(0, PasswordTries(sshd.Log()), sshd.Log());
    }

    /// <summary>
    /// The same server with the password ways on names them with its refusal of the app's key, in its own order, and
    /// gets no password: the log shows a password try only when a call sends one (the last call, which proves that the
    /// log would show it). Bugs: a probe that sends a password to learn the ways (a password that the owner never gave,
    /// and a failure that brings a server's lockout nearer); the list of SSH.NET's own methods in place of the server's.
    /// </summary>
    [TestMethod]
    public async Task A_server_with_the_password_ways_on_names_them_and_gets_no_password()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([AppSshKey.Make().PublicLine], extra: PasswordWaysOn);
        var (result, _) = await app.Run(sshd.Target, "true");
        Assert.AreEqual(RemoteFailure.LoginRefused, result.Failure);
        CollectionAssert.AreEqual(new[] { "publickey", "password", "keyboard-interactive" }, result.LoginWays?.ToArray(), sshd.Log());
        Assert.AreEqual(0, PasswordTries(sshd.Log()), sshd.Log());

        var (sent, _) = await app.Run(sshd.Target, "true", login: new RemoteLogin.PasswordOnce("not-the-password".ToCharArray()));
        Assert.AreEqual(RemoteFailure.LoginRefused, sent.Failure);
        var log = "";
        for (var wait = 0; wait < 20 && PasswordTries(log = sshd.Log()) == 0; wait++) await Task.Delay(250);
        Assert.AreEqual(1, PasswordTries(log), log);
    }

    /// <summary>
    /// A login that got in, and a server that was not reached, name no ways: the list is null, never empty. Bug: an empty
    /// list for a result with no refusal, which the first run reads as a server that names no password way, and so
    /// sends the owner of a server that it never reached to the stop of a server that takes keys only.
    /// </summary>
    [TestMethod]
    public async Task A_login_that_got_in_and_a_server_that_was_not_reached_name_no_ways()
    {
        await using var app = new App();
        using var sshd = new ScratchSshd([app.Key.PublicLine], extra: PasswordWaysOn);
        var (inside, _) = await app.Run(sshd.Target, "true");
        Assert.IsNull(inside.Failure);
        Assert.IsNull(inside.LoginWays);

        var (refused, _) = await app.Run(new RemoteTarget("127.0.0.1", Local.FreePort(), "nobody"), "true");
        Assert.AreEqual(RemoteFailure.Refused, refused.Failure);
        Assert.IsNull(refused.LoginWays);

        using var closing = new Closing();
        var (closed, _) = await app.Run(new RemoteTarget("127.0.0.1", closing.Port, "nobody"), "true");
        Assert.AreEqual(RemoteFailure.Closed, closed.Failure);
        Assert.IsNull(closed.LoginWays);
        Assert.AreEqual(0, PasswordTries(sshd.Log()), sshd.Log());
    }

    private static int PasswordTries(string log) => PasswordTry.Matches(log).Count;
}
