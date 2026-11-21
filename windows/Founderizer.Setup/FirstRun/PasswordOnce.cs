using System;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Remote;
using Founderizer.Setup.Install;

namespace Founderizer.Setup.FirstRun;

/// <summary>**The password, once** (the Mac's FleetCore/PasswordOnce.swift; the owner, 4 November 2026: "maybe users will
/// only have ssh access to that server.. with nothing else installed"). When a server takes none of this PC's keys, or
/// the <c>sudo</c> of the user that the PC logs in as asks for a password, the app asks for that password once, uses it
/// to put the app's own key on the server, and forgets it; every connection after that one uses the key. After the
/// install the server's own hardening turns password login off.
///
/// The password is a <c>char[]</c> in this PC's memory and nowhere else: never in a file, a program's text, a record, a
/// log or an exception, never sent to the hub, and cleared when it is of no more use. It reaches the server in two
/// places only: the login of this one call (<see cref="RemoteLogin.PasswordOnce"/>, which clears its own copy), and the
/// first line of the call's standard input, for <c>sudo -S</c>. The program of the call (<see cref="Program"/>) and its
/// marks are held to <c>app/vectors/remote-password.json</c>, which the Mac's own code writes.</summary>
public static class PasswordOnce
{
    /// <summary>What the remote program prints once the key is in <c>authorized_keys</c>, and how that user becomes root.</summary>
    public const string KeyAdded = "founderizer-key=added";
    public const string SudoMark = "founderizer-sudo=";
    /// <summary>What the server prints once this PC reached it with its own key alone.</summary>
    public const string KeyWorks = "founderizer-key=works";

    /// <summary>The program of the proof that the app's own key alone opens the server.</summary>
    public const string WorksProgram = "echo " + KeyWorks;

    /// <summary>The Mac's limits of the two calls: the key's call 90 seconds, the proof 60.</summary>
    internal static readonly TimeSpan KeyLimit = TimeSpan.FromSeconds(90), WorksLimit = TimeSpan.FromSeconds(60);

    /// <summary>**The program of that one session, as the user it logged in as** (the Mac's <c>addKey</c>). First how that
    /// user becomes root: it is root, its <c>sudo</c> asks nothing, or <c>sudo -S</c> takes the password on the first
    /// line of standard input (<c>-k</c>: it asks every time, so it always reads that line). A user that cannot become root
    /// is said so, and nothing is left on the server. Then the key goes into <c>~/.ssh/authorized_keys</c>, once:
    /// <c>~/.ssh</c> is made with mode 700 and the file with 600 where they are not there, a file whose last line has no
    /// newline gets one first, and a key that is there already, with any comment or options, is not added again.</summary>
    public static string AddKey(string line) =>
        "umask 077; if [ \"$(id -u)\" = 0 ]; then sudo=root; elif sudo -n true >/dev/null 2>&1; then sudo=nopasswd; "
        + "elif sudo -S -k -p '' true >/dev/null 2>&1; then sudo=password; else echo " + SudoMark + "refused; exit 0; fi; "
        + "key=" + InstallPlan.Quote(line) + "; blob=${key#* }; blob=${blob%% *}; dir=\"$HOME/.ssh\"; "
        + "file=\"$dir/authorized_keys\"; [ -d \"$dir\" ] || mkdir -m 700 \"$dir\" || exit 1; "
        + "if [ -s \"$file\" ] && [ -n \"$(tail -c 1 \"$file\")\" ]; then echo >> \"$file\"; fi; "
        + "grep -qF \"$blob\" \"$file\" 2>/dev/null || printf '%s\\n' \"$key\" >> \"$file\" || exit 1; "
        + "echo " + KeyAdded + "; echo \"" + SudoMark + "$sudo\"";

    /// <summary>The whole command that the server gets for the key's call: the Mac's <c>/bin/sh -c '…'</c>.</summary>
    public static string Program(string publicLine) => "/bin/sh -c " + InstallPlan.Quote(AddKey(publicLine));

    /// <summary>What the password did.</summary>
    public abstract record Outcome
    {
        /// <summary>The app's own key is on the server and opens it. <paramref name="KeepsPassword"/>: the <c>sudo</c> of
        /// that user asks for the password, so the install that follows gets the same password, and clears it when it
        /// ends. Otherwise it is cleared already.</summary>
        public sealed record Ready(bool KeepsPassword) : Outcome;
        /// <summary>One plain line of why not. The password is cleared.</summary>
        public sealed record Refused(string Says) : Outcome;
    }

    /// <summary>**Logs in once with the password where <paramref name="need"/> is SSH, or with the app's own key where it
    /// is <c>sudo</c>; puts the app's public key in that account's <c>authorized_keys</c>; reads whether that user's
    /// <c>sudo</c> takes the same password; then proves that the app's key alone opens the server.** The caller gives
    /// the app's public line (<see cref="AppSshKey"/>, with its private half in the secret box). <paramref name="password"/>
    /// is cleared when the outcome is not <see cref="Outcome.Ready"/> with <c>KeepsPassword</c>.</summary>
    public static Task<Outcome> RunAsync(IRemote remote, InstallTarget target, ServerCheck.PasswordNeed need, char[] password,
                                         string publicLine, CancellationToken cancel = default)
    {
        var login = need == ServerCheck.PasswordNeed.Ssh ? new RemoteLogin.PasswordOnce((char[])password.Clone()) : (RemoteLogin)new RemoteLogin.AppKey();
        return AddAsync(remote, target, need, login, password, publicLine, cancel);
    }

    /// <summary>The key's call with a given way in (the password once, the app's key, or the owner's own key once), and
    /// the password of a <c>sudo</c> that asks for one on the first line of its input, or none. Shared by the password and
    /// by the owner's key, whose program is the same (the Mac's one text for both).</summary>
    internal static async Task<Outcome> AddAsync(IRemote remote, InstallTarget target, ServerCheck.PasswordNeed need, RemoteLogin login,
                                                 char[]? sudoPassword, string publicLine, CancellationToken cancel)
    {
        var keeps = false;
        byte[]? input = null;
        try
        {
            input = Line(sudoPassword);
            var call = new RemoteCall(target.Remote, Program(publicLine), input, login, HostKeyRule.TakeNew, RemoteCall.ConnectTimeout)
            {
                Limit = KeyLimit,
            };
            var answer = await remote.RunAsync(call, null, cancel).ConfigureAwait(false);
            if (answer.Failure == RemoteFailure.Canceled) throw new OperationCanceledException(cancel);
            if (answer.Failure is { } failure) return new Outcome.Refused(Refusal(failure, login, target));
            var said = Lines(answer.Output + "\n" + answer.Errors);
            var sudo = said.LastOrDefault(l => l.StartsWith(SudoMark, StringComparison.Ordinal))?[SudoMark.Length..];
            if (sudo == "refused")
                return new Outcome.Refused(need == ServerCheck.PasswordNeed.Sudo ? SudoRefused(target.Host) : ServerCheck.NotRoot(target.User));
            if (!said.Contains(KeyAdded) || sudo is not ("root" or "nopasswd" or "password"))
                return new Outcome.Refused(CannotAdd(target.User, target.Host));
            var works = await WorksAsync(remote, target, cancel).ConfigureAwait(false);
            // With sudo the app's own key opened the server already; not so with the owner's key, which goes after this call.
            if (!works && (need != ServerCheck.PasswordNeed.Sudo || login is RemoteLogin.KeyOnce))
                return new Outcome.Refused(StillAsks(target.Host, target.User));
            keeps = sudo == "password" && sudoPassword is { Length: > 0 };
            return new Outcome.Ready(keeps);
        }
        finally
        {
            if (input is not null) CryptographicOperations.ZeroMemory(input);
            if (!keeps && sudoPassword is not null) Array.Clear(sudoPassword);
        }
    }

    /// <summary>**The app's own key alone opens the server**: one call with it that prints the mark.</summary>
    internal static async Task<bool> WorksAsync(IRemote remote, InstallTarget target, CancellationToken cancel)
    {
        var call = new RemoteCall(target.Remote, InstallPlan.Command(WorksProgram, target, Runs.Login), null, new RemoteLogin.AppKey(),
                                  HostKeyRule.TakeNew, RemoteCall.ConnectTimeout) { Limit = WorksLimit };
        var answer = await remote.RunAsync(call, null, cancel).ConfigureAwait(false);
        if (answer.Failure == RemoteFailure.Canceled) throw new OperationCanceledException(cancel);
        return answer.Failure is null && Lines(answer.Output).Contains(KeyWorks);
    }

    /// <summary>Why the server did not let the session in, in one line: a server that takes keys only, a password or a key
    /// that it did not take, and the words of a call that did not reach it.</summary>
    internal static string Refusal(RemoteFailure failure, RemoteLogin login, InstallTarget target) => failure switch
    {
        RemoteFailure.LoginRefused when login is RemoteLogin.PasswordOnce => ServerCheck.PasswordRefused(target.Host, target.User),
        RemoteFailure.LoginRefused when login is RemoteLogin.KeyOnce => KeyNotTaken(target.Host, target.User),
        _ => ServerCheck.Failed(target.Host, target.Port, target.User, failure, login, firstRun: true),
    };

    /// <summary>The Mac's sentences of the program's answer, with "PC": a sudo that did not take the password, a key that
    /// could not be added, and a server that still asks for a password with the app's key in place.</summary>
    public static string SudoRefused(string server) => $"sudo on {server} did not take that password.";
    public static string CannotAdd(string user, string server) => $"This PC could not add its key to {user}'s ~/.ssh/authorized_keys on {server}.";
    public static string StillAsks(string server, string user) =>
        $"{server} still asks for a password with this PC's key in {user}'s authorized_keys, so its SSH server reads keys from elsewhere.";

    /// <summary>A key of the owner's that the server did not take, in the form of the password's sentence: new words of the
    /// PC, which go to the owner with wave A's built pictures (not his yet).</summary>
    public static string KeyNotTaken(string server, string user) => $"{server} did not take that key for {user}.";

    /// <summary>**The owner's key once** (the owner's "Choose key, as Mac" of 21 November 2026; plan 5.5): the same
    /// program as the password's, in one call that logs in with the owner's own key and no other way
    /// (<see cref="RemoteLogin.KeyOnce"/>, which clears its two arrays when it has read the key), with the password of a
    /// sudo that asks for one on the first line of its input, then the proof that the app's own key alone opens the
    /// server. Here the proof must pass also with a sudo password: the owner's key is not kept, so the app's key is the
    /// only way in after this call. <paramref name="sudoPassword"/> is cleared unless the outcome keeps it.</summary>
    public static Task<Outcome> KeyAsync(IRemote remote, InstallTarget target, RemoteLogin.KeyOnce key, char[]? sudoPassword, string publicLine,
                                         CancellationToken cancel = default) =>
        AddAsync(remote, target, sudoPassword is null ? ServerCheck.PasswordNeed.Ssh : ServerCheck.PasswordNeed.Sudo, key, sudoPassword,
                 publicLine, cancel);

    /// <summary>The password and a newline as bytes, for <c>sudo -S</c>; none for no password. The caller clears them.</summary>
    private static byte[]? Line(char[]? password)
    {
        if (password is not { Length: > 0 }) return null;
        var bytes = new byte[Encoding.UTF8.GetByteCount(password) + 1];
        Encoding.UTF8.GetBytes(password, 0, password.Length, bytes, 0);
        bytes[^1] = (byte)'\n';
        return bytes;
    }

    private static string[] Lines(string text) =>
        text.Split('\n').Select(l => l.TrimEnd('\r').Trim()).Where(l => l.Length > 0).ToArray();
}
