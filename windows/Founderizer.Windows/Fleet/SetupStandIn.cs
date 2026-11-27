#if PROOFS
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;
using Founderizer.Setup.Agents;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;

namespace Founderizer.Windows.Fleet;

/// <summary>**For the proofs in the build VM only** (app/windows/vm/README.md, "The manager's setup against a stand-in"):
/// with FOUNDERIZER_SETUP_READINGS set to a folder, the manager's first setup reads that folder in place of the hub's owner
/// routes, at each of its reads: <c>servers.json</c> (GET /ui/servers), <c>machines.json</c> (GET /ui/machines) and
/// <c>fleet.json</c> (the manager's row of the hub's reading: <c>runtime</c>, <c>alive</c>, <c>title</c>, and the mark's
/// <c>provider</c> and <c>joined</c>). A proof writes each state as files from the Mac. Each write of the setup goes to
/// <c>writes.log</c> of the folder by its route only, never its body, so no code is in a file. With
/// FOUNDERIZER_SETUP_SAMPLE (<c>checks</c> or <c>approve</c>), the first run's page shows that state of the hub's install,
/// which the stand-ins of U2 cannot reach (the claim of a hub). A build without the proofs' switch has no such class.</summary>
internal sealed class SetupStandIn : OwnerReads.ICalls
{
    private readonly string folder;

    private SetupStandIn(string folder) => this.folder = folder;

    public static SetupStandIn? Create() =>
        Proofs.Variable("FOUNDERIZER_SETUP_READINGS") is { Length: > 0 } folder && Directory.Exists(folder) ? new SetupStandIn(folder) : null;

    public string? Database => "db-1";

    /// <summary>The stand-in's hub, as the mark names it: an address for documents of the VM's way to the Mac.</summary>
    public static readonly Uri Hub = new("http://10.0.2.2:58440/");

    private JsonElement Row()
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(folder, "fleet.json")));
            return document.RootElement.Clone();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return default; }
    }

    private static string? Text(JsonElement row, string name) =>
        row.ValueKind == JsonValueKind.Object && row.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    /// <summary>The mark of the manager's first setup that a hand-over would have kept.</summary>
    public ManagerSetupMark Mark()
    {
        var row = Row();
        return new ManagerSetupMark(Hub, "db-1", "juno", Text(row, "provider") is { Length: > 0 } p ? p : null,
                                    Text(row, "joined") is { Length: > 0 } j ? j : null);
    }

    /// <summary>The hub's reading as the owner's store would hold it: the manager alone, with the setup's features.</summary>
    public MobileSnapshot Fleet()
    {
        var row = Row();
        return new MobileSnapshot(1, "db-1", DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            [new MobileAgent("juno", "manager", Text(row, "runtime") ?? "claude", 0, [], Title: Text(row, "title") ?? "Fleet Manager", Active: true,
                             Alive: Text(row, "alive") ?? "")],
            [], [], [], [], [], UiFeatures: Features(row) ?? ["servers", "machines", "machine_signin", "agent_setup", "manager_server"]);
    }

    /// <summary>The hub's features that <c>fleet.json</c> names (<c>features</c>), for a state that needs others (the
    /// name's page of piece U3b needs the fleet's shape and the manager's rename); null for the setup's own.</summary>
    private static IReadOnlyList<string>? Features(JsonElement row)
    {
        if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("features", out var list) || list.ValueKind != JsonValueKind.Array)
            return null;
        var names = new List<string>();
        foreach (var name in list.EnumerateArray())
            if (name.ValueKind == JsonValueKind.String) names.Add(name.GetString()!);
        return names;
    }

    public Task<OwnerAnswer<T>> GetAsync<T>(string route, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type, int limit,
                                            CancellationToken cancel) where T : class
    {
        var name = route switch
        {
            "ui/servers" => "servers.json",
            "ui/machines" => "machines.json",
            "ui/team" => "team.json",
            _ => throw HubException.NoAnswer(),
        };
        try { return Task.FromResult(new OwnerAnswer<T>(JsonSerializer.Deserialize(File.ReadAllBytes(Path.Combine(folder, name)), type))); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw HubException.NoAnswer(e); }
    }

    public Task<OwnerAnswer<TAnswer>> PostAsync<TBody, TAnswer>(string route, TBody body,
        System.Text.Json.Serialization.Metadata.JsonTypeInfo<TBody> bodyType,
        System.Text.Json.Serialization.Metadata.JsonTypeInfo<TAnswer> answerType, Guid? requestId, CancellationToken cancel) where TAnswer : class
    {
        try { File.AppendAllText(Path.Combine(folder, "writes.log"), DateTimeOffset.UtcNow.ToString("O") + " " + route + Environment.NewLine); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        var id = (requestId ?? Guid.NewGuid()).ToString("D");
        var json = body switch
        {
            MoveAsk move => $"{{\"ok\": true, \"request_id\": \"{id}\", \"agent\": \"juno\", \"server\": \"{move.Server}\", \"runtime\": \"{move.Runtime}\", \"job\": 7, " +
                            $"\"revision\": \"{new string('a', 40)}\", \"sha256\": \"{new string('c', 64)}\"}}",
            // The rename of a manager with no server (piece U3b): the hub's receipt, with no job and no server.
            RenameAsk rename => $"{{\"ok\": true, \"request_id\": \"{id}\", \"agent\": \"{rename.Name}\", \"was\": \"juno\", \"server\": null, " +
                                $"\"job\": null, \"revision\": \"{new string('a', 40)}\", \"sha256\": \"{new string('d', 64)}\"}}",
            _ => $"{{\"ok\": true, \"request_id\": \"{id}\"}}",
        };
        return Task.FromResult(new OwnerAnswer<TAnswer>(JsonSerializer.Deserialize(json, answerType)));
    }

    /// <summary>**A state of the hub's install that the first run's page shows in place of the store's own**, for
    /// FOUNDERIZER_SETUP_SAMPLE: <c>checks</c> (the install ended with a check that did not pass, and the hub answers this
    /// PC: "Open Founderizer"), <c>approve</c> (the hub's install ended well, and the join of the manager's own server waits
    /// for the owner's yes at Tailscale). Null with none.</summary>
    public static SetupState? Sample()
    {
        var now = DateTimeOffset.UtcNow;
        IReadOnlyList<InstallProgress> done =
        [
            new("read", "Read the server", "", ProgressState.Done), new("network", "The private network", "", ProgressState.Done),
            new("claim", "Claim the hub", "", ProgressState.Done), new("verify", "Check the server", "", ProgressState.Done),
        ];
        var failed = VerifyChecklist.Read("[{\"check\": \"services\", \"state\": \"ok\", \"says\": \"The hub's services run.\"}, " +
                                          "{\"check\": \"tailnet\", \"state\": \"fail\", \"says\": \"The server is not on your private network.\", " +
                                          "\"fix\": \"Start Tailscale on the server.\"}]");
        var passed = VerifyChecklist.Read("[{\"check\": \"services\", \"state\": \"ok\", \"says\": \"The hub's services run.\"}]");
        return Proofs.Variable("FOUNDERIZER_SETUP_SAMPLE") switch
        {
            "checks" => new SetupState
            {
                Page = SetupPage.Installing, Shaped = true, Named = true, ManagerName = "Juno", HubAnswers = true,
                Install = new InstallView(false, done, [], now, null, failed, Hub.ToString(), false),
            },
            "approve" => new SetupState
            {
                Page = SetupPage.Installing, Shaped = true, Named = true, ManagerName = "Juno", HubAnswers = true,
                Install = new InstallView(false, done, [], now, null, passed, Hub.ToString(), false),
                ManagerInstall = new InstallView(true,
                    [new("read", "Read the server", "", ProgressState.Done),
                     new("network", "The private network", "", ProgressState.Running,
                         ["fleet-machine-name=worker-2", "To authenticate, visit:", "https://login.tailscale.com/a/0a1b2c3d4e5f"])],
                    ["read", "network", "join", "verify"], now, null, null, null, false, "worker-2", Hub.ToString()),
            },
            _ => null,
        };
    }
}
#endif
