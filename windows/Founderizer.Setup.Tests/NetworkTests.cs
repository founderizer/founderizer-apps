using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.Network;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>What the PC's network and cloud code must hold beside the Mac's vectors (windows-app-plan-v2.md, piece L2):
/// a secret never kept where it does not belong and never in a word; a policy file that another tool keeps never
/// written; Tailscale's own installer for this kind of PC and no other file; the wait for a new server.</summary>
[TestClass]
public sealed class NetworkTests
{
    private const string Token = "tskey-api-kEXAMPLE1CNTRL-notarealsecretvalue0000";
    private const string Secret = "tskey-client-kFLEET1234CNTRL-notarealsecret";
    private const string Access = "notarealaccesstoken-0123456789abcdef";
    private const string CloudToken = "notarealtoken0123456789notarealtoken0123456789notarealtoken0123";

    /// <summary>A box that keeps every value written to it, under every name.</summary>
    private sealed class WatchedBox : ISecretBox
    {
        private readonly MemorySecretBox inner = new();
        public List<(string Name, byte[] Value)> Written { get; } = [];
        public byte[]? Read(string name) => inner.Read(name);
        public void Write(string name, byte[] value) { Written.Add((name, (byte[])value.Clone())); inner.Write(name, value); }
        public void Remove(string name) => inner.Remove(name);
    }

    private static StandIn Tailnet(string policy, bool managed, int settingsStatus = 200)
    {
        var stand = new StandIn();
        stand.Add("GET", "/api/v2/tailnet/-/settings", settingsStatus,
                  settingsStatus == 200 ? $"{{\"aclsExternallyManagedOn\":{(managed ? "true" : "false")}}}" : $"{{\"message\":\"token {Token} refused\"}}");
        stand.Add("GET", "/api/v2/tailnet/-/acl", 200, policy, new() { ["ETag"] = "\"v1\"" });
        stand.Add("POST", "/api/v2/tailnet/-/acl/validate", 200, "{}");
        stand.Add("POST", "/api/v2/tailnet/-/acl", 200, "{}");
        stand.Add("POST", "/api/v2/tailnet/-/keys", 200, $"{{\"id\":\"kFLEET1234CNTRL\",\"key\":\"{Secret}\"}}");
        stand.Add("POST", "/api/v2/oauth/token", 200, $"{{\"access_token\":\"{Access}\"}}");
        return stand;
    }

    /// <summary>**The owner's access token is used once and kept nowhere, and no secret is ever in a word.** The bugs:
    /// the token kept beside the fleet key (it would outlive its one use in the box); a refusal that echoes the token
    /// onto the owner's page; a fleet key, an order or a call whose text prints its secret into a log.</summary>
    [TestMethod]
    public async Task TheAccessTokenIsKeptNowhereAndNoSecretIsInAWord()
    {
        foreach (var (policy, managed) in new[] { ("{\"acls\": []}", false), ("{\"tagOwners\": {\"tag:founderizer\": []}}", true), ("{}", false) })
        {
            var box = new WatchedBox();
            var api = new TailscaleApi(Tailnet(policy, managed), box);
            var setup = await api.MakeFleetClientAsync("  " + Token + "\n");
            Assert.IsTrue(setup.KeyMade, policy);
            Assert.AreEqual(1, box.Written.Count, "only the fleet key is kept");
            Assert.AreEqual(TailscaleApi.ClientName, box.Written[0].Name);
            foreach (var (_, value) in box.Written)
                Assert.IsFalse(Encoding.UTF8.GetString(value).Contains(Token, StringComparison.Ordinal), "the access token was kept");
            var key = await api.AuthKeyAsync("worker-1", 900).ContinueWith(t => t.Exception?.InnerException?.Message ?? "");
            Assert.IsFalse(key.Contains(Access, StringComparison.Ordinal) || key.Contains(Secret, StringComparison.Ordinal), key);
        }
        // A refusal in Tailscale's words, which echo the token: the words say "(not shown)" in its place.
        var refused = await Assert.ThrowsExactlyAsync<FleetKeyException>(
            () => new TailscaleApi(Tailnet("{}", false, settingsStatus: 500), new WatchedBox()).MakeFleetClientAsync(Token));
        Assert.IsFalse(refused.Message.Contains(Token, StringComparison.Ordinal), refused.Message);
        Assert.IsTrue(refused.Message.Contains("(not shown)", StringComparison.Ordinal), refused.Message);
        // A one-hour access token and the fleet key's secret that Tailscale echoes are taken out too.
        var echo = new StandIn();
        echo.Add("POST", "/api/v2/oauth/token", 500, $"{{\"error_description\":\"client {Secret} is down\"}}");
        var held = new MemorySecretBox();
        held.Write(TailscaleApi.ClientName, Encoding.UTF8.GetBytes("kFLEET1234CNTRL\n" + Secret));
        var down = await Assert.ThrowsExactlyAsync<FleetKeyException>(() => new TailscaleApi(echo, held).AuthKeyAsync("hub-1"));
        Assert.IsFalse(down.Message.Contains(Secret, StringComparison.Ordinal), down.Message);
        var minted = Tailnet("{}", false);
        minted.Add("POST", "/api/v2/tailnet/-/keys", 400, $"{{\"message\":\"token {Access} may not\"}}");
        var keysRefused = new StandIn();
        keysRefused.Add("POST", "/api/v2/oauth/token", 200, $"{{\"access_token\":\"{Access}\"}}");
        keysRefused.Add("POST", "/api/v2/tailnet/-/keys", 400, $"{{\"message\":\"token {Access} may not\"}}");
        var mintRefused = await Assert.ThrowsExactlyAsync<FleetKeyException>(() => new TailscaleApi(keysRefused, held).AuthKeyAsync("hub-1"));
        Assert.IsFalse(mintRefused.Message.Contains(Access, StringComparison.Ordinal), mintRefused.Message);
        // No text of a fleet key, an order, the APIs or a call holds its secret.
        Assert.IsFalse(FleetClient.Of("kFLEET1234CNTRL", Secret)!.ToString().Contains(Secret, StringComparison.Ordinal));
        var order = new CloudOrder("hub-1", CloudServerUse.Hub, "ssh-ed25519 AAAA x", "tskey-auth-kAUTH1234CNTRL-notarealkey");
        Assert.IsFalse(order.ToString().Contains("tskey-auth", StringComparison.Ordinal), order.ToString());
        var cloudBox = new MemorySecretBox();
        cloudBox.Write(CloudProvider.Hetzner.BoxName(), Encoding.UTF8.GetBytes(CloudToken));
        var cloud = CloudServers.For(CloudProvider.Hetzner, new StandIn(), cloudBox, TimeSpan.Zero, (_, _) => Task.CompletedTask);
        Assert.IsFalse(cloud.ToString()!.Contains(CloudToken, StringComparison.Ordinal));
    }

    /// <summary>**A policy file that another tool keeps (GitOps, Terraform) is read and never written, nor sent to be
    /// checked**: the next run of that tool would undo the change, so a missing tag is the owner's one line. The bug: the
    /// PC writes into a managed file as into one that Tailscale keeps.</summary>
    [TestMethod]
    public async Task APolicyFileThatAnotherToolKeepsIsNeverWritten()
    {
        foreach (var policy in new[] { "{}", "{\"acls\": []}", "{\"tagOwners\": {\"tag:founderizer\": []}, \"acls\": []}", "not json" })
        {
            var stand = Tailnet(policy, managed: true);
            var setup = await new TailscaleApi(stand, new MemorySecretBox()).MakeFleetClientAsync(Token);
            Assert.IsFalse(setup.WrotePolicy, policy);
            Assert.IsTrue(setup.Place.Tool, policy);
            Assert.IsFalse(stand.Calls.Any(c => c.Method == "POST" && c.Url.AbsolutePath.Contains("/acl", StringComparison.Ordinal)),
                           policy + ": " + string.Join(", ", stand.Calls.Select(c => c.Method + " " + c.Url.AbsolutePath)));
            var tagStands = policy.Contains("tag:founderizer", StringComparison.Ordinal) || policy == "not json";
            Assert.AreEqual(tagStands, setup.KeyMade, policy);
            Assert.AreEqual(tagStands ? null : "\"tag:founderizer\": [\"autogroup:admin\"],", setup.LinesToAdd, policy);
        }
    }

    /// <summary>**Tailscale's own MSI for this kind of PC, at Tailscale's own address, and nothing else**: the name comes
    /// from the network and goes into an address and a file of this app's, and the installer runs as an administrator.
    /// The bugs: an x64 PC given the Arm installer (it does not install), a name with a path in it, a name of another
    /// version than the list's, a host other than Tailscale's.</summary>
    [TestMethod]
    public void TheInstallerIsTailscalesOwnMsiForThisKindOfPc()
    {
        // As pkgs.tailscale.com gave it on 20 November 2026.
        const string list = """
            {"Exes": ["tailscale-setup-1.104.7.exe"], "ExesVersion": "1.104.7",
             "MSIs": {"amd64": "tailscale-setup-1.104.7-amd64.msi", "arm64": "tailscale-setup-1.104.7-arm64.msi", "x86": "tailscale-setup-1.104.7-x86.msi"},
             "MSIsVersion": "1.104.7", "Version": "1.104.7"}
            """;
        var x64 = PcNetwork.InstallerFor(PcNetwork.Arch(System.Runtime.InteropServices.Architecture.X64)!, list)!;
        Assert.AreEqual(new PcNetwork.Installer("1.104.7", "tailscale-setup-1.104.7-amd64.msi",
                                                new Uri("https://pkgs.tailscale.com/stable/tailscale-setup-1.104.7-amd64.msi")), x64);
        var arm = PcNetwork.InstallerFor("arm64", list)!;
        Assert.AreEqual("https://pkgs.tailscale.com/stable/tailscale-setup-1.104.7-arm64.msi", arm.Address.AbsoluteUri);
        Assert.IsNull(PcNetwork.Arch(System.Runtime.InteropServices.Architecture.X86));
        Assert.IsNull(PcNetwork.InstallerFor("x86", list));
        foreach (var bad in new[]
                 {
                     """{"MSIs": {"amd64": "../../evil.msi"}}""", """{"MSIs": {"amd64": "tailscale-setup-1.104.7-arm64.msi"}}""",
                     """{"MSIs": {"amd64": "tailscale-setup-1.104.7-amd64.msi"}, "MSIsVersion": "1.104.8"}""",
                     """{"MSIs": {"amd64": "https://example.com/tailscale-setup-1.104.7-amd64.msi"}}""",
                     """{"MSIs": {"amd64": "tailscale-setup-1.104.7-amd64.msi\n"}}""", """{"MSIs": {}}""", "not json", "",
                 })
            Assert.IsNull(PcNetwork.InstallerFor("amd64", bad), bad);
        Assert.AreEqual("https://pkgs.tailscale.com/stable/?mode=json&os=windows", PcNetwork.Packages.AbsoluteUri);
    }

    /// <summary>A clock that only the wait's own pauses move, so a wait of an hour takes no time.</summary>
    private sealed class Clock(DateTimeOffset at)
    {
        public DateTimeOffset Now { get; private set; } = at;
        public Task Pass(TimeSpan time, CancellationToken cancel) { Now += time; return Task.CompletedTask; }
    }

    private static string Network(bool? online) =>
        """{"Self": {"DNSName": "owner-pc.tail1234.ts.net."}, "Peer": {"a": {"DNSName": "worker-1.tail1234.ts.net.", "TailscaleIPs": ["100.96.100.130"], "Online": true}"""
        + (online is { } on ? $$""", "c": {"DNSName": "worker-3.tail1234.ts.net.", "TailscaleIPs": ["100.64.0.31"], "Online": {{(on ? "true" : "false")}}}""" : "")
        + "}}";

    /// <summary>**The app waits for a new server until its key ends, one hour, and a server that joined out of this PC's
    /// sight ends the wait after six minutes** (the Mac's own cases). The bugs: a wait of the Mac's old five minutes,
    /// which gives up on a first boot that waits for the server's first updates; a server that is there and not online
    /// taken as ready; a stop that does not end the wait; a server that joined and is hidden by the policy waited for an
    /// hour.</summary>
    [TestMethod]
    public async Task ANewServerIsWaitedForUntilItsKeyEnds()
    {
        var made = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var late = new Clock(made);
        var end = await CloudJoin.WaitAsync("worker-3", made, _ =>
        {
            var gone = (late.Now - made).TotalSeconds;
            return Task.FromResult<string?>(gone < 600 ? Network(null) : Network(gone >= 620));
        }, null, () => late.Now, late.Pass);
        Assert.AreEqual(new CloudJoin.End.Online("100.64.0.31"), end);
        Assert.AreEqual(620, (late.Now - made).TotalSeconds);
        var never = new Clock(made);
        Assert.AreEqual(new CloudJoin.End.Ended(),
                        await CloudJoin.WaitAsync("worker-3", made, _ => Task.FromResult<string?>(Network(false)), null, () => never.Now, never.Pass));
        Assert.AreEqual(CloudJoin.KeyLife, (never.Now - made).TotalSeconds);
        using (var stop = new CancellationTokenSource())
        {
            stop.Cancel();
            await Assert.ThrowsAsync<OperationCanceledException>(() => CloudJoin.WaitAsync(
                "worker-3", made, _ => Task.FromResult<string?>(Network(true)), null, () => made, (_, _) => Task.CompletedTask, stop.Token));
        }
        var hidden = new Clock(made);
        var asked = new List<double>();
        var listed = new JoinedDevice("worker-3.tail1234.ts.net", ["100.64.0.31"]);
        var seen = await CloudJoin.WaitAsync("worker-3", made, _ => Task.FromResult<string?>(Network(false)), _ =>
        {
            asked.Add((hidden.Now - made).TotalSeconds);
            return Task.FromResult<JoinedDevice?>(listed);
        }, () => hidden.Now, hidden.Pass);
        Assert.AreEqual(new CloudJoin.End.Listed(listed), seen);
        CollectionAssert.AreEqual(new[] { 300.0, 360.0 }, asked);
        // A PC that slept past the end: the last look still finds the server.
        var slept = new Clock(made);
        var woke = await CloudJoin.WaitAsync("worker-3", made, _ => Task.FromResult<string?>(Network((slept.Now - made).TotalSeconds > 3600)),
                                             null, () => slept.Now, (_, c) => slept.Pass(TimeSpan.FromSeconds(3601), c));
        Assert.AreEqual(new CloudJoin.End.Online("100.64.0.31"), woke);
    }
}
