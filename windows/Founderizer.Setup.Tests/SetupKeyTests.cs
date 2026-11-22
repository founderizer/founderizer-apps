using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Founderizer.Remote;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The owner's key once on Other VPS** (the owner's "Choose key, as Mac" and "One field, only then" of 21
/// November 2026; plan 5.5 and piece L4), on L1a's <see cref="RemoteLogin.KeyOnce"/> and <see cref="OwnerKeyFile"/>,
/// over a stand-in server that takes keys only. Each key is made by ssh-keygen in the test; none is a file of the
/// repository.</summary>
[TestClass]
public sealed class SetupKeyTests
{
    private const string Server = "203.0.113.10";

    /// <summary>A key of <c>ssh-keygen -t ed25519</c>, with this passphrase or none (given on its input, never as an
    /// argument): its file's bytes and its second line, for a search of the files that must not hold it.</summary>
    private static (byte[] File, string Line) Key(string? passphrase = null)
    {
        if (!File.Exists("/usr/bin/ssh-keygen")) Assert.Inconclusive("no ssh-keygen on this machine");
        var folder = Directory.CreateTempSubdirectory("founderizer-setup-key-").FullName;
        try
        {
            var askpass = Path.Combine(folder, "askpass");
            File.WriteAllText(askpass, "#!/bin/sh\nIFS= read -r line && printf '%s\\n' \"$line\"\n");
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(askpass, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var key = Path.Combine(folder, "key");
            var start = new ProcessStartInfo("/usr/bin/ssh-keygen") { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var a in new[] { "-q", "-t", "ed25519", "-C", "owner@example.com", "-f", key }) start.ArgumentList.Add(a);
            if (passphrase is null) { start.ArgumentList.Add("-N"); start.ArgumentList.Add(""); }
            else { start.Environment["SSH_ASKPASS"] = askpass; start.Environment["SSH_ASKPASS_REQUIRE"] = "force"; start.Environment["DISPLAY"] = ":0"; }
            using var keygen = Process.Start(start)!;
            if (passphrase is not null) keygen.StandardInput.Write(passphrase + "\n" + passphrase + "\n");
            keygen.StandardInput.Close();
            keygen.WaitForExit();
            Assert.AreEqual(0, keygen.ExitCode, keygen.StandardError.ReadToEnd());
            var bytes = File.ReadAllBytes(key);
            return (bytes, File.ReadAllLines(key)[1]);
        }
        finally { Directory.Delete(folder, recursive: true); }
    }

    /// <summary>The first pages, Other VPS, and the check that the app's key does not pass at a server that names its
    /// ways with no password way among them: the stop of a server that takes keys only, at once.</summary>
    private static async Task<SetupRig> AtTheKeysOnlyStop(KeyServer server, string user = "root")
    {
        var rig = await AtTheCheck(server, user);
        var s = rig.Store.State;
        Assert.AreEqual((VpsPhase.Stopped, true), (s.Vps.Phase, s.Vps.KeysOnly), s.Vps.Why);
        Assert.AreEqual($"{Server} takes SSH keys only, so a password cannot open it. Choose its key.", s.Vps.Why);
        var row = SetupScreens.Of(s).Controls.First();
        Assert.AreEqual((SetupScreens.SshKey, SetupScreens.ChooseKeyWords), (row.Words, row.Lines![0]));
        return rig;
    }

    /// <summary>The first pages, Other VPS, and the check of the server with the app's key.</summary>
    private static async Task<SetupRig> AtTheCheck(KeyServer server, string user = "root")
    {
        var rig = new SetupRig(call => server.Answer(call, call.Input));
        rig.ThroughTheFirstPages(ServersStep.One);
        rig.Store.ChooseOtherVps();
        await rig.Store.CheckVpsAsync(user == "root" ? Server : $"{user}@{Server}");
        return rig;
    }

    /// <summary>**A server that names its ways, with no password way among them, goes straight to the key** (piece L4c;
    /// the owner's "Key row here too" of 21 November 2026): the stop of picture 13d after the check alone, with no
    /// password's page and no call that carries a password. The bug: the owner of the usual VPS, made with a key, asked
    /// for a password that the server never takes (the owner's first wall of 21 November 2026).</summary>
    [TestMethod]
    public async Task A_server_that_names_no_password_way_goes_to_the_key_with_no_password_try()
    {
        var pages = new List<VpsPhase>();
        var server = new KeyServer();
        var rig = new SetupRig(call => server.Answer(call, call.Input));
        await using (rig)
        {
            rig.Store.Changed += (_, s) => { lock (pages) pages.Add(s.Vps.Phase); };
            rig.ThroughTheFirstPages(ServersStep.One);
            rig.Store.ChooseOtherVps();
            await rig.Store.CheckVpsAsync(Server);
            var s = rig.Store.State;
            Assert.AreEqual((VpsPhase.Stopped, true), (s.Vps.Phase, s.Vps.KeysOnly), s.Vps.Why);
            Assert.AreEqual($"{Server} takes SSH keys only, so a password cannot open it. Choose its key.", s.Vps.Why);
            lock (pages) Assert.IsFalse(pages.Contains(VpsPhase.Password), "no password's page");
            Assert.IsFalse(SetupScreens.Of(s).Controls.Any(c => c.Kind == SetupControlKind.Secret), "no password's field");
            Assert.IsFalse(rig.Remote.Calls.Any(c => c.Login is RemoteLogin.PasswordOnce), "no call carries a password");
        }
    }

    /// <summary>**Other VPS on a PC that has made no server yet: the check has the app's own key** (found by piece U2 in
    /// the build VM). The app's SSH key is made at its first use; the provider's build makes it, and Other VPS checks with
    /// it before any build. The rig's remote refuses a call with the app's key while the box holds none, as SshRemote
    /// does. The bug: a PC whose first run goes to Other VPS checks with no key in its box, and the title stands at
    /// "Checking" for ever, or stops with the words of a server not reached.</summary>
    [TestMethod]
    public async Task Other_VPS_on_a_PC_with_no_server_yet_checks_with_the_apps_own_key()
    {
        await using var rig = new SetupRig(call => new KeyServer().Answer(call, call.Input));
        Assert.IsNull(rig.Box.Read(AppSshKey.BoxName), "a PC that has made no server holds no key yet");
        rig.ThroughTheFirstPages(ServersStep.One);
        rig.Store.ChooseOtherVps();
        await rig.Store.CheckVpsAsync(Server);
        var s = rig.Store.State;
        Assert.AreEqual((VpsPhase.Stopped, true), (s.Vps.Phase, s.Vps.KeysOnly), s.Vps.Why);
        Assert.AreEqual(ServerCheck.KeysOnly(Server), s.Vps.Why);
        Assert.IsTrue(rig.Remote.Calls.Any(c => c.Login is RemoteLogin.AppKey), "the check called the server with the app's key");
    }

    /// <summary>**Try again of an address that is not one says its sentence again, and calls nothing** (Check 1 of U2).
    /// The address's own sentence shows at once; its stop's one press is Try again, and Enter presses it too. The bug: Try
    /// again sent the call that no server may get, the SSH client refused it with an exception, and the title stood at
    /// "Checking &lt;address&gt;" for ever. The rig's remote refuses such a call as RemoteRules.Check does.</summary>
    [TestMethod]
    public async Task Try_again_of_an_address_that_is_not_one_says_its_sentence_again()
    {
        foreach (var typed in new[] { "my server", "https://203.0.113.10", "203.0.113.10:70000" })
        {
            await using var rig = new SetupRig(call => new KeyServer().Answer(call, call.Input));
            rig.ThroughTheFirstPages(ServersStep.One);
            rig.Store.ChooseOtherVps();
            var says = SetupStore.Target(typed).Problem;
            Assert.IsNotNull(says, typed);
            await rig.Store.CheckVpsAsync(typed);
            Assert.AreEqual((VpsPhase.Stopped, says), (rig.Store.State.Vps.Phase, rig.Store.State.Vps.Why), typed);
            await rig.Store.VpsAgainAsync();
            Assert.AreEqual((VpsPhase.Stopped, says), (rig.Store.State.Vps.Phase, rig.Store.State.Vps.Why), typed + ", Try again");
            Assert.AreEqual(0, rig.Remote.Calls.Count, typed + ": no call");
        }
    }

    /// <summary>**A call of Other VPS that throws ends in a stop, and the owner's key goes** (Check 1 of U2; the Mac's
    /// <c>ServerCheck.run</c> turns each error into the stop of a server not reached). The bug: an exception that is not
    /// a cancel (a box that does not open, a call that the SSH client refuses) leaves the title at "Checking" with no
    /// end, and the owner's key and its passphrase in memory until Back.</summary>
    [TestMethod]
    public async Task A_call_that_throws_ends_in_a_stop_and_the_owners_key_goes()
    {
        var (file, _) = Key();
        var server = new KeyServer(keyCall: (_, _) => throw new IOException("the network went away in the middle"));
        await using var rig = await AtTheKeysOnlyStop(server);
        await rig.Store.ChooseKey(file, "id_ed25519");
        var s = rig.Store.State;
        Assert.AreEqual((VpsPhase.Stopped, ServerCheck.Unreached(Server)), (s.Vps.Phase, s.Vps.Why));
        Assert.IsFalse(rig.Store.HoldsOwnerKey, "no byte of the owner's key and no passphrase stays");
        Assert.IsNull(s.Vps.KeyName);

        // The check itself: a remote that throws at the check is a stop in the same words, not a title with no end.
        await using var other = new SetupRig(call => call.Program == "/bin/sh -s" ? throw new IOException("no answer") : (RemoteResult?)null);
        other.ThroughTheFirstPages(ServersStep.One);
        other.Store.ChooseOtherVps();
        await other.Store.CheckVpsAsync(Server);
        Assert.AreEqual((VpsPhase.Stopped, ServerCheck.Unreached(Server)), (other.Store.State.Vps.Phase, other.Store.State.Vps.Why));
    }

    /// <summary>**A server that names a password way, or names none, shows the password and the key on one page, and a key
    /// chosen there puts this PC's key on the server with no password call** (picture 14b, W15): the password's field and
    /// its line, then the key's row with Choose key and "Your key never leaves this PC". Keyboard-interactive is a
    /// password way: PAM asks for the password by it. The bugs: the owner of a server that takes both ways, who has the
    /// key and not the password, with no way in (the owner's second wall); a server that names nothing read as one that
    /// takes keys only, so a password that it would take is never asked.</summary>
    [TestMethod]
    public async Task A_server_that_names_a_password_way_or_none_takes_the_password_or_the_key_on_one_page()
    {
        string[]?[] cases = [["publickey", "password", "keyboard-interactive"], ["publickey", "keyboard-interactive"], null];
        foreach (var ways in cases)
        {
            var at = ways is null ? "no list" : string.Join(",", ways);
            await using var rig = await AtTheCheck(new KeyServer { Ways = ways });
            var s = rig.Store.State;
            Assert.AreEqual((VpsPhase.Password, ServerCheck.PasswordNeed.Ssh as ServerCheck.PasswordNeed?, false),
                            (s.Vps.Phase, s.Vps.Need, s.Vps.KeysOnly), at);
            var controls = SetupScreens.Of(s).Controls;
            CollectionAssert.AreEqual(new[] { SetupScreens.Password, SetupScreens.UsedOnce, SetupScreens.SshKey, SetupScreens.KeyNeverLeaves },
                                      controls.Select(c => c.Words).ToArray(), at);
            Assert.AreEqual(SetupScreens.ChooseKeyWords, controls[2].Lines![0], at);

            await rig.Store.ChooseKey(Key().File, "id_ed25519");
            s = rig.Store.State;
            Assert.AreEqual(VpsPhase.Ready, s.Vps.Phase, $"{at}: {s.Vps.Why ?? s.Vps.KeyWarning}");
            Assert.IsFalse(rig.Remote.Calls.Any(c => c.Login is RemoteLogin.PasswordOnce), $"{at}: no call carries a password");
            var keyed = rig.Remote.Calls.FindIndex(c => c.Login is RemoteLogin.KeyOnce);
            Assert.AreEqual(1, rig.Remote.Calls.Count(c => c.Login is RemoteLogin.KeyOnce), at);
            Assert.IsTrue(rig.Remote.Calls.Skip(keyed + 1).All(c => c.Login is RemoteLogin.AppKey), $"{at}: after the key's call, the app's key alone");
            Assert.IsFalse(rig.Store.HoldsOwnerKey, at);
        }
    }

    /// <summary>**The password's page of a sudo password has no key's row, and takes no key**: the app's key got in, and
    /// the password is for <c>sudo</c>. The bug: the owner's key offered to a server that takes the app's key.</summary>
    [TestMethod]
    public async Task The_page_of_a_sudo_password_has_no_key_row()
    {
        await using var rig = await AtTheCheck(new KeyServer("admin") { HasAppKey = true }, "admin");
        var s = rig.Store.State;
        Assert.AreEqual((VpsPhase.Password, ServerCheck.PasswordNeed.Sudo as ServerCheck.PasswordNeed?), (s.Vps.Phase, s.Vps.Need), s.Vps.Why);
        CollectionAssert.AreEqual(new[] { SetupScreens.Password, SetupScreens.UsedOnce }, SetupScreens.Of(s).Controls.Select(c => c.Words).ToArray());
        var given = Key().File;
        await rig.Store.ChooseKey(given, "id_ed25519");
        Assert.IsTrue(given.All(b => b == 0), "the bytes are cleared");
        Assert.IsFalse(rig.Store.HoldsOwnerKey);
        Assert.IsNull(rig.Store.State.Vps.KeyName);
        Assert.IsFalse(rig.Remote.Calls.Any(c => c.Login is RemoteLogin.KeyOnce));
    }

    /// <summary>**A key refused on the password's page comes back to that page**, its row empty, with the key's sentence
    /// under it, and the password is still offered; a password given there then takes the place of a key that was
    /// chosen, which goes. The bugs: a refused key that sends the owner to the stop of a server that takes keys only,
    /// where the password is gone although the server takes it; a chosen key kept in memory after the owner took the
    /// password's way.</summary>
    [TestMethod]
    public async Task A_key_refused_on_the_password_page_comes_back_to_that_page()
    {
        var server = new KeyServer(keyCall: (_, _) => StandInRemote.Failed(RemoteFailure.LoginRefused)) { Ways = ["publickey", "password"] };
        await using var rig = await AtTheCheck(server);
        await rig.Store.ChooseKey(Key().File, "id_ed25519");
        var s = rig.Store.State;
        Assert.AreEqual((VpsPhase.Password, ServerCheck.PasswordNeed.Ssh as ServerCheck.PasswordNeed?, false),
                        (s.Vps.Phase, s.Vps.Need, s.Vps.KeysOnly), s.Vps.Why ?? s.Vps.KeyWarning);
        Assert.AreEqual(($"{Server} did not take that key for root.", null as string), (s.Vps.KeyWarning, s.Vps.KeyName));
        var controls = SetupScreens.Of(s).Controls;
        CollectionAssert.AreEqual(new[] { SetupScreens.Password, SetupScreens.UsedOnce, SetupScreens.SshKey, SetupScreens.KeyNeverLeaves,
                                          $"{Server} did not take that key for root." },
                                  controls.Select(c => c.Words).ToArray());
        Assert.AreEqual(SetupScreens.ChooseKeyWords, controls[2].Lines![0]);
        Assert.IsFalse(rig.Store.HoldsOwnerKey);

        await rig.Store.ChooseKey(Key("Pâss-phrase-of-the-test").File, "id_ed25519");
        Assert.IsTrue(rig.Store.State.Vps.KeyAsksPassphrase);
        Assert.IsTrue(rig.Store.HoldsOwnerKey);
        await rig.Store.GivePasswordAsync("not the password".ToCharArray());
        s = rig.Store.State;
        Assert.IsFalse(rig.Store.HoldsOwnerKey, "the password's way takes the place of the chosen key");
        Assert.AreEqual((null as string, false), (s.Vps.KeyName, s.Vps.KeyAsksPassphrase));
        Assert.AreEqual($"{Server} did not take that password for root.", s.Vps.Why);
        Assert.AreEqual(1, rig.Remote.Calls.Count(c => c.Login is RemoteLogin.KeyOnce));
    }

    /// <summary>**A password that the server never asked for goes from the password's page to the keys-only stop**, with
    /// its sentence and the key's row, and a key chosen there then works: a server that names keyboard-interactive and
    /// asks for no password on it (LoginNotOffered; the password was not sent). The bug: such a server read as one that
    /// refused the password, so the owner gets Try again and types the password again and again, with no key's row.</summary>
    [TestMethod]
    public async Task A_password_that_the_server_never_asked_for_goes_to_the_keys_only_stop()
    {
        await using var rig = await AtTheCheck(new KeyServer { Ways = ["publickey", "keyboard-interactive"], AsksNoPassword = true });
        Assert.AreEqual((VpsPhase.Password, ServerCheck.PasswordNeed.Ssh as ServerCheck.PasswordNeed?), (rig.Store.State.Vps.Phase, rig.Store.State.Vps.Need));
        var password = "not asked for".ToCharArray();
        await rig.Store.GivePasswordAsync(password);
        var s = rig.Store.State;
        Assert.AreEqual((VpsPhase.Stopped, true), (s.Vps.Phase, s.Vps.KeysOnly), s.Vps.Why);
        Assert.AreEqual($"{Server} takes SSH keys only, so a password cannot open it. Choose its key.", s.Vps.Why);
        Assert.IsTrue(password.All(c => c == '\0'));
        var row = SetupScreens.Of(s).Controls.First();
        Assert.AreEqual((SetupScreens.SshKey, SetupScreens.ChooseKeyWords), (row.Words, row.Lines![0]));

        await rig.Store.ChooseKey(Key().File, "id_ed25519");
        s = rig.Store.State;
        Assert.AreEqual(VpsPhase.Ready, s.Vps.Phase, s.Vps.Why ?? s.Vps.KeyWarning);
        Assert.AreEqual(1, rig.Remote.Calls.Count(c => c.Login is RemoteLogin.KeyOnce));
        Assert.IsFalse(rig.Store.HoldsOwnerKey);
    }

    /// <summary>**A key with no passphrase puts this PC's key on the server in one call, and is kept nowhere**: after its
    /// call no call carries the owner's key; the model holds no byte and no name of it; the file's name, its key and the
    /// passphrase are in no record, setting or text; and the field never shows. The bugs: the owner's key used for the
    /// whole install (kept in memory for an hour), a key's path or bytes in a record, a field for a key that has no
    /// passphrase.</summary>
    [TestMethod]
    public async Task A_key_puts_this_PCs_key_on_the_server_once_and_is_kept_nowhere()
    {
        var server = new KeyServer();
        await using var rig = await AtTheKeysOnlyStop(server);
        var fields = new List<bool>();
        rig.Store.Changed += (_, s) => { lock (fields) fields.Add(s.Vps.KeyAsksPassphrase); };
        var (file, line) = Key();
        var given = file;
        await rig.Store.ChooseKey(given, "id_ed25519");
        var s = rig.Store.State;
        Assert.AreEqual(VpsPhase.Ready, s.Vps.Phase, s.Vps.Why ?? s.Vps.KeyWarning);
        Assert.IsTrue(given.All(b => b == 0), "the model clears the bytes that it was given");
        Assert.IsFalse(rig.Store.HoldsOwnerKey);
        Assert.IsNull(s.Vps.KeyName);
        lock (fields) Assert.IsFalse(fields.Any(f => f), "a key with no passphrase never shows the field");
        var keyed = rig.Remote.Calls.FindIndex(c => c.Login is RemoteLogin.KeyOnce);
        Assert.AreEqual(1, rig.Remote.Calls.Count(c => c.Login is RemoteLogin.KeyOnce));
        Assert.AreEqual(PasswordOnce.AddKey(rig.Store.State.Vps.Target is { } ? AppLine(rig) : ""), Unwrapped(rig.Remote.Calls[keyed].Program));
        Assert.IsTrue(rig.Remote.Calls.Skip(keyed + 1).All(c => c.Login is RemoteLogin.AppKey), "after the key's call, the app's key alone");

        rig.Store.InstallVps();
        await rig.Until(x => x.Install.Checklist is not null, "the install");
        Assert.IsTrue(rig.Remote.Calls.Skip(keyed + 1).All(c => c.Login is RemoteLogin.AppKey));
        var texts = new List<string> { rig.Store.State.ToString(), rig.Store.State.Vps.ToString() };
        texts.AddRange(Directory.EnumerateFiles(rig.Folder, "*", SearchOption.AllDirectories).Select(f => File.ReadAllText(f)));
        foreach (var name in new[] { SetupChoiceNames.ManagerName, SetupChoiceNames.AiProvider, SetupChoiceNames.ServersStep, SetupChoiceNames.Reports,
                                     SetupChoiceNames.ReportsWaiting, "tailscalePolicyPlace" })
            texts.Add(rig.Choices.Get(name) ?? "");
        Assert.IsFalse(texts.Any(t => t.Contains("id_ed25519", StringComparison.Ordinal) || t.Contains(line, StringComparison.Ordinal)),
                       "no file's name and no key in a record, a setting or a text");
    }

    private static string AppLine(SetupRig rig) => AppSshKey.PublicLine(rig.Box.Read(AppSshKey.BoxName)!);

    /// <summary>The program of a call as the Mac gives it to <c>/bin/sh -c</c>.</summary>
    private static string Unwrapped(string program) =>
        program.StartsWith("/bin/sh -c '", StringComparison.Ordinal) ? program[12..^1].Replace("'\\''", "'", StringComparison.Ordinal) : program;

    /// <summary>**A key with a passphrase shows the one field; a wrong passphrase says its sentence, empties the field and
    /// reaches no server; the right one opens the key.** The passphrase is in no text of the state, and goes with the
    /// key. The bugs: a field that is not there for such a key, a login try with a passphrase that the PC could have found
    /// wrong itself, a passphrase that stays in memory.</summary>
    [TestMethod]
    public async Task A_key_with_a_passphrase_shows_the_field_and_a_wrong_one_reaches_no_server()
    {
        const string passphrase = "Pâss-phrase-of-the-test";
        var server = new KeyServer();
        await using var rig = await AtTheKeysOnlyStop(server);
        var (file, _) = Key(passphrase);
        await rig.Store.ChooseKey(file, "id_ed25519");
        var s = rig.Store.State;
        Assert.AreEqual((VpsPhase.Stopped, true, "id_ed25519"), (s.Vps.Phase, s.Vps.KeyAsksPassphrase, s.Vps.KeyName));
        var controls = SetupScreens.Of(s).Controls;
        Assert.IsTrue(controls.Any(c => c.Kind == SetupControlKind.Secret && c.Words == SetupScreens.PassphrasePlaceholder));
        Assert.IsTrue(controls.Any(c => c.Words == SetupScreens.UsedOnce));
        Assert.AreEqual(SetupScreens.Change, controls.First().Lines![0]);
        var calls = rig.Remote.Calls.Count;

        var wrong = "not it".ToCharArray();
        await rig.Store.GiveKeyPassphrase(wrong);
        s = rig.Store.State;
        Assert.AreEqual((SetupScreens.WrongPassphrase, true), (s.Vps.KeyWarning, s.Vps.KeyAsksPassphrase));
        Assert.AreEqual(calls, rig.Remote.Calls.Count, "a wrong passphrase reaches no server");
        Assert.IsTrue(wrong.All(c => c == '\0'));
        Assert.AreEqual(SetupScreens.WrongPassphrase, SetupScreens.Of(s).Controls.Last().Words);

        var right = passphrase.ToCharArray();
        await rig.Store.GiveKeyPassphrase(right);
        s = rig.Store.State;
        Assert.AreEqual(VpsPhase.Ready, s.Vps.Phase, s.Vps.Why ?? s.Vps.KeyWarning);
        Assert.IsTrue(right.All(c => c == '\0'), "the passphrase goes with the key");
        Assert.IsFalse(rig.Store.HoldsOwnerKey);
        Assert.IsFalse(s.ToString().Contains(passphrase, StringComparison.Ordinal));
    }

    /// <summary>**A file that is no key says its sentence before any connection, a key that the server refuses says its
    /// own, and the row is empty again.** The bugs: a text file sent as a key; a refused key that the model keeps.</summary>
    [TestMethod]
    public async Task A_file_that_is_no_key_and_a_refused_key_say_their_sentences()
    {
        var server = new KeyServer(keyCall: (_, _) => StandInRemote.Failed(RemoteFailure.LoginRefused));
        await using var rig = await AtTheKeysOnlyStop(server);
        var calls = rig.Remote.Calls.Count;
        await rig.Store.ChooseKey(Encoding.UTF8.GetBytes("ssh-ed25519 AAAA a public key, not a private one"), "id_ed25519.pub");
        var s = rig.Store.State;
        Assert.AreEqual((SetupScreens.NotAKey, null as string), (s.Vps.KeyWarning, s.Vps.KeyName));
        Assert.AreEqual(calls, rig.Remote.Calls.Count, "no call for a file that is no key");

        await rig.Store.ChooseKey(Key().File, "id_ed25519");
        s = rig.Store.State;
        Assert.AreEqual((VpsPhase.Stopped, true), (s.Vps.Phase, s.Vps.KeysOnly));
        Assert.AreEqual($"{Server} did not take that key for root.", s.Vps.KeyWarning);
        Assert.IsNull(s.Vps.KeyName);
        Assert.IsFalse(rig.Store.HoldsOwnerKey);
    }

    /// <summary>**A server that takes the app's own key gets no call with the owner's key, also when one is chosen.** The
    /// bug: the owner's key offered to a server that needs none of it.</summary>
    [TestMethod]
    public async Task A_server_that_takes_the_apps_key_gets_no_call_with_the_owners_key()
    {
        await using var rig = new SetupRig();
        rig.ThroughTheFirstPages(ServersStep.One);
        rig.Store.ChooseOtherVps();
        await rig.Store.CheckVpsAsync(Server);
        Assert.AreEqual(VpsPhase.Ready, rig.Store.State.Vps.Phase);
        var given = Key().File;
        await rig.Store.ChooseKey(given, "id_ed25519");
        Assert.IsTrue(given.All(b => b == 0));
        Assert.IsFalse(rig.Store.HoldsOwnerKey);
        Assert.IsNull(rig.Store.State.Vps.KeyName);
        Assert.IsFalse(rig.Remote.Calls.Any(c => c.Login is RemoteLogin.KeyOnce));
    }

    /// <summary>**A user whose sudo asks for its password gets it asked once, and the owner's key's call goes again with it
    /// on the first line of its input**; the install then holds it. The bug: a user that is not root left with no way in.</summary>
    [TestMethod]
    public async Task A_sudo_that_asks_for_its_password_gets_it_once_with_the_owners_key()
    {
        KeyServer? server = null;
        server = new KeyServer("admin", (call, input) =>
        {
            if (input is null) return StandInRemote.Said(PasswordOnce.SudoMark + "refused");
            server!.HasAppKey = true;
            return StandInRemote.Said($"{PasswordOnce.KeyAdded}\n{PasswordOnce.SudoMark}password");
        });
        await using var rig = await AtTheKeysOnlyStop(server, "admin");
        await rig.Store.ChooseKey(Key().File, "id_ed25519");
        var s = rig.Store.State;
        Assert.AreEqual((VpsPhase.Password, ServerCheck.PasswordNeed.Sudo as ServerCheck.PasswordNeed?), (s.Vps.Phase, s.Vps.Need));
        Assert.IsTrue(rig.Store.HoldsOwnerKey, "the key stays for the one call with the password");
        await rig.Store.GivePasswordAsync("sudo-pass".ToCharArray());
        s = rig.Store.State;
        Assert.AreEqual((VpsPhase.Ready, true), (s.Vps.Phase, s.Vps.HoldsSudo), s.Vps.Why ?? s.Vps.KeyWarning);
        var keyed = rig.Remote.Calls.Select((c, i) => (c, i)).Where(x => x.c.Login is RemoteLogin.KeyOnce).ToList();
        Assert.AreEqual(2, keyed.Count);
        Assert.AreEqual("sudo-pass\n", Encoding.UTF8.GetString(rig.Remote.Inputs[keyed[1].i]!));
        Assert.IsFalse(rig.Store.HoldsOwnerKey);
    }
}
