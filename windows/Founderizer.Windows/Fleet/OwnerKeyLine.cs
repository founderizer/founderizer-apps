using Founderizer.Core;

namespace Founderizer.Windows.Fleet;

/// <summary>**The line over the page when the hub refuses the key of the owner's computer** (windows-app-plan-v2.md, 5.2,
/// piece U1). The hub's refusals <c>owner_key_required</c>, <c>owner_key_mismatch</c> and <c>key_not_expected</c> are
/// values of its <c>auth</c>. The Mac shows no sentence for them: it repairs each by itself, which the PC does with piece
/// L6. Until then the library's line names a phone ("The hub refused this phone (…)") or the owner's Mac and a step that
/// the owner's computer does not have (Forget the key, which takes nothing off there). So on the owner's computer each
/// value gets one sentence of its own with "PC" (the step-1 sentences of a device's key, with no step to take: "owner
/// key" is the Mac's word for the fleet's signing key), and the line's one action is Try again: Settings has nothing to
/// repair there. These are new words of the PC, which go to the owner with wave A's built pictures. A device keeps the
/// library's line.</summary>
internal static class OwnerKeyLine
{
    public const string Required = "The hub wants this PC's key and the PC sent none.";
    public const string Mismatch = "This PC's key is not the one the hub keeps.";
    public const string NotExpected = "The hub takes no key from this PC.";

    /// <summary>The line as the window shows it: the library's, or for a refusal of the owner's key on the owner's
    /// computer, its own sentence with Try again.</summary>
    public static ConnectionLine? Of(StoreState state, ConnectionLine? line)
    {
        if (line is null || state.Role != HubRole.Owner || state.AuthProblem is not { } auth) return line;
        string? words = auth switch
        {
            OwnerPcKey.Required => Required,
            OwnerPcKey.Mismatch => Mismatch,
            OwnerPcKey.NotExpected => NotExpected,
            _ => null,
        };
        // Only where the line says the refusal itself: the key's own words, when the key is locked, stand first.
        return words is null || state.KeyWords is not null ? line : new ConnectionLine(words, ActionIsSettings: false);
    }
}
