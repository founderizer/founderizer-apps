using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Renci.SshNet;
using Renci.SshNet.Common;
using Renci.SshNet.Messages.Transport;
using Renci.SshNet.Security;
using Renci.SshNet.Security.Cryptography;

namespace Founderizer.Remote;

/// <summary>
/// **<see cref="IRemote"/> with SSH.NET**, the one file that names it. One connection for each call, as the Mac's
/// <c>ssh</c> makes one for each program; it ends with the call.
///
/// The Mac's options, as this file keeps them: <c>ConnectTimeout=20</c> is the call's <c>Connect</c> (the connection,
/// the greeting, the key exchange and each wait of the login); <c>ServerAliveInterval=30</c> is a keep-alive every 30
/// seconds, so a server that went away ends the call as <see cref="RemoteFailure.Dropped"/> once the PC's network gives
/// up on it; <c>BatchMode=yes</c> and <c>NumberOfPasswordPrompts=0</c> are a login with <c>call.Login</c> alone;
/// <c>IdentitiesOnly=yes -i KEY</c> is <see cref="RemoteLogin.AppKey"/>, or <see cref="RemoteLogin.KeyOnce"/> for the key
/// that the owner picked (the Mac's <c>-i</c> with the file of "Choose key"); <c>StrictHostKeyChecking</c> is
/// <see cref="HostKeyRule"/>, checked against <see cref="HostKeys"/> before anything is sent.
///
/// The algorithms are the Mac's <c>ssh</c>'s (OpenSSH 10): no SHA-1 key exchange, no CBC cipher, no <c>ssh-rsa</c>
/// signature of a host, no compression; and a host key as a plain key, never a certificate, because the record holds
/// keys. A server with a key on record is asked for a key of that type first, so a server that has several types shows
/// the one on record, and a server that no longer has it shows another, which is a changed key.
/// </summary>
public sealed class SshRemote : IRemote
{
    /// <summary>The Mac's <c>ServerAliveInterval=30</c>.</summary>
    public static readonly TimeSpan KeepAlive = TimeSpan.FromSeconds(30);

    /// <summary>What each of standard output and standard error keeps: the first 1 MiB, as the Mac's <c>LocalShell</c>.</summary>
    internal const int OutputLimit = 1 << 20;

    /// <summary>A line longer than this goes to the caller in pieces of this length, so a line never fills memory.</summary>
    internal const int LineLimit = 1 << 16;

    private static readonly string[] WeakKeyExchanges =
        ["diffie-hellman-group-exchange-sha1", "diffie-hellman-group14-sha1", "diffie-hellman-group1-sha1"];
    private static readonly string[] WeakCiphers = ["aes128-cbc", "aes192-cbc", "aes256-cbc", "3des-cbc"];

    private readonly HostKeys hostKeys;
    private readonly Func<byte[]?> appKey;
    private readonly CancellationTokenSource closing = new();
    private readonly object gate = new();
    private int running;
    private bool disposed;
    private TaskCompletionSource? idle;

    /// <summary>
    /// <c>appKey</c> gives a fresh copy of the app key's private half from the secret box, or null while there is none;
    /// the call clears the copy when its connection ends.
    /// </summary>
    public SshRemote(HostKeys hostKeys, Func<byte[]?> appKey)
    {
        this.hostKeys = hostKeys ?? throw new ArgumentNullException(nameof(hostKeys));
        this.appKey = appKey ?? throw new ArgumentNullException(nameof(appKey));
    }

    /// <inheritdoc/>
    public async Task<RemoteResult> RunAsync(RemoteCall call, Action<string>? line, CancellationToken cancel)
    {
        try
        {
            RemoteRules.Check(call);
            lock (gate)
            {
                ObjectDisposedException.ThrowIf(disposed, this);
                running++;
            }
        }
        catch
        {
            // A call that no server may get ends here: its password or the owner's key is cleared all the same.
            call?.Login?.Clear();
            throw;
        }
        try
        {
            // A cancel of the caller (or of this SshRemote) is Canceled; the call's own limit is TimedOut.
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancel, closing.Token);
            using var limit = new CancellationTokenSource(call.Limit);
            using var both = CancellationTokenSource.CreateLinkedTokenSource(stop.Token, limit.Token);
            var stopped = () => stop.IsCancellationRequested ? RemoteFailure.Canceled : RemoteFailure.TimedOut;
            return await new Run(this, call, line, both.Token, stopped).Go().ConfigureAwait(false);
        }
        finally
        {
            lock (gate)
            {
                running--;
                if (running == 0) idle?.TrySetResult();
            }
        }
    }

    /// <summary>Cancels each call that runs and waits for it to end.</summary>
    public async ValueTask DisposeAsync()
    {
        Task wait;
        lock (gate)
        {
            if (idle is null)
            {
                disposed = true;
                idle = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                if (running == 0) idle.TrySetResult();
            }
            wait = idle.Task;
        }
        await closing.CancelAsync().ConfigureAwait(false);
        await wait.ConfigureAwait(false);
    }

    /// <summary>One call: its connection, its program, and what it printed.</summary>
    private sealed class Run(SshRemote owner, RemoteCall call, Action<string>? line, CancellationToken cancel,
                             Func<RemoteFailure> stopped)
    {
        private readonly Printed printed = new(line);
        private int refused;                       // a HostKeyVerdict that the host key check refused, plus one
        private byte[]? seed;
        private ED25519Key? key;
        private OwnerKey? ownerKey;
        private Once? password;
        private readonly List<AuthenticationMethod> methods = [];
        private IReadOnlyList<string>? ways;      // the server's ways with its last refusal of the login (LoginWays)

        public async Task<RemoteResult> Go()
        {
            SshClient? client = null;
            Task? connecting = null;
            SshCommand? command = null;
            Task[] pumps = [];
            Task? feeding = null;
            try
            {
                Login();
                var target = call.Target;
                var info = new ConnectionInfo(target.Host, target.Port, target.User, [.. methods])
                {
                    Timeout = call.Connect,
                    Encoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                };
                Harden(info, owner.hostKeys.Find(target.Host, target.Port));
                client = new SshClient(info) { KeepAliveInterval = KeepAlive };
                client.HostKeyReceived += CheckHostKey;
                if (cancel.IsCancellationRequested) return Result(null, stopped());

                // The token reaches the connection and the greeting; each later wait of the handshake and the login is
                // bounded by Connect, and a cancel in one of them returns at once and lets it end behind the call.
                connecting = client.ConnectAsync(cancel);
                try { await connecting.WaitAsync(cancel).ConfigureAwait(false); }
                catch (Exception e) { return Result(null, ConnectFailure(e)); }
                connecting = null;

                // From here a wait has no bound of its own (a program that reads its input late, a server that is slow to
                // open a channel): the keep-alive and the caller's cancel end it, as with the Mac's `ssh`.
                info.Timeout = Timeout.InfiniteTimeSpan;
                try
                {
                    // A connection that ended since the login is Dropped here too: CreateCommand throws on it.
                    command = client.CreateCommand(Wire(call));
                    pumps = [printed.Pump(command.OutputStream, Printed.Out), printed.Pump(command.ExtendedOutputStream, Printed.Err)];
                    // ExecuteAsync opens the channel and waits for the answer to the program's request before it returns.
                    var request = command;
                    var opening = Task.Factory.StartNew(() => request.ExecuteAsync(cancel), CancellationToken.None,
                                                        TaskCreationOptions.DenyChildAttach, TaskScheduler.Default);
                    _ = opening.ContinueWith(t => t.Exception, CancellationToken.None,
                                             TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
                    var ends = await opening.WaitAsync(cancel).ConfigureAwait(false);
                    if (call.Input is { Length: > 0 } input)
                        feeding = Task.Run(() => Feed(request, input), CancellationToken.None);
                    await ends.WaitAsync(cancel).ConfigureAwait(false);
                }
                catch (Exception e) { return await Finish(client, command, pumps, null, RunFailure(e)).ConfigureAwait(false); }
                return await Finish(client, command, pumps, command!.ExitStatus, null).ConfigureAwait(false);
            }
            finally
            {
                if (connecting is { IsCompleted: false })
                {
                    // A login still waits on the server: its secrets are cleared once it has ended, not under it.
                    var left = client!;
                    _ = connecting.ContinueWith(t => { _ = t.Exception; Quietly(left.Dispose); Release(); }, CancellationToken.None,
                                                TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
                }
                else
                {
                    if (command is not null) Quietly(command.Dispose);
                    if (client is not null) Quietly(client.Dispose);
                    Release();
                }
                if (feeding is not null) await Ended(feeding, TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            }
        }

        /// <summary>
        /// The login's methods: the app's key alone, the owner's key alone, or the password once (keyboard-interactive
        /// first, as the Mac). The caller's arrays are cleared here, before anything connects.
        /// </summary>
        private void Login()
        {
            var user = call.Target.User;
            switch (call.Login)
            {
                case RemoteLogin.AppKey:
                    seed = owner.appKey() ?? throw new InvalidOperationException(
                        "The app has no SSH key yet: make it with AppSshKey.Make and keep it in the secret box first.");
                    if (seed.Length != AppSshKey.Length)
                        throw new InvalidOperationException("The app's SSH key in the secret box is not one.");
                    key = new ED25519Key(seed);
                    methods.Add(new PrivateKeyAuthenticationMethod(user, new PrivateKeyFile(key)));
                    break;
                case RemoteLogin.PasswordOnce once:
                    password = new Once(Encoding.UTF8.GetBytes(once.Password));
                    Array.Clear(once.Password);
                    methods.Add(new OnceKeyboardInteractive(user, password));
                    methods.Add(new OncePassword(user, password));
                    break;
                case RemoteLogin.KeyOnce once:
                    OwnerKeyCheck state;
                    try { state = OpenOwnerKey(once.KeyFile, once.Passphrase, out ownerKey); }
                    finally { once.Clear(); }
                    if (ownerKey is null)
                        throw new ArgumentException(state switch
                        {
                            OwnerKeyCheck.NeedsPassphrase => "The owner's key has a passphrase, and the call gave none.",
                            OwnerKeyCheck.WrongPassphrase => "The passphrase that the call gave does not open the owner's key.",
                            _ => "The owner's file is not a private key that the app reads.",
                        } + " Check it with OwnerKeyFile.Check first.", nameof(call));
                    methods.Add(new PrivateKeyAuthenticationMethod(user, ownerKey));
                    break;
                default:
                    throw new ArgumentException("A login is the app's key, the owner's key or a password.", nameof(call));
            }
        }

        private void CheckHostKey(object? sender, HostKeyEventArgs e)
        {
            var verdict = owner.hostKeys.Check(call.Target.Host, call.Target.Port, e.HostKey, call.HostKey);
            if (verdict == HostKeyVerdict.Trusted) return;
            Interlocked.CompareExchange(ref refused, (int)verdict + 1, 0);
            e.CanTrust = false;
        }

        private RemoteFailure? HostKeyFailure() => Volatile.Read(ref refused) switch
        {
            0 => null,
            (int)HostKeyVerdict.Unknown + 1 => RemoteFailure.HostKeyUnknown,
            _ => RemoteFailure.HostKeyChanged,
        };

        /// <summary>
        /// Why the connection or the login failed, in the Mac's kinds (<c>ServerCheck.unreached(_:said:)</c>): a name not
        /// found, a port that refused, no answer in time, a server that closed the connection (or found no common way to
        /// talk) before any login; then a login refused, or a password that the server never asked for.
        /// </summary>
        private RemoteFailure ConnectFailure(Exception e)
        {
            if (HostKeyFailure() is { } hostKey) return hostKey;
            if (cancel.IsCancellationRequested) return stopped();
            var login = password is { Taken: false } ? RemoteFailure.LoginNotOffered : RemoteFailure.LoginRefused;
            if (e is SshAuthenticationException
                || e is SshConnectionException
                {
                    DisconnectReason: DisconnectReason.NoMoreAuthenticationMethodsAvailable or DisconnectReason.IllegalUserName
                        or DisconnectReason.AuthenticationCanceledByUser,
                })
            {
                ways = Named(methods);
                return login;
            }
            if (e is SshOperationTimeoutException or TimeoutException or OperationCanceledException) return RemoteFailure.NoAnswer;
            if (SocketErrorOf(e) is { } error)
                return error switch
                {
                    SocketError.HostNotFound or SocketError.TryAgain
                        or SocketError.NoData or SocketError.NoRecovery => RemoteFailure.NotFound,
                    SocketError.ConnectionRefused => RemoteFailure.Refused,
                    SocketError.ConnectionReset or SocketError.ConnectionAborted
                        or SocketError.Shutdown or SocketError.Disconnecting => RemoteFailure.Closed,
                    _ => RemoteFailure.NoAnswer,
                };
            return e is SshException or IOException ? RemoteFailure.Closed : RemoteFailure.NoAnswer;
        }

        /// <summary>
        /// The ways that the server named with its last refusal of the login (<see cref="RemoteResult.LoginWays"/>), as a
        /// copy: SSH.NET keeps the list of each failure message on the method that it answered, and tries the methods
        /// in their order, each once. A method that the server never answered has none. Null when no method has a
        /// list, or the list is empty: a server that named no way.
        /// </summary>
        internal static IReadOnlyList<string>? Named(IEnumerable<AuthenticationMethod> methods)
        {
            string[]? last = null;
            foreach (var method in methods)
                if (method.AllowedAuthentications is { Length: > 0 } named) last = named;
            return last is null ? null : Array.AsReadOnly((string[])last.Clone());
        }

        /// <summary>The socket's own error under an exception, if one is there.</summary>
        private static SocketError? SocketErrorOf(Exception? e)
        {
            for (var depth = 0; e is not null && depth < 8; depth++, e = e.InnerException)
                if (e is SocketException socket) return socket.SocketErrorCode;
            return null;
        }

        private RemoteFailure RunFailure(Exception e)
        {
            if (HostKeyFailure() is { } hostKey) return hostKey;
            return cancel.IsCancellationRequested ? stopped() : RemoteFailure.Dropped;
        }

        /// <summary>
        /// The text that goes to the server. A call with no input reads an end of file at once, as the Mac's
        /// <c>/dev/null</c> gives <c>ssh</c>; SSH.NET sends the end of an input only after one byte of it. So such a
        /// program goes as one word to <c>/bin/sh</c>, which takes <c>/dev/null</c> as its input and gives the program to
        /// the user's own login shell, as <c>sshd</c> would. The outer words are plain single-quoted words, which a login
        /// shell that is not sh reads alike (the tests run it with zsh and with tcsh).
        /// </summary>
        internal static string Wire(RemoteCall call) =>
            call.Input is { Length: > 0 }
                ? call.Program
                : "/bin/sh -c 'exec \"${SHELL:-/bin/sh}\" -c \"$0\" </dev/null' " + Quote(call.Program);

        /// <summary>One shell word, as the Mac's <c>InstallPlan.quote</c>.</summary>
        internal static string Quote(string value) => "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";

        /// <summary>The input, then the end of the input; a program that ended before it read it all is no fault.</summary>
        private static void Feed(SshCommand command, byte[] input)
        {
            try
            {
                using var stream = command.CreateInputStream();
                stream.Write(input, 0, input.Length);
            }
            catch (Exception e) when (e is SshException or IOException or SocketException or InvalidOperationException
                                          or ObjectDisposedException)
            {
            }
        }

        /// <summary>Ends the connection, then gives what the program printed: each line is given before the call returns.</summary>
        private async Task<RemoteResult> Finish(SshClient client, SshCommand? command, Task[] pumps, int? status,
                                                RemoteFailure? failure)
        {
            if (command is not null) Quietly(command.Dispose);   // the output's pipes end, so the pumps end after what is in them
            Quietly(client.Dispose);
            await Task.WhenAll(pumps).ConfigureAwait(false);
            return Result(failure is null ? status : null, failure);
        }

        private RemoteResult Result(int? status, RemoteFailure? failure) =>
            new(status, printed.Text(Printed.Out), printed.Text(Printed.Err), failure)
            {
                LoginWays = failure is RemoteFailure.LoginRefused or RemoteFailure.LoginNotOffered ? ways : null,
            };

        /// <summary>Clears every secret of the call: the password's bytes and text, the app key's private half, the owner's key.</summary>
        private void Release()
        {
            password?.Clear();
            if (seed is not null) Array.Clear(seed);
            if (key is not null) Array.Clear(key.PrivateKey);
            ownerKey?.Dispose();
            foreach (var method in methods) Quietly(method.Dispose);
        }

        private static async Task Ended(Task task, TimeSpan wait)
        {
            try { await task.WaitAsync(wait).ConfigureAwait(false); }
            catch (TimeoutException) { _ = task.ContinueWith(t => t.Exception, TaskScheduler.Default); }
            catch (Exception) { }
        }
    }

    /// <summary>The algorithms of the Mac's <c>ssh</c>, and the host key type on record first.</summary>
    internal static void Harden(ConnectionInfo info, string? recorded)
    {
        foreach (var name in WeakKeyExchanges) info.KeyExchangeAlgorithms.Remove(name);
        foreach (var name in WeakCiphers) info.Encryptions.Remove(name);
        info.CompressionAlgorithms.Remove("zlib@openssh.com");
        var type = recorded?.Split(' ')[0];
        var first = new List<KeyValuePair<string, Func<byte[], KeyHostAlgorithm>>>();
        var then = new List<KeyValuePair<string, Func<byte[], KeyHostAlgorithm>>>();
        foreach (var pair in info.HostKeyAlgorithms)
        {
            if (pair.Key.EndsWith("-cert-v01@openssh.com", StringComparison.Ordinal) || pair.Key == "ssh-rsa") continue;
            (SignsFor(pair.Key, type) ? first : then).Add(pair);
        }
        info.HostKeyAlgorithms.Clear();
        foreach (var pair in first) info.HostKeyAlgorithms.Add(pair.Key, pair.Value);
        foreach (var pair in then) info.HostKeyAlgorithms.Add(pair.Key, pair.Value);
    }

    /// <summary>Whether a host key algorithm signs with a key of this type (an RSA key signs with SHA-2 only).</summary>
    private static bool SignsFor(string algorithm, string? type) =>
        type is not null && (algorithm == type || (type == "ssh-rsa" && algorithm is "rsa-sha2-512" or "rsa-sha2-256"));

    private static void Quietly(Action action)
    {
        try { action(); } catch (Exception) { }
    }

    /// <summary>
    /// Overwrites a string of the call's own (never one that the runtime shares or interns), as far as .NET lets a
    /// program reach the memory it used: a copy that the garbage collector made when it moved the string stays.
    /// </summary>
    private static void Overwrite(string? text)
    {
        if (text is { Length: > 0 })
            MemoryMarshal.CreateSpan(ref Unsafe.AsRef(in text.GetPinnableReference()), text.Length).Clear();
    }

    /// <summary>The PEM label of PKCS#8's encrypted form, whose reader gives no word of its own for a missing passphrase.</summary>
    private static ReadOnlySpan<byte> EncryptedPkcs8 => "-----BEGIN ENCRYPTED PRIVATE KEY-----"u8;

    /// <summary>
    /// **The owner's key file** (<see cref="OwnerKeyFile.Check"/>, <see cref="RemoteLogin.KeyOnce"/>): what it is, and
    /// the key when it is <see cref="OwnerKeyCheck.Usable"/>, for the caller to dispose. It changes neither array. The
    /// passphrase goes to SSH.NET as a string of its own (SSH.NET takes no other form), which is overwritten when the
    /// read ends. SSH.NET's own copies are not reached: the file's text as a string, its decoded and its decrypted
    /// bytes, the passphrase's UTF-8 bytes or characters inside its key derivation, and an RSA key's numbers. They are
    /// garbage when the read or the call ends and stay in the process's memory until the runtime uses that memory again.
    /// </summary>
    internal static OwnerKeyCheck OpenOwnerKey(byte[]? file, char[]? passphrase, out OwnerKey? key)
    {
        key = null;
        if (file is null || file.Length is 0 or > OwnerKeyFile.MaxLength) return OwnerKeyCheck.NotAKey;
        var pkcs8 = file.AsSpan().IndexOf(EncryptedPkcs8) >= 0;
        try
        {
            key = OwnerKey.Proven(ParseKey(file, null));
            return key is null ? OwnerKeyCheck.NotAKey : OwnerKeyCheck.Usable;
        }
        catch (SshPassPhraseNullOrEmptyException) { }                   // OpenSSH, PEM, PuTTY, ssh.com
        catch (Exception) when (pkcs8) { }                              // PKCS#8: BouncyCastle's own error
        catch (Exception) { return OwnerKeyCheck.NotAKey; }

        // SSH.NET reads the type of an encrypted key only once it has decrypted it, so a key of a type that it does not
        // take (DSA, a security key's) would read as a wrong passphrase for ever. OpenSSH's format and PuTTY's keep
        // the type in clear text, and it says so first.
        if (ClearType(file) is { } type && Array.IndexOf(ReadTypes, type) < 0) return OwnerKeyCheck.NotAKey;

        if (passphrase is not { Length: > 0 }) return OwnerKeyCheck.NeedsPassphrase;
        // PKCS#8's PBES2 derives its key from the passphrase's UTF-8 bytes (OpenSSL and LibreSSL write it so), and
        // BouncyCastle, which reads it for SSH.NET, from one byte of each character. So a passphrase with a letter
        // outside ASCII goes to it once more, as one character for each of its UTF-8 bytes.
        var tries = new List<string>(2) { new(passphrase) };
        if (pkcs8 && Array.Exists(passphrase, c => c > '\x7f')) tries.Add(OneCharacterForEachByte(passphrase));
        var state = OwnerKeyCheck.WrongPassphrase;
        try
        {
            foreach (var text in tries)
            {
                try
                {
                    key = OwnerKey.Proven(ParseKey(file, text));
                    if (key is not null) return OwnerKeyCheck.Usable;
                }
                catch (NotSupportedException) { state = OwnerKeyCheck.NotAKey; }   // a type that SSH.NET does not take
                catch (Exception) { }
            }
            return state;
        }
        finally
        {
            foreach (var text in tries) Overwrite(text);
        }
    }

    /// <summary>The key types that SSH.NET's readers take.</summary>
    private static readonly string[] ReadTypes =
        ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa"];

    /// <summary>
    /// The key's type where its file keeps it in clear text before the encrypted part: PuTTY's first line, and the first
    /// public key of OpenSSH's own format. Null for another format, or a file that does not read so. Called for an
    /// encrypted file only, so what it decodes is the public key and the encrypted part.
    /// </summary>
    private static string? ClearType(byte[] file)
    {
        var bytes = file.AsSpan();
        try
        {
            if (bytes.StartsWith("PuTTY-User-Key-File-"u8))
            {
                var line = bytes[..Math.Max(0, bytes.IndexOfAny((byte)'\r', (byte)'\n'))];
                var colon = line.IndexOf(": "u8);
                return colon < 0 ? null : Encoding.ASCII.GetString(line[(colon + 2)..]);
            }
            var begin = bytes.IndexOf(OpenSshBegin);
            var end = bytes.IndexOf("-----END OPENSSH PRIVATE KEY-----"u8);
            if (begin < 0 || end < begin) return null;
            var blob = Convert.FromBase64String(Encoding.ASCII.GetString(bytes[(begin + OpenSshBegin.Length)..end]));
            var magic = "openssh-key-v1\0"u8;
            if (!blob.AsSpan().StartsWith(magic)) return null;
            var at = magic.Length;
            for (var field = 0; field < 3; field++)          // the cipher, the key derivation and its options
                at += 4 + (int)BinaryPrimitives.ReadUInt32BigEndian(blob.AsSpan(at));
            at += 4 + 4;                                     // the number of keys; the length of the first public key
            var length = (int)BinaryPrimitives.ReadUInt32BigEndian(blob.AsSpan(at));
            return length is < 1 or > 64 ? null : Encoding.ASCII.GetString(blob, at + 4, length);
        }
        catch (Exception) { return null; }
    }

    private static ReadOnlySpan<byte> OpenSshBegin => "-----BEGIN OPENSSH PRIVATE KEY-----"u8;

    /// <summary>The passphrase's UTF-8 bytes, each as the character of the same number.</summary>
    private static string OneCharacterForEachByte(char[] passphrase)
    {
        var bytes = Encoding.UTF8.GetBytes(passphrase);
        try
        {
            return string.Create(bytes.Length, bytes, static (chars, b) =>
            {
                for (var i = 0; i < b.Length; i++) chars[i] = (char)b[i];
            });
        }
        finally { Array.Clear(bytes); }
    }

    private static PrivateKeyFile ParseKey(byte[] file, string? passphrase)
    {
        using var stream = new MemoryStream(file, writable: false);
        return new PrivateKeyFile(stream, passphrase);
    }

    /// <summary>
    /// The owner's key as the login offers it: the ways of signing of the Mac's <c>ssh</c> (OpenSSH 10), so an RSA key
    /// signs with SHA-2 only (<c>rsa-sha2-512</c>, then <c>rsa-sha2-256</c>) and never with SHA-1 (<c>ssh-rsa</c>).
    /// </summary>
    internal sealed class OwnerKey : IPrivateKeySource, IDisposable
    {
        private readonly PrivateKeyFile file;
        private readonly List<HostAlgorithm> algorithms;
        private int disposed;

        private OwnerKey(PrivateKeyFile file, List<HostAlgorithm> algorithms)
        {
            this.file = file;
            this.algorithms = algorithms;
        }

        public IReadOnlyCollection<HostAlgorithm> HostKeyAlgorithms => algorithms;

        /// <summary>The key once it has signed and its own signature checks; else null, and the file is disposed.</summary>
        internal static OwnerKey? Proven(PrivateKeyFile file)
        {
            try
            {
                var algorithms = new List<HostAlgorithm>();
                foreach (var algorithm in file.HostKeyAlgorithms)
                    if (algorithm.Name != "ssh-rsa") algorithms.Add(algorithm);
                if (algorithms.Count > 0)
                {
                    var data = RandomNumberGenerator.GetBytes(32);
                    if (algorithms[0].VerifySignature(data, algorithms[0].Sign(data))) return new OwnerKey(file, algorithms);
                }
            }
            catch (Exception) { }
            Clear(file);
            return null;
        }

        /// <summary>Overwrites the private parts that SSH.NET keeps as arrays, and lets the system's key objects go.</summary>
        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) == 0) Clear(file);
        }

        private static void Clear(PrivateKeyFile file)
        {
            switch (file.Key)
            {
                case ED25519Key ed25519: Array.Clear(ed25519.PrivateKey); break;
                case EcdsaKey { PrivateKey: { } d }: Array.Clear(d); break;
            }
            Quietly(file.Dispose);
        }
    }

    /// <summary>A password that the call sends once at most, by whichever method the server asks for first.</summary>
    private sealed class Once(byte[] bytes)
    {
        private int taken;
        private string? text;

        public byte[] Bytes => bytes;

        /// <summary>Whether the password went already.</summary>
        public bool Taken => Volatile.Read(ref taken) != 0;

        /// <summary>True for the first asker only.</summary>
        public bool Take() => Interlocked.Exchange(ref taken, 1) == 0;

        /// <summary>
        /// The password as text, for a keyboard-interactive answer (SSH.NET takes a string there): a string of its own,
        /// never one that the runtime shares, because <see cref="Clear"/> overwrites it.
        /// </summary>
        public string Text() =>
            text = string.Create(Encoding.UTF8.GetCharCount(bytes), bytes, static (chars, b) => Encoding.UTF8.GetChars(b, chars));

        /// <summary>Overwrites the bytes and the text, as far as .NET lets a program reach the memory it used.</summary>
        public void Clear()
        {
            Array.Clear(bytes);
            Overwrite(text);
        }
    }

    /// <summary>The password method, which sends nothing when the password went already.</summary>
    private sealed class OncePassword(string user, Once once) : PasswordAuthenticationMethod(user, once.Bytes)
    {
        public override AuthenticationResult Authenticate(Session session) =>
            once.Take() ? base.Authenticate(session) : AuthenticationResult.Failure;
    }

    /// <summary>
    /// Keyboard-interactive (PAM's prompt), which the Mac's <c>ssh</c> asks first: the first prompt that does not echo
    /// gets the password, if it did not go already; every other prompt gets nothing. Not started when it went already.
    /// </summary>
    private sealed class OnceKeyboardInteractive : KeyboardInteractiveAuthenticationMethod
    {
        private readonly Once once;

        public OnceKeyboardInteractive(string user, Once once) : base(user)
        {
            this.once = once;
            AuthenticationPrompt += Answer;
        }

        public override AuthenticationResult Authenticate(Session session) =>
            once.Taken ? AuthenticationResult.Failure : base.Authenticate(session);

        private void Answer(object? sender, AuthenticationPromptEventArgs e)
        {
            foreach (var prompt in e.Prompts)
                prompt.Response = !prompt.IsEchoed && once.Take() ? once.Text() : "";
        }
    }

    /// <summary>What a program printed: the first 1 MiB of each stream, and its lines to the caller as they come.</summary>
    private sealed class Printed(Action<string>? line)
    {
        public const int Out = 0, Err = 1;
        private readonly MemoryStream[] kept = [new(), new()];
        private readonly object lines = new();

        public Task Pump(Stream source, int which) =>
            Task.Factory.StartNew(() => Read(source, which), CancellationToken.None, TaskCreationOptions.LongRunning,
                                  TaskScheduler.Default);

        public string Text(int which)
        {
            lock (kept[which])
            {
                return Encoding.UTF8.GetString(kept[which].GetBuffer(), 0, (int)kept[which].Length);
            }
        }

        private void Read(Stream source, int which)
        {
            var buffer = new byte[65536];
            var pending = new MemoryStream();
            int count;
            while ((count = source.Read(buffer, 0, buffer.Length)) > 0)
            {
                lock (kept[which])
                {
                    var room = OutputLimit - (int)kept[which].Length;
                    if (room > 0) kept[which].Write(buffer, 0, Math.Min(room, count));
                }
                if (line is null) continue;
                var start = 0;
                for (var at = 0; at < count; at++)
                {
                    if (buffer[at] != (byte)'\n') continue;
                    pending.Write(buffer, start, at - start);
                    Give(pending);
                    start = at + 1;
                }
                pending.Write(buffer, start, count - start);
                while (pending.Length >= LineLimit) Give(pending, LineLimit);
            }
            if (line is not null && pending.Length > 0) Give(pending);
        }

        /// <summary>Gives the caller the pending bytes (or their first <c>take</c>) as one line, without a carriage return at its end.</summary>
        private void Give(MemoryStream pending, int take = -1)
        {
            var all = pending.GetBuffer();
            var length = take < 0 ? (int)pending.Length : take;
            var end = length > 0 && all[length - 1] == (byte)'\r' && take < 0 ? length - 1 : length;
            var text = Encoding.UTF8.GetString(all, 0, end);
            var rest = (int)pending.Length - length;
            Buffer.BlockCopy(all, length, all, 0, rest);
            pending.SetLength(rest);
            lock (lines) line!(text);
        }
    }
}
