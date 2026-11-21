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

/// <summary>The committed vector files of app/vectors, copied beside the tests.</summary>
internal static class Vectors
{
    public static JsonElement Read(string name)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "vectors", name)));
        return document.RootElement.Clone();
    }

    public static string? Text(this JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetString();

    public static string? Text(this JsonElement value, string name) => value.GetProperty(name).Text();

    public static List<string> Texts(this JsonElement value) => value.EnumerateArray().Select(v => v.GetString()!).ToList();

    /// <summary>**A sentence of the Mac with the PC's word** (windows-app-plan-v2.md, rule 14): where it says "Mac" for
    /// the owner's computer, the PC says "PC".</summary>
    public static string Pc(string mac) =>
        mac.Replace("This Mac's", "This PC's", StringComparison.Ordinal).Replace("this Mac's", "this PC's", StringComparison.Ordinal)
           .Replace("This Mac", "This PC", StringComparison.Ordinal).Replace("this Mac", "this PC", StringComparison.Ordinal);
}

/// <summary>A server that answers each call with what the test says, and keeps each call and a copy of its input (the
/// installer clears its own copy of an input that holds a password after the call).</summary>
internal sealed class StandInRemote(Func<RemoteCall, byte[]?, RemoteResult> answer) : IRemote
{
    public List<RemoteCall> Calls { get; } = [];
    public List<byte[]?> Inputs { get; } = [];

    public Task<RemoteResult> RunAsync(RemoteCall call, Action<string>? line, CancellationToken cancel)
    {
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
