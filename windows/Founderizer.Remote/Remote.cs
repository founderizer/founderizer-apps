using System;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Remote;

/// <summary>A server as the owner gave it: its address or host name, its SSH port, and the user the app logs in as.</summary>
public sealed record RemoteTarget(string Host, int Port, string User);

/// <summary>How the app logs in. Never the owner's own keys, never an SSH agent, never a file of keys.</summary>
public abstract record RemoteLogin
{
    private RemoteLogin() { }

    /// <summary>The app's own key (<see cref="AppSshKey"/>), and nothing else: the Mac's <c>IdentitiesOnly=yes -i KEY</c>.</summary>
    public sealed record AppKey() : RemoteLogin;

    /// <summary>
    /// A password that the owner typed once (the Mac's <c>PasswordOnce</c>), kept in memory only. The call clears this
    /// array when it ends, whatever its outcome, so a caller that needs the password again keeps a copy of its own.
    /// It is offered once: a server that refuses it is not asked again in the same call.
    /// </summary>
    public sealed record PasswordOnce(char[] Password) : RemoteLogin;
}

/// <summary>What a host key must be. <c>TakeNew</c> is OpenSSH's <c>accept-new</c>; <c>Known</c> is its <c>yes</c>.</summary>
public enum HostKeyRule
{
    /// <summary>A server with no key on record has its key kept now; a server with a key on record must show that key.</summary>
    TakeNew,
    /// <summary>The server must show the key on record. A server with none is refused.</summary>
    Known,
}

/// <summary>
/// One program on one server. <c>Program</c> is the whole text that the Mac gives <c>ssh</c> as its command, after the
/// wrap for <c>sudo</c>. <c>Input</c> is the bytes of its standard input (null: the program reads an end of file at
/// once, as the Mac's <c>/dev/null</c>). The call does not change <c>Input</c>; a caller that put a password in it
/// clears it. <c>Connect</c> bounds the connection, the handshake, the key exchange and the login, each wait of them.
/// <c>Limit</c> bounds the whole call, as the Mac's <c>LocalShell</c> bounds its <c>ssh</c> (600 s unless a step gives
/// its own): a server whose network answers while its programs stand still ends the call as
/// <see cref="RemoteFailure.TimedOut"/>.
/// </summary>
public sealed record RemoteCall(RemoteTarget Target, string Program, byte[]? Input, RemoteLogin Login,
                                HostKeyRule HostKey, TimeSpan Connect)
{
    /// <summary>The Mac's <c>ConnectTimeout=20</c>.</summary>
    public static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(20);

    /// <summary>The Mac's <c>LocalShell.run</c> limit when a step gives none.</summary>
    public static readonly TimeSpan DefaultLimit = TimeSpan.FromSeconds(600);

    /// <summary>The longest that the whole call may take.</summary>
    public TimeSpan Limit { get; init; } = DefaultLimit;

    /// <summary>The server alone: a program can hold a one-time code (a join line), and this text can reach a log.</summary>
    public override string ToString() => $"RemoteCall {{ Target = {Target} }}";
}

/// <summary>
/// Why a call did not run its program to its end. The ways of not reaching a server are apart, because the Mac says a
/// sentence for each (<c>ServerCheck.unreached(_:said:)</c>, <c>PasswordOnce.refusal</c>).
/// </summary>
public enum RemoteFailure
{
    /// <summary>The server did not answer in time: no connection, no SSH greeting, or no key exchange. Nothing was sent.</summary>
    NoAnswer,
    /// <summary>The PC could not find the server's name. Nothing was sent.</summary>
    NotFound,
    /// <summary>The server's port refused the connection: nothing listens there, or a firewall says no. Nothing was sent.</summary>
    Refused,
    /// <summary>The server closed the connection before any login. Nothing was sent.</summary>
    Closed,
    /// <summary>The server showed another key than the one on record. Nothing was sent: no login, no program, no input.</summary>
    HostKeyChanged,
    /// <summary>Under <c>Known</c>, the server has no key on record. Nothing was sent.</summary>
    HostKeyUnknown,
    /// <summary>The server did not take the login: the app's key, or the password that it was given.</summary>
    LoginRefused,
    /// <summary>A password login to a server that never asked for a password (it takes keys only). The password was not sent.</summary>
    LoginNotOffered,
    /// <summary>The connection ended while the program ran.</summary>
    Dropped,
    /// <summary>The call passed its <see cref="RemoteCall.Limit"/>.</summary>
    TimedOut,
    /// <summary>The caller canceled the call.</summary>
    Canceled,
}

/// <summary>
/// What a call gave. <c>ExitStatus</c> is the program's status, or null when it has none: a failure, or a program that
/// a signal ended. <c>Output</c> and <c>Errors</c> are its standard output and standard error as UTF-8, each the first
/// 1 MiB (the Mac's bound); what came before a failure stays in them.
/// </summary>
public sealed record RemoteResult(int? ExitStatus, string Output, string Errors, RemoteFailure? Failure);

/// <summary>SSH from the owner's computer: one program on one server, with one login, under one host key rule.</summary>
public interface IRemote : IAsyncDisposable
{
    /// <summary>
    /// Runs <c>call.Program</c> on <c>call.Target</c>. <c>line</c>, when given, gets each line of standard output and of
    /// standard error as it arrives (without its line end; never after the call has returned; never two at once). A
    /// failure is a result, never an exception; an exception is a fault of the caller (a call that breaks
    /// <see cref="RemoteRules"/>, or an <see cref="RemoteLogin.AppKey"/> while the app has no key).
    /// </summary>
    Task<RemoteResult> RunAsync(RemoteCall call, Action<string>? line, CancellationToken cancel);
}

/// <summary>The rules that every call keeps, whichever implementation runs it.</summary>
public static partial class RemoteRules
{
    /// <summary>
    /// Throws for a call that no server may get. The address and the user take the Mac's own patterns
    /// (<c>InstallTarget.problem</c>), so the pages' words are said before a call. A program must have line feeds only
    /// and no NUL (windows-app-plan-v2.md, 8.10): a C# source that a Windows checkout gave CRLF line ends puts a
    /// carriage return into each line of a multi-line string literal, and <c>/bin/sh</c> then reads <c>$'\r'</c> as
    /// part of each command.
    /// </summary>
    public static void Check(RemoteCall call)
    {
        ArgumentNullException.ThrowIfNull(call);
        ArgumentNullException.ThrowIfNull(call.Target);
        ArgumentNullException.ThrowIfNull(call.Login);
        ArgumentNullException.ThrowIfNull(call.Program);
        if (!HostPattern().IsMatch(call.Target.Host ?? ""))
            throw new ArgumentException("The server's address is not one that SSH reaches.", nameof(call));
        if (!UserPattern().IsMatch(call.Target.User ?? ""))
            throw new ArgumentException("The user is not one that a Linux server has.", nameof(call));
        if (call.Target.Port is < 1 or > 65535)
            throw new ArgumentException("The SSH port is between 1 and 65535.", nameof(call));
        if (call.Program.Length == 0)
            throw new ArgumentException("The program is empty.", nameof(call));
        if (call.Program.Contains('\r') || call.Program.Contains('\0'))
            throw new ArgumentException("A program for a server has line feeds only, and no carriage return or NUL.", nameof(call));
        if (call.Connect <= TimeSpan.Zero || call.Connect > TimeSpan.FromMinutes(10))
            throw new ArgumentException("The time to connect is between 0 and 10 minutes.", nameof(call));
        if (call.Limit <= TimeSpan.Zero || call.Limit > TimeSpan.FromHours(24))
            throw new ArgumentException("The limit of a call is between 0 and 24 hours.", nameof(call));
        if (call.Login is RemoteLogin.PasswordOnce { Password: null })
            throw new ArgumentException("A password login needs its password.", nameof(call));
    }

    [GeneratedRegex(@"^[a-zA-Z0-9]([a-zA-Z0-9.:-]{0,252}[a-zA-Z0-9])?\z")]
    private static partial Regex HostPattern();

    [GeneratedRegex(@"^[a-z_][a-z0-9_-]{0,31}\z")]
    private static partial Regex UserPattern();
}
