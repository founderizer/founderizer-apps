using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Core;

/// <summary>**A press of Continue on "Name your manager"** (FleetCore's <c>ManagerRename</c>, the Mac's 6e83cad2f, case for
/// case). The hub can rename the manager and its answer can be lost, while the window still shows the old name. So each
/// press reads the team first, and the team decides, never that old reading: no press renames a name that is gone.</summary>
public static class ManagerRename
{
    /// <summary>The hub's code of a refusal of a call for an agent that it does not have: an earlier press may have renamed
    /// it (the Mac's <c>RefusalMeaning.noSuchAgent</c>).</summary>
    public const string NoSuchAgent = "no_such_agent";

    /// <summary>The hub's code of a refusal of a command against a team.json that changed (409).</summary>
    public const string TeamChanged = "team_changed";

    /// <summary>What the press needs of <c>GET /ui/team</c>: each agent of the team, the agent whose role is the
    /// manager's, and the file's SHA-256, which the rename goes against.</summary>
    public sealed record Team(IReadOnlyList<string> Names, string? Manager, string Sha256);

    /// <summary>What a press comes to.</summary>
    public abstract record Outcome
    {
        private Outcome() { }

        /// <summary>The manager has the page's name, and he goes on with it: no rename.</summary>
        public sealed record Keep : Outcome;

        /// <summary>The hub took the new name.</summary>
        public sealed record Named : Outcome;

        /// <summary>The page's name is gone, and the manager is <paramref name="Now"/>: an earlier press renamed it, and this
        /// press sent nothing. When <paramref name="Now"/> is the wanted name, this is that rename's receipt; when it is
        /// another, its name page shows again.</summary>
        public sealed record Renamed(string Now) : Outcome;

        /// <summary>The hub refused this press's command. The rename of an earlier press can have been made all the
        /// same.</summary>
        public sealed record Refused(HubException Refusal) : Outcome;

        /// <summary>No answer: the hub can have the new name.</summary>
        public sealed record Unanswered : Outcome;

        /// <summary>The window went to another hub, or the hub to another generation: nothing of this press counts.</summary>
        public sealed record Moved : Outcome;
    }

    /// <summary>The team is read at the press. A team that changed between the read and the command, also by the rename of
    /// an earlier press, is read again, once. <paramref name="team"/> gives null when the window went to another hub or
    /// generation; <paramref name="rename"/> gives false when its call was answered with nothing (the hub's generation
    /// changed): the press counts for nothing.</summary>
    public static async Task<Outcome> PressAsync(string was, string wanted, Func<Task<Team?>> team, Func<string, Task<bool>> rename,
                                                 CancellationToken cancel = default)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                if (await team().ConfigureAwait(false) is not { } read) return new Outcome.Moved();
                if (!read.Names.Contains(was) && read.Manager is { } now) return new Outcome.Renamed(now);
                if (wanted == was) return new Outcome.Keep();
                return await rename(read.Sha256).ConfigureAwait(false) ? new Outcome.Named() : new Outcome.Moved();
            }
            catch (HubException refused) when (refused.Kind == HubErrorKind.Refusal)
            {
                // A team that changed, or a name that is gone: the rename of an earlier press can have landed meanwhile. The
                // team is read again, once, before the refusal stands.
                if (attempt == 0 && (refused.Code == NoSuchAgent || refused is { Status: 409, Code: TeamChanged })) continue;
                return new Outcome.Refused(refused);
            }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested) { throw; }
            catch (Exception e) when (e is HubException or InvalidOperationException or ArgumentException or JsonException or
                                      OperationCanceledException)
            {
                return new Outcome.Unanswered();
            }
        }
        return new Outcome.Unanswered();
    }
}

/// <summary>**The note that this window asked the hub to rename the manager** (FleetCore's <c>ManagerRenameNote</c>). The
/// window shows the manager under the name that it had, and its answer can be lost: the first reading that has no agent of
/// that name shows the manager's name now, and the page goes to it. The note is for one hub and one generation. Nothing
/// takes it away before: a refusal says only that its own command renamed nothing, and a note whose manager keeps its
/// name does nothing. The name that a press asked for is not in it, so a worker of that name never takes the page.</summary>
public sealed record ManagerRenameNote(Uri Hub, string Db, string Was)
{
    /// <summary>The note of this manager of this hub and generation.</summary>
    public bool Is(Uri hub, string db, string was) => Db == db && Was == was && SameHub(hub, Hub);

    /// <summary>The manager's name in this reading, when it is that of the note's hub and generation and no agent has the
    /// noted name any more.</summary>
    public string? Follow(Uri hub, MobileSnapshot reading)
    {
        if (!SameHub(hub, Hub) || reading.Db != Db || reading.Agents.Any(a => a.Name == Was)) return null;
        return reading.Agents.FirstOrDefault(a => a.Role == "manager")?.Name;
    }

    private static bool SameHub(Uri one, Uri other) =>
        Uri.Compare(one, other, UriComponents.SchemeAndServer, UriFormat.SafeUnescaped, StringComparison.OrdinalIgnoreCase) == 0;
}
