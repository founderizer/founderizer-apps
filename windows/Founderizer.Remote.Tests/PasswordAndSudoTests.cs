using System;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Remote.Tests;

/// <summary>The password once, and sudo -S, against an sshd in a container that each test removes.</summary>
[TestClass]
[TestCategory("Container")]
public sealed class PasswordAndSudoTests
{
    /// <summary>A password of the test alone, with a letter outside ASCII, so its bytes must go as UTF-8.</summary>
    private static string NewPassword() => "Tést-" + Convert.ToBase64String(RandomNumberGenerator.GetBytes(12)).Replace('/', '_').Replace('+', '-');

    /// <summary>
    /// The password logs in on a server that asks for it by keyboard-interactive (PAM's prompt, as the Mac's ssh asks
    /// first) and on one that takes the password method alone, and the caller's array holds no password after the
    /// call. Bugs: one of the two methods not answered (a VPS of that kind never installs); the password as UTF-16; the
    /// password left in the PC's memory after the call.
    /// </summary>
    [TestMethod]
    public async Task A_password_logs_in_by_either_method_and_is_cleared_after_the_call()
    {
        var password = NewPassword();
        await using var app = new App();
        using var server = new ContainerSshd(password, app.Key.PublicLine);
        foreach (var target in new[] { server.Target, server.PasswordOnly })
        {
            var chars = password.ToCharArray();
            var (result, _) = await app.Run(target, "id -un", login: new RemoteLogin.PasswordOnce(chars));
            Assert.IsNull(result.Failure, $"port {target.Port}");
            Assert.AreEqual("founder\n", result.Output);
            Assert.IsTrue(chars.All(c => c == '\0'), "The caller's password array was not cleared.");
        }
    }

    /// <summary>
    /// A wrong password is LoginRefused after one try, on a server that offers both methods. Bug: the password sent by
    /// keyboard-interactive and again by the password method, which counts two failures where the Mac's ssh makes one
    /// (NumberOfPasswordPrompts=1) and brings a server's lockout nearer.
    /// </summary>
    [TestMethod]
    public async Task A_wrong_password_is_LoginRefused_after_one_try()
    {
        await using var app = new App();
        using var server = new ContainerSshd(NewPassword(), app.Key.PublicLine);
        var (result, _) = await app.Run(server.Target, "id -un", login: new RemoteLogin.PasswordOnce("not-the-password".ToCharArray()));
        Assert.AreEqual(RemoteFailure.LoginRefused, result.Failure);
        string log = "";
        for (var wait = 0; wait < 20; wait++)
        {
            log = server.Log();
            if (log.Contains("Failed ", StringComparison.Ordinal)) break;
            await Task.Delay(250);
        }
        var failures = log.Split('\n').Count(l => l.Contains("Failed ", StringComparison.Ordinal) && l.Contains("founder", StringComparison.Ordinal));
        Assert.AreEqual(1, failures, log);
    }

    /// <summary>
    /// A program with no input runs in the user's own login shell, here tcsh, and reads an end of file at once, as with
    /// the Mac's ssh. Bugs: a line that only sh-like shells read (tcsh answers "exec: Too few arguments" to a bare
    /// redirection), so the program never starts or waits for ever on its input; the program run by sh instead.
    /// </summary>
    [TestMethod]
    public async Task A_program_with_no_input_runs_in_a_login_shell_that_is_not_sh()
    {
        await using var app = new App();
        using var server = new ContainerSshd(NewPassword(), app.Key.PublicLine);
        var (result, _) = await app.Run(server.Tcsh, "cat; echo \"it's $shell\"", seconds: 30);
        Assert.IsNull(result.Failure, result.Errors);
        Assert.AreEqual(0, result.ExitStatus, result.Errors);
        StringAssert.Matches(result.Output, new System.Text.RegularExpressions.Regex(@"it's \S*/tcsh\n\z"));
    }

    /// <summary>
    /// The installer's root step for a user whose sudo asks for a password: the app's key logs in, and the password goes
    /// as the first line of standard input to sudo -S, in the Mac's form (sudo -S -k -p '' -i), with the step's own input
    /// after it. Bugs: the input cut or sent before the channel opened, sudo reading more than its line.
    /// </summary>
    [TestMethod]
    public async Task Sudo_takes_the_password_from_the_first_line_of_the_input()
    {
        var password = NewPassword();
        await using var app = new App();
        using var server = new ContainerSshd(password, app.Key.PublicLine);
        var step = new byte[1000];
        step.AsSpan().Fill((byte)'x');
        var input = Encoding.UTF8.GetBytes(password + "\n").Concat(step).ToArray();
        var (result, _) = await app.Run(server.Target, "sudo -S -k -p '' -i -- /bin/sh -c 'id -u; wc -c'", input);
        Assert.IsNull(result.Failure);
        Assert.AreEqual(0, result.ExitStatus, result.Errors);
        CollectionAssert.AreEqual(new[] { "0", "1000" }, result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim()).ToArray());
    }
}
