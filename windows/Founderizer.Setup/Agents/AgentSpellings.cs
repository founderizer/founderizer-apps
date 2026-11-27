using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Owner.Reads;
using Founderizer.Setup.FirstRun;

namespace Founderizer.Setup.Agents;

/// <summary>**His capitals of a name that the hub took without them** (hub feature <c>agent_spelling</c>, owner API 1.339;
/// the validator's W-S1; FleetCore's <c>SpellingNotes</c>, the Mac's <c>FleetStore.noteSpelling</c>): the first run's
/// installer names the manager in small letters ("mcbot" for "McBot"), so this PC keeps the name as he typed it for that
/// hub, its generation and the agent, and <see cref="AgentSpellingSender"/> sends it once, under the hood, as a new
/// spelling of the same name. The notes are among the first run's kept answers (<see cref="ISetupChoices"/>), so an app
/// that starts again still sends them. Only the name in other capitals is a note: a name in small letters, or other words,
/// is none, and takes away a note of that agent from before. A note goes when the hub took its spelling or refused it; when
/// a reading shows any spelling of the agent (the installer gives the first run's manager none, so a spelling there came
/// after the note: his newer word on another device stays); when a reading of its hub and generation does not list the
/// agent (renamed or removed: a later agent of that name is another one); when it went <see cref="SendsMost"/> times and
/// each came to nothing; when a current reading of its hub shows another generation; and with its hub at Start again.
/// Four of these depart from the Mac's notes of 0fb82692e, which live in memory only: the count across starts, any
/// spelling (the Mac's 48866c69d takes it too, with `over`, the spelling that a press typed over, which this PC's note does
/// not record yet), the agent that is not listed, and a reading of the hub in another generation.</summary>
public static class AgentSpellingNotes
{
    /// <summary>The name of the notes among the first run's kept answers: one line for each note.</summary>
    public const string ChoiceName = "agentSpellings";

    /// <summary>The most notes that this PC keeps: the newest stay. One first run makes one.</summary>
    public const int Most = 8;

    /// <summary>**How many times a spelling goes at most** (the validator's S1 on 66c6c6b70; the Mac's
    /// <c>SpellingNotes.sendsMost</c>, 459eb5a39: a wait ends on an event or a count): sends with no answer, or with a
    /// team.json that changed twice, end after this many, and the name keeps the capitals of the plain rule. Each note
    /// counts its own in its line, so a start of the app does not start the count again; a new note does.</summary>
    public const int SendsMost = 3;

    /// <summary>One read and the write that follows it at a time in this app: the first run and the sender each write from
    /// a thread of their own.</summary>
    private static readonly object Writes = new();

    /// <summary>The notes that this PC keeps, oldest first; a line of no valid shape is none.</summary>
    public static IReadOnlyList<AgentSpellingNote> Read(ISetupChoices choices)
    {
        lock (Writes) return Parse(choices.Get(ChoiceName));
    }

    /// <summary>**Keeps the name as he typed it for <paramref name="agent"/>** of this hub and generation, in place of a
    /// note of that agent from before. Words that are not the agent's name in other capitals keep no note and take that
    /// note away (<see cref="AgentBook.Spelling"/>). It never throws: the first run's hand-over writes it.</summary>
    public static void Note(ISetupChoices choices, Uri hub, string db, string agent, string typed)
    {
        if (hub is not { IsAbsoluteUri: true, Scheme: "http" or "https" } || !Fits(db)) return;
        var spelling = AgentBook.Spelling(typed, agent, served: true);
        lock (Writes)
        {
            var notes = Parse(choices.Get(ChoiceName)).Where(n => !(n.IsOf(hub, db) && n.Agent == agent)).ToList();
            if (spelling is not null) notes.Add(new AgentSpellingNote(hub, db, agent, spelling));
            Write(choices, notes.TakeLast(Most));
        }
    }

    /// <summary>Takes this note away, when it is still kept as it is.</summary>
    public static void Forget(ISetupChoices choices, AgentSpellingNote note)
    {
        lock (Writes)
        {
            var notes = Parse(choices.Get(ChoiceName));
            if (notes.Contains(note)) Write(choices, notes.Where(n => n != note));
        }
    }

    /// <summary>**Counts one more send of this note**, before it goes, so that a send that an app's end cuts still counts:
    /// the note with its count, or null when the note is not kept as it is any more (another note of the agent took its
    /// place, or a reading of another generation took it away), and then nothing goes.</summary>
    public static AgentSpellingNote? Count(ISetupChoices choices, AgentSpellingNote note)
    {
        lock (Writes)
        {
            var notes = Parse(choices.Get(ChoiceName));
            var at = notes.IndexOf(note);
            if (at < 0) return null;
            notes[at] = note with { Sends = note.Sends + 1 };
            Write(choices, notes);
            return notes[at];
        }
    }

    /// <summary>**Takes away the notes of this hub's other generations** (the validator's S2 on 66c6c6b70): a current reading
    /// of the hub in this generation says that they are dead, as no reading of theirs comes again. It writes nothing when
    /// there is none.</summary>
    public static void ForgetOtherGenerations(ISetupChoices choices, Uri hub, string db)
    {
        lock (Writes)
        {
            var notes = Parse(choices.Get(ChoiceName));
            if (notes.Any(n => n.IsOf(hub, n.Db) && n.Db != db)) Write(choices, notes.Where(n => !(n.IsOf(hub, n.Db) && n.Db != db)));
        }
    }

    /// <summary>Takes away every note of this hub, of any generation: Start again takes the hub away. It never throws.</summary>
    public static void ForgetHub(ISetupChoices choices, Uri hub)
    {
        lock (Writes)
        {
            var notes = Parse(choices.Get(ChoiceName));
            if (notes.Any(n => n.IsOf(hub, n.Db))) Write(choices, notes.Where(n => !n.IsOf(hub, n.Db)));
        }
    }

    private static void Write(ISetupChoices choices, IEnumerable<AgentSpellingNote> notes)
    {
        var lines = notes.Select(n => string.Join('|', n.Hub.GetLeftPart(UriPartial.Authority) + "/", n.Db, n.Agent, n.Spelling,
                                                  n.Sends.ToString(CultureInfo.InvariantCulture))).ToList();
        choices.Set(ChoiceName, lines.Count == 0 ? null : string.Join('\n', lines));
    }

    private static List<AgentSpellingNote> Parse(string? kept)
    {
        var notes = new List<AgentSpellingNote>();
        foreach (var line in (kept ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            // The count of its sends is the line's fifth part (0 to SendsMost); a line of four parts has none yet.
            var parts = line.Split('|');
            if (parts.Length is not (4 or 5)) continue;
            var (hub, db, agent, spelling) = (parts[0], parts[1], parts[2], parts[3]);
            var sends = 0;
            if (!Fits(db) || !ManagerSetupMark.Holds(agent) || AgentBook.Spelling(spelling, agent, served: true) != spelling ||
                parts.Length == 5 && (!int.TryParse(parts[4], NumberStyles.None, CultureInfo.InvariantCulture, out sends) || sends > SendsMost))
                continue;
            try { notes.Add(new AgentSpellingNote(HubClient.Address(hub), db, agent, spelling, sends)); }
            catch (HubException) { }
        }
        return notes;
    }

    /// <summary>A generation that a note can hold: one line with no "|".</summary>
    private static bool Fits(string db) => db.Length is > 0 and <= 200 && db.IndexOfAny(['|', '\n', '\r']) < 0;
}

/// <summary>One kept spelling: the hub by its scheme, host and port, its generation, the agent, the name as he typed it,
/// and how many times it went (<see cref="AgentSpellingNotes.SendsMost"/>).</summary>
public sealed record AgentSpellingNote(Uri Hub, string Db, string Agent, string Spelling, int Sends = 0)
{
    /// <summary>The note is of this hub (the same scheme, host and port) and of this generation of it.</summary>
    public bool IsOf(Uri hub, string db) =>
        db == Db && hub.IsAbsoluteUri &&
        Uri.Compare(hub, Hub, UriComponents.SchemeAndServer, UriFormat.SafeUnescaped, StringComparison.OrdinalIgnoreCase) == 0;
}

/// <summary>**The kept spellings go to the hub, each once, at a current reading** (the Mac's <c>spellingTick</c>, with the
/// validator's A-S1 point taken): a reading of the hub and generation of a note, from a hub that serves
/// <c>agent_spelling</c>, on the owner's computer, that lists the note's agent and shows no spelling of it. Such a reading
/// that does not list the agent, or that shows any spelling of it, ends the note with no command. The spelling goes as a new spelling of the
/// same name (<see cref="OwnerReads.RespellAsync"/>), against the team that the hub gives first; a team that changed between
/// that read and the command (409 <c>team_changed</c>) is read again, once. The hub's answer, or its refusal, ends the note:
/// a refusal leaves the name with the capitals of the plain rule. A send that came to nothing (no answer, a team read that
/// does not read or is of another generation, an answer that is not this command's, or a team.json that changed twice,
/// the Mac's <c>later</c>) keeps it for a later reading, <see cref="AgentSpellingNotes.SendsMost"/> sends in all, also
/// across starts of the app. A current reading of the hub in another generation ends that generation's notes. One send at a time; nothing shows on a
/// page, and the window does not wait for it.</summary>
public sealed class AgentSpellingSender(OwnerReads.ICalls calls, ISetupChoices choices, Func<Task>? refresh = null)
{
    private readonly object gate = new();
    private bool sending;

    /// <summary>What one send came to.</summary>
    private enum Sent { Taken, Refused, Unanswered }

    /// <summary>**One state of the owner's store.** A test waits for it; the window does not.</summary>
    public async Task NoteAsync(StoreState state, DateTimeOffset now, CancellationToken cancel = default)
    {
        if (state.Role != HubRole.Owner || state.Hub is not { } hub || state.Fleet is not { } fleet || !state.IsFresh(now)) return;
        // The kept answers are read from memory (FileChoices reads its file once), and nothing is written but a change.
        AgentSpellingNotes.ForgetOtherGenerations(choices, hub, fleet.Db);
        if (!fleet.Offers(AgentBook.SpellingFeature)) return;
        var due = AgentSpellingNotes.Read(choices).Where(n => n.IsOf(hub, fleet.Db)).ToList();
        if (due.Count == 0) return;
        lock (gate)
        {
            if (sending) return;
            sending = true;
        }
        try
        {
            var spellings = AgentBook.Spellings(fleet.Agents.Select(a => (a.Name, a.Spelling)), served: true);
            var taken = false;
            foreach (var note in due)
            {
                if (!fleet.Agents.Any(a => a.Name == note.Agent))
                {
                    // Renamed or removed since the note: a later agent of that name is another one, and gets none of it.
                    AgentSpellingNotes.Forget(choices, note);
                    continue;
                }
                if (spellings.ContainsKey(note.Agent))
                {
                    // The hub keeps a spelling of it: this one, from a send whose answer was lost, or a newer one that he
                    // gave on another device or with an owner tool, which an older note must not write over.
                    AgentSpellingNotes.Forget(choices, note);
                    continue;
                }
                if (note.Sends >= AgentSpellingNotes.SendsMost || AgentSpellingNotes.Count(choices, note) is not { } counted)
                {
                    // Given up already (an app that ended after its last send), or not kept as it is any more.
                    if (note.Sends >= AgentSpellingNotes.SendsMost) AgentSpellingNotes.Forget(choices, note);
                    continue;
                }
                var sent = await SendAsync(counted, cancel).ConfigureAwait(false);
                // The answer or a refusal ends it; a send that came to nothing ends it at the count's end.
                if (sent != Sent.Unanswered || counted.Sends >= AgentSpellingNotes.SendsMost) AgentSpellingNotes.Forget(choices, counted);
                taken |= sent == Sent.Taken;
            }
            if (taken && refresh is not null) await refresh().ConfigureAwait(false);
        }
        finally
        {
            lock (gate) sending = false;
        }
    }

    private async Task<Sent> SendAsync(AgentSpellingNote note, CancellationToken cancel)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            try
            {
                // A changed generation answers with nothing: the note stays until a reading of the new one takes it away.
                if ((await OwnerReads.TeamAsync(calls, cancel).ConfigureAwait(false)).Value is not { } team || team.Db != note.Db)
                    return Sent.Unanswered;
                var answer = await OwnerReads.RespellAsync(calls, note.Agent, team.Sha256, note.Spelling, cancel: cancel).ConfigureAwait(false);
                return answer.Value is null ? Sent.Unanswered : Sent.Taken;
            }
            catch (HubException refused) when (refused.Kind == HubErrorKind.Refusal)
            {
                // A team.json that changed between the read and the command (the Mac's setup writes, AgentSetupWizard):
                // the team is read again, once; a second change comes to nothing, as no answer does (the Mac's later).
                if (refused is { Status: 409, Code: ManagerRename.TeamChanged })
                {
                    if (attempt == 0) continue;
                    return Sent.Unanswered;
                }
                return Sent.Refused;
            }
            catch (ArgumentException)
            {
                return Sent.Refused;
            }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested) { throw; }
            catch (Exception e) when (e is HubException or InvalidOperationException or JsonException or OperationCanceledException)
            {
                return Sent.Unanswered;
            }
        }
        return Sent.Refused;
    }
}
