using System;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;

namespace Founderizer.Setup.Install;

/// <summary>What a read of the hub from this PC said, while the install waits for the hub installer's link code (the
/// Mac's MachineInstaller.HubRead).</summary>
public enum HubRead
{
    /// <summary>The hub served this PC its state: this PC is its owner.</summary>
    Serves,
    /// <summary>Something answered with 403. A hub says so to a computer that is not its owner's, and also to its owner's
    /// computer for one read whose key it does not take: one refusal alone decides nothing.</summary>
    Refuses,
    /// <summary>Nothing that says either: no answer, the claim's own listener, a hub that starts.</summary>
    Silent,
}

/// <summary>**The claim of a new hub, as the install's step makes it** (the Mac's MachineInstaller.sendClaim and
/// readHub). The HTTP of the claim and the key of the owner's PC are piece L0's (<see cref="OwnerPcKey.ClaimAsync"/>):
/// the key's SHA-256 is made from the box there, so this step takes the box and not a SHA-256.</summary>
public static class Claim
{
    /// <summary>The step's title, as its failures name it.</summary>
    public const string Title = "Claim the hub";

    /// <summary>The hub's own port on the private network (the Mac's FleetOnTailscale.hubPort).</summary>
    public const int HubPort = 8765;

    /// <summary>**An address that a claim may go to**: HTTP, a number of 100.64.0.0/10, the path <c>/claim</c>, and
    /// nothing else (no login, query or fragment).</summary>
    public static bool IsTarget(Uri claim) =>
        claim.IsAbsoluteUri && claim.Scheme == "http" && OwnerPcKey.IsClaimAddress(claim.Host) && claim.AbsolutePath == "/claim" &&
        claim.Query.Length == 0 && claim.Fragment.Length == 0 && claim.UserInfo.Length == 0;

    /// <summary>**The claim, from this PC and from nowhere else**: the code to the address that the installer printed,
    /// with the SHA-256 of the PC's key for that hub (L0). Null when the hub took it; else the owner's words: the
    /// listener's own, or the PC's when the address is not on the private network (and then nothing is sent).</summary>
    public static Task<string?> SendAsync(HubClient http, ISecretBox box, Uri claim, string code, CancellationToken cancel = default) =>
        IsTarget(claim) ? OwnerPcKey.ClaimAsync(http, box, claim, code, cancel) : Task.FromResult<string?>(OwnerPcKey.NotOnYourNetwork);

    /// <summary>**One read of the hub from this PC** (the Mac's readHub): GET /ui/mobile with the PC's key for that hub,
    /// the kept one first and, after a refusal, the one that waits (the Mac's rule of two keys). The claim's listener
    /// serves only the claim, so this read harms no claim that waits.</summary>
    public static async Task<HubRead> ReadHubAsync(HubClient http, ISecretBox box, Uri hub, CancellationToken cancel = default)
    {
        string? kept = null, waiting = null;
        try
        {
            kept = OwnerPcKey.Read(box, hub);
            waiting = OwnerPcKey.Waiting(box, hub);
        }
        catch (Exception e) when (e is not OutOfMemoryException) { }
        var read = await ReadOnceAsync(http, hub, kept ?? waiting, cancel);
        if (read == HubRead.Refuses && kept is not null && waiting is not null && waiting != kept)
            read = await ReadOnceAsync(http, hub, waiting, cancel);
        return read;
    }

    private static async Task<HubRead> ReadOnceAsync(HubClient http, Uri hub, string? key, CancellationToken cancel)
    {
        try
        {
            await http.SnapshotAsync(hub, key, null, null, cancel);
            return HubRead.Serves;
        }
        catch (HubException e) when (e is { Kind: HubErrorKind.Refusal, Status: 403 })
        {
            return HubRead.Refuses;
        }
        catch (Exception e) when (e is not OutOfMemoryException && !(e is OperationCanceledException && cancel.IsCancellationRequested))
        {
            // Every other answer, and no answer, leaves the wait as it is (the Mac's readHub).
            return HubRead.Silent;
        }
    }
}
