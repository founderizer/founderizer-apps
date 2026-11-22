using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Remote;
using Founderizer.Setup.Install;

namespace Founderizer.Setup.Tests;

/// <summary>A server that answers each call with what the test says, and keeps each call and a copy of its input (the
/// installer clears its own copy of an input that holds a password after the call).</summary>
internal sealed class StandInRemote(Func<RemoteCall, byte[]?, RemoteResult> answer) : IRemote
{
    public List<RemoteCall> Calls { get; } = [];
    public List<byte[]?> Inputs { get; } = [];

    /// <summary>Each call that a model asked for, also one that the client's refusals below then refused: <see
    /// cref="Calls"/> holds only the calls that reached the server.</summary>
    public int Tries => tries;
    private int tries;

    /// <summary>Whether the app's own key is in the box: a call with it while it is not throws, as SshRemote's does.
    /// Null: the stand-in asks no box.</summary>
    public Func<bool>? HoldsAppKey { get; set; }

    /// <summary>The real client's two refusals come first (RemoteRules.Check, and the app's key that is not there), so a
    /// model that makes such a call fails here as it fails on a PC.</summary>
    public Task<RemoteResult> RunAsync(RemoteCall call, Action<string>? line, CancellationToken cancel)
    {
        Interlocked.Increment(ref tries);
        RemoteRules.Check(call);
        if (call.Login is RemoteLogin.AppKey && HoldsAppKey?.Invoke() == false)
            throw new InvalidOperationException("The app has no SSH key yet: make it with AppSshKey.Make and keep it in the secret box first.");
        var input = call.Input?.ToArray();
        Calls.Add(call);
        Inputs.Add(input);
        var result = answer(call, input);
        if (line is not null)
            foreach (var each in (result.Output + "\n" + result.Errors).Split('\n').Where(l => l.Length > 0)) line(each);
        return Task.FromResult(result);
    }

    public ValueTask DisposeAsync() => default;

    public static RemoteResult Said(string output, int status = 0) => new(status, output, "", null);

    public static RemoteResult Failed(RemoteFailure failure) => new(null, "", "", failure);
}

/// <summary>A clock whose waits pass at once and move its time on.</summary>
internal sealed class StandInClock : InstallerClock
{
    private DateTimeOffset now = new(2026, 11, 20, 12, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset Now => now;

    public override Task DelayAsync(TimeSpan time, CancellationToken cancel)
    {
        cancel.ThrowIfCancellationRequested();
        now += time;
        return Task.CompletedTask;
    }
}

/// <summary>What a server prints, for the stand-ins.</summary>
internal static class Printed
{
    public const string PrivateAddress = "100.64.0.9";

    /// <summary>The check's lines of a server that can take either install, as the script prints them, with
    /// <paramref name="changes"/> in place of the keys they name.</summary>
    public static string Ready(params string[] changes)
    {
        string[] ready = ["user=root", "uid=0", "sudo=root", "os_id=ubuntu", "os_version=24.04", "os_name=Ubuntu", "arch=x86_64",
                          "memory_mb=3911", "disk_free_mb=70000", "systemd=yes", "ipv4_route=yes", "reach=github.com yes",
                          "reach=tailscale.com yes", "reach=claude.ai yes", "reach=chatgpt.com yes", "cloud_init=done",
                          "dpkg_lock=no", "listen=tcp/22/sshd", "listen=tcp/443/caddy", "ufw=inactive", "tailscale=none", "end=yes"];
        var keys = changes.Select(c => c.Split('=')[0]).ToHashSet();
        return string.Join("\n", ready.Where(l => !keys.Contains(l.Split('=')[0])).Concat(changes));
    }

    public static string ClaimLog(string address, string code = "ABCD-EFGH-JKLM") =>
        $"Founderizer step 12: the owner claim\nFLEET_CLAIM={code} sh -c \"$(curl -fsS http://{address}:8765/claim)\"";

    public const string Checklist = "[{\"check\": \"services\", \"state\": \"ok\", \"says\": \"Running.\"}]";
}
