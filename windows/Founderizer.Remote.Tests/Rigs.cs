using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

[assembly: DoNotParallelize]

namespace Founderizer.Remote.Tests;

/// <summary>One program of this machine (ssh-keygen, sshd, docker), with its input on standard input and never in an argument.</summary>
internal static class Local
{
    public static (int Status, string Output) Run(string program, IEnumerable<string> arguments, string? input = null,
                                                   int seconds = 120)
    {
        var start = new ProcessStartInfo(program)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        if (input is not null) process.StandardInput.Write(input);
        process.StandardInput.Close();
        if (!process.WaitForExit(seconds * 1000))
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException($"{program} did not end in {seconds} s.");
        }
        return (process.ExitCode, output.Result + errors.Result);
    }

    public static string Must(string program, IEnumerable<string> arguments, string? input = null, int seconds = 120)
    {
        var (status, output) = Run(program, arguments, input, seconds);
        if (status != 0) throw new InvalidOperationException($"{program} {string.Join(' ', arguments)} answered {status}: {output}");
        return output;
    }

    public static string Folder(string name)
    {
        var folder = Path.Combine(Path.GetTempPath(), name + "-" + Guid.NewGuid().ToString("N")[..12]);
        Directory.CreateDirectory(folder);
        return folder;
    }

    public static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}

/// <summary>
/// The app's side of a test: its own folder (where <c>known-hosts.json</c> goes), its own key, and an SshRemote with
/// them. The folder goes with it.
/// </summary>
internal sealed class App : IAsyncDisposable
{
    public string Folder { get; } = Local.Folder("founderizer-remote-app");
    public AppSshKey.Made Key { get; } = AppSshKey.Make();
    public HostKeys HostKeys { get; }
    public SshRemote Remote { get; }
    public int KeyReads;

    public App(AppSshKey.Made? key = null)
    {
        if (key is { } given) Key = given;
        HostKeys = new HostKeys(Folder);
        Remote = new SshRemote(HostKeys, () => { Interlocked.Increment(ref KeyReads); return (byte[])Key.PrivateKey.Clone(); });
    }

    /// <summary>One call, with a bound on its time so that a hang fails the test instead of the run.</summary>
    public async Task<(RemoteResult Result, List<string> Lines)> Run(RemoteTarget target, string program, byte[]? input = null,
        HostKeyRule rule = HostKeyRule.TakeNew, RemoteLogin? login = null, TimeSpan? connect = null,
        CancellationToken cancel = default, Action<string>? also = null, int seconds = 60, TimeSpan? limit = null)
    {
        var lines = new List<string>();
        var call = new RemoteCall(target, program, input, login ?? new RemoteLogin.AppKey(), rule,
                                  connect ?? RemoteCall.ConnectTimeout) { Limit = limit ?? RemoteCall.DefaultLimit };
        var result = await Remote.RunAsync(call, text => { lock (lines) lines.Add(text); also?.Invoke(text); }, cancel)
            .WaitAsync(TimeSpan.FromSeconds(seconds));
        lock (lines) return (result, [.. lines]);
    }

    public async ValueTask DisposeAsync()
    {
        await Remote.DisposeAsync();
        Directory.Delete(Folder, recursive: true);
    }
}

/// <summary>
/// **A scratch sshd**: this machine's own OpenSSH server, started as this user on a loopback port with its own host key,
/// its own <c>authorized_keys</c> and its own log, and stopped with its folder when the test ends. Without root it
/// takes keys only, and runs each program as this user with this user's shell.
/// </summary>
internal sealed class ScratchSshd : IDisposable
{
    private const string Sshd = "/usr/sbin/sshd", Keygen = "/usr/bin/ssh-keygen";
    private readonly string extra;
    private Process? process;
    private int hostKeys;

    public string Folder { get; } = Local.Folder("founderizer-scratch-sshd");
    public int Port { get; private set; }
    public string User { get; } = Environment.UserName;
    public string HostKeyLine { get; private set; } = "";
    public string LogPath => Path.Combine(Folder, "sshd.log");
    public RemoteTarget Target => new("127.0.0.1", Port, User);

    /// <summary>Whether this machine has an OpenSSH server and ssh-keygen (not on Windows, where proof A runs it).</summary>
    public static void RequireOrSkip()
    {
        if (OperatingSystem.IsWindows() || !File.Exists(Sshd) || !File.Exists(Keygen))
            Assert.Inconclusive("This machine has no OpenSSH server for a scratch sshd.");
    }

    /// <summary>Starts it with these public lines in its authorized_keys, a host key of this type, and more lines of configuration.</summary>
    public ScratchSshd(IEnumerable<string> authorized, string hostKeyType = "ed25519", string extra = "")
    {
        RequireOrSkip();
        this.extra = extra;
        File.WriteAllText(Path.Combine(Folder, "authorized_keys"), string.Concat(authorized.Select(l => l + "\n")));
        Port = Local.FreePort();
        Start(hostKeyType);
    }

    /// <summary>Stops it, and starts it again on the same port with a new host key of this type and nothing else.</summary>
    public void Restart(string hostKeyType)
    {
        Stop();
        Start(hostKeyType);
    }

    /// <summary>The log's text from this offset on.</summary>
    public string Log(long from = 0)
    {
        using var file = new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        file.Position = Math.Min(from, file.Length);
        return new StreamReader(file).ReadToEnd();
    }

    public long LogLength => File.Exists(LogPath) ? new FileInfo(LogPath).Length : 0;

    private void Start(string hostKeyType)
    {
        var key = Path.Combine(Folder, $"host_{++hostKeys}_{hostKeyType}");
        Local.Must(Keygen, ["-q", "-t", hostKeyType, "-N", "", "-C", "scratch-host", "-f", key]);
        var parts = File.ReadAllText(key + ".pub").Trim().Split(' ');
        HostKeyLine = parts[0] + " " + parts[1];
        var config = Path.Combine(Folder, "sshd_config");
        File.WriteAllText(config, string.Join('\n',
            $"ListenAddress 127.0.0.1:{Port}",
            $"HostKey {key}",
            $"PidFile {Path.Combine(Folder, "sshd.pid")}",
            $"AuthorizedKeysFile {Path.Combine(Folder, "authorized_keys")}",
            "UsePAM no",
            "StrictModes no",
            "PasswordAuthentication no",
            "KbdInteractiveAuthentication no",
            "UseDNS no",
            "LogLevel VERBOSE",
            extra,
            ""));
        var start = new ProcessStartInfo(Sshd) { UseShellExecute = false, RedirectStandardInput = true };
        foreach (var argument in new[] { "-D", "-E", LogPath, "-f", config }) start.ArgumentList.Add(argument);
        process = Process.Start(start)!;
        var until = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < until)
        {
            if (process.HasExited) throw new InvalidOperationException("The scratch sshd ended: " + Log());
            try
            {
                using var probe = new TcpClient();
                probe.Connect(IPAddress.Loopback, Port);
                return;
            }
            catch (SocketException) { Thread.Sleep(50); }
        }
        throw new TimeoutException("The scratch sshd did not listen in 10 s.");
    }

    private void Stop()
    {
        if (process is null) return;
        if (!process.HasExited) process.Kill(entireProcessTree: true);
        process.WaitForExit(10_000);
        process.Dispose();
        process = null;
    }

    public void Dispose()
    {
        Stop();
        try { Directory.Delete(Folder, recursive: true); } catch (IOException) { }
    }
}

/// <summary>A relay on a loopback port to another one, whose connections a test can cut, as a network that went away.</summary>
internal sealed class Relay : IDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly int to;
    private readonly List<TcpClient> open = [];

    public Relay(int to)
    {
        this.to = to;
        listener.Start();
        _ = Task.Run(Serve);
    }

    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;

    /// <summary>Ends every connection at once.</summary>
    public void Cut()
    {
        lock (open)
        {
            foreach (var client in open)
            {
                client.Client.LingerState = new LingerOption(true, 0);
                client.Dispose();
            }
            open.Clear();
        }
    }

    private async Task Serve()
    {
        while (true)
        {
            TcpClient inner;
            try { inner = await listener.AcceptTcpClientAsync(); } catch (Exception) { return; }
            var outer = new TcpClient();
            await outer.ConnectAsync(IPAddress.Loopback, to);
            lock (open) open.AddRange([inner, outer]);
            _ = Pump(inner, outer);
            _ = Pump(outer, inner);
        }
    }

    private static async Task Pump(TcpClient from, TcpClient to)
    {
        try { await from.GetStream().CopyToAsync(to.GetStream()); } catch (Exception) { }
    }

    public void Dispose()
    {
        listener.Stop();
        Cut();
    }
}

/// <summary>A server that takes a connection and never says a word.</summary>
internal sealed class Silent : IDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly List<TcpClient> held = [];

    public Silent()
    {
        listener.Start();
        _ = Task.Run(async () =>
        {
            while (true)
            {
                try { var client = await listener.AcceptTcpClientAsync(); lock (held) held.Add(client); }
                catch (Exception) { return; }
            }
        });
    }

    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;

    public void Dispose()
    {
        listener.Stop();
        lock (held) foreach (var client in held) client.Dispose();
    }
}

/// <summary>A server that takes a connection and closes it at once, before any word.</summary>
internal sealed class Closing : IDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);

    public Closing()
    {
        listener.Start();
        _ = Task.Run(async () =>
        {
            while (true)
            {
                try { using var client = await listener.AcceptTcpClientAsync(); }
                catch (Exception) { return; }
            }
        });
    }

    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;

    public void Dispose() => listener.Stop();
}

/// <summary>
/// **An sshd in a Docker container on this machine** (Ubuntu 24.04, OpenSSH with PAM), for what a scratch sshd without
/// root cannot do: a password, <c>sudo</c> that asks for it, and a user whose login shell is not sh. The user
/// <c>founder</c> (bash) gets the test's password through <c>chpasswd</c>'s standard input, never an argument; the user
/// <c>tcshuser</c> has tcsh as its login shell; both take the app's key. Port 22 takes keyboard-interactive and password,
/// as a VPS does; port 2222 takes the password method alone. The container goes when the test ends; the image stays,
/// as a cache, under the name below (about 160 MB).
/// </summary>
internal sealed class ContainerSshd : IDisposable
{
    public const string Image = "founderizer-remote-test-sshd:2";
    public const string User = "founder";
    public const string TcshUser = "tcshuser";
    private const string Docker = "/usr/local/bin/docker";

    private const string Dockerfile = """
        FROM ubuntu:24.04
        RUN apt-get update \
         && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server sudo tcsh \
         && rm -rf /var/lib/apt/lists/* \
         && mkdir -p /run/sshd \
         && useradd -m -s /bin/bash founder && useradd -m -s /usr/bin/tcsh tcshuser \
         && printf 'founder ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/founder && chmod 440 /etc/sudoers.d/founder \
         && printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication yes\nUsePAM yes\nPermitRootLogin no\nLogLevel VERBOSE\n' > /etc/ssh/sshd_config.d/10-test.conf \
         && ssh-keygen -A
        CMD ["/bin/sh", "-c", "/usr/sbin/sshd -E /tmp/sshd-2222.log -p 2222 -o KbdInteractiveAuthentication=no && exec /usr/sbin/sshd -D -e"]
        """;

    public string Name { get; } = "founderizer-remote-test-" + Guid.NewGuid().ToString("N")[..10];
    public int Port { get; }
    public int PasswordOnlyPort { get; }

    public static void RequireOrSkip()
    {
        if (!File.Exists(Docker) || Local.Run(Docker, ["info", "--format", "{{.ServerVersion}}"], seconds: 30).Status != 0)
            Assert.Inconclusive("This machine has no Docker that runs.");
    }

    public ContainerSshd(string password, string authorizedLine)
    {
        RequireOrSkip();
        if (Local.Run(Docker, ["image", "inspect", Image]).Status != 0)
            Local.Must(Docker, ["build", "-t", Image, "-"], Dockerfile, seconds: 600);
        Local.Must(Docker, ["run", "-d", "--name", Name, "-p", "127.0.0.1::22", "-p", "127.0.0.1::2222", Image]);
        try
        {
            Port = Published(22);
            PasswordOnlyPort = Published(2222);
            Local.Must(Docker, ["exec", "-i", Name, "chpasswd"], $"{User}:{password}\n");
            foreach (var user in new[] { User, TcshUser })
                Local.Must(Docker, ["exec", "-i", Name, "sh", "-c",
                    $"install -d -m 700 -o {user} -g {user} /home/{user}/.ssh && cat > /home/{user}/.ssh/authorized_keys "
                    + $"&& chown {user}:{user} /home/{user}/.ssh/authorized_keys && chmod 600 /home/{user}/.ssh/authorized_keys"],
                    authorizedLine + "\n");
            Ready(Port);
            Ready(PasswordOnlyPort);
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    public RemoteTarget Target => new("127.0.0.1", Port, User);
    public RemoteTarget PasswordOnly => new("127.0.0.1", PasswordOnlyPort, User);
    public RemoteTarget Tcsh => new("127.0.0.1", Port, TcshUser);

    /// <summary>What the sshd of port 22 logged.</summary>
    public string Log() => Local.Run(Docker, ["logs", Name]).Output;

    private int Published(int port)
    {
        var line = Local.Must(Docker, ["port", Name, $"{port}/tcp"]).Split('\n')[0].Trim();
        return int.Parse(line[(line.LastIndexOf(':') + 1)..], System.Globalization.CultureInfo.InvariantCulture);
    }

    /// <summary>Waits until the server behind Docker's forwarder says its greeting.</summary>
    private static void Ready(int port)
    {
        var until = DateTime.UtcNow.AddSeconds(30);
        while (DateTime.UtcNow < until)
        {
            try
            {
                using var probe = new TcpClient();
                probe.Connect(IPAddress.Loopback, port);
                probe.ReceiveTimeout = 2000;
                var buffer = new byte[64];
                var count = probe.GetStream().Read(buffer, 0, buffer.Length);
                if (count > 0 && Encoding.ASCII.GetString(buffer, 0, count).StartsWith("SSH-2.0", StringComparison.Ordinal)) return;
            }
            catch (Exception e) when (e is SocketException or IOException) { }
            Thread.Sleep(200);
        }
        throw new TimeoutException("The container's sshd did not answer in 30 s.");
    }

    public void Dispose() => Local.Run(Docker, ["rm", "-f", Name], seconds: 60);
}
