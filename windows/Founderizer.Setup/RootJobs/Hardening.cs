using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using Founderizer.Owner.Reads;
using Founderizer.Setup.Install;

namespace Founderizer.Setup.RootJobs;

/// <summary>**The join's hardening, put right again by the owner's computer** (the Mac's ServerHardening; the owner's
/// "Yes, all of it" of 14 November 2026). The join of a Linux server makes its SSH take keys only and gives npm its
/// seven-day rule. A server whose join kept password login, or that has no such rule, keeps the fault until its hardening
/// runs again as root, so the PC does it by itself: in a server that joined and whose own service's current reading says
/// the fault in two rounds in a row, never in the hour after its join, never while a job of its service is open, and never
/// against a choice (a server is settled once a reading or a run says that its hardening holds). The hub's own server the
/// same way, by the hub's own reading of it.</summary>
public static class Hardening
{
    /// <summary>The file that the join's hardening writes in sshd's folder, and its text: byte for byte
    /// <c>hubsetup.py</c>'s <c>SSHD_HARDENING</c> and <c>SSHD_TEXT</c>.</summary>
    public const string SshdFolder = "/etc/ssh/sshd_config.d";
    public const string SshdFile = SshdFolder + "/10-fleet-hardening.conf";
    public const string SshdText =
        "# Founderizer's join writes this file (hubsetup.py harden): SSH takes keys only, and no X11 forwarding.\n"
        + "PasswordAuthentication no\nKbdInteractiveAuthentication no\nX11Forwarding no\n";

    /// <summary>npm's line for every user of the system (<c>hubsetup.py</c>'s <c>NPMRC</c> and <c>NPM_RULE</c>).</summary>
    public const string Npmrc = "/etc/npmrc";
    public const string NpmRule = "min-release-age=7";

    /// <summary>The first word of the program's last line, which says what each part came to.</summary>
    internal const string Mark = "founderizer-hardening";

    /// <summary>**The program's first line, alone on its line, before it reads or changes anything on the server.** A call
    /// that did not log in and a connection that broke while the program ran both end with no status, so this line says
    /// whether the program started.</summary>
    public const string Started = Mark + "-started";

    /// <summary>Whether the owner's computer puts the hardening of this server right at all: a Linux server that joined, and
    /// the hub's own server where the hub gives its own reading of it. Not a Mac that joined as a server.</summary>
    public static bool Applies(ServerEntry server) =>
        server.Hub ? HubHardening.Read(server.Hardening) is not null && !server.IsMac : server is { Kind: "linux", Joined: true };

    /// <summary>What one round reads of a server's hardening. <paramref name="join"/>: the fleet's newest join.
    /// <paramref name="time"/>: the hub's clock, which the reading, the join and the hub's claim are all on.</summary>
    public static SweepReading ReadingOf(ServerEntry server, JoinState? join, double time)
    {
        if (!Applies(server) || server.Job?.IsOpen == true) return SweepReading.Unread;
        if (join is not null && join.Server == server.Name && time - join.Created < RootJob.JoinGrace) return SweepReading.Unread;
        bool? ssh, npm;
        if (server.Hub)
        {
            // The hub's own read, also where its server has a service with a reading of its own: one source, so that the
            // two never disagree.
            if (HubHardening.Read(server.Hardening) is not { } own || !own.IsCurrent(time) ||
                own.ClaimedAt is not { } claimed || time - claimed < RootJob.JoinGrace) return SweepReading.Unread;
            (ssh, npm) = (own.SshKeysOnly, own.NpmRule);
        }
        else
        {
            if (server.Reading is not { Source: "server", Security: { } security } reading || !reading.IsCurrent(time))
                return SweepReading.Unread;
            (ssh, npm) = (security.SshKeysOnly, security.NpmRule);
        }
        if (ssh == false || npm == false) return SweepReading.Faulty;
        return ssh == true ? SweepReading.Holds : SweepReading.Unread;
    }

    /// <summary>**The program, as root on the server** (the Mac's, byte for byte: <c>remote-root.json</c> holds it). SSH
    /// first: nothing where OpenSSH does not run or no account has an SSH key; else the file in sshd's folder, checked with
    /// <c>sshd -t</c> and taken back when sshd refuses it, sshd reloaded and read back with <c>sshd -T</c>; then npm's line
    /// where <c>/etc/npmrc</c> has none. It changes nothing before it has printed its first line.</summary>
    public static string Program()
    {
        var r = InstallPlan.Quote("");
        var text = InstallPlan.Quote(SshdText);
        return $"printf '\\n%s\\n' {Started} || exit 1\n"
        + $"r={r}; d=\"$r{SshdFolder}\"; f=\"$r{SshdFile}\"; s=; n=; b=\n"
        + $"if ! systemctl is-active ssh.service ssh.socket 2>/dev/null | grep -qx active; then s=off\n"
        + $"elif ! ( for k in \"$r\"/root/.ssh/authorized_keys \"$r\"/root/.ssh/authorized_keys2 \"$r\"/home/*/.ssh/authorized_keys \"$r\"/home/*/.ssh/authorized_keys2; do\n"
        + $"  [ -f \"$k\" ] && grep -qv -e '^[[:space:]]*#' -e '^[[:space:]]*$' \"$k\" && exit 0; done; exit 1 ); then s=no-key\n"
        + $"elif [ ! -d \"$d\" ]; then s=no-folder\n"
        + $"else\n"
        + $"  [ -d \"$r/run/sshd\" ] || {{ mkdir \"$r/run/sshd\" && chmod 755 \"$r/run/sshd\"; }} 2>/dev/null\n"
        + $"  n=$(mktemp \"$d/.fleet-XXXXXX\") && printf '%s' {text} > \"$n\" && chmod 644 \"$n\" || s=not-written\n"
        + $"  if [ -z \"$s\" ] && ! cmp -s \"$n\" \"$f\"; then\n"
        + $"    if [ -f \"$f\" ]; then b=$(mktemp \"$d/.fleet-XXXXXX\") && cp -p \"$f\" \"$b\" || s=not-written; fi\n"
        + $"    if [ -z \"$s\" ]; then\n"
        + $"      mv -f \"$n\" \"$f\"; n=\n"
        + $"      if ! o=$(sshd -t 2>&1); then\n"
        + $"        if [ -n \"$b\" ]; then mv -f \"$b\" \"$f\"; b=; else rm -f \"$f\"; fi\n"
        + $"        printf '%s\\n' \"$o\" | tail -n 3; s=refused\n"
        + $"      fi\n"
        + $"    fi\n"
        + $"  fi\n"
        + $"  [ -z \"$n\" ] || rm -f \"$n\"; [ -z \"$b\" ] || rm -f \"$b\"\n"
        + $"  if [ -z \"$s\" ]; then\n"
        + $"    systemctl try-reload-or-restart ssh.service >/dev/null 2>&1\n"
        + $"    t=$(sshd -T 2>/dev/null)\n"
        + $"    if printf '%s\\n' \"$t\" | grep -qx 'passwordauthentication no' && printf '%s\\n' \"$t\" | grep -qx 'kbdinteractiveauthentication no' && printf '%s\\n' \"$t\" | grep -qx 'x11forwarding no'; then s=keys-only; else s=not-yet; fi\n"
        + $"  fi\n"
        + $"fi\n"
        + $"m=\"$r{Npmrc}\"\n"
        + $"if [ -f \"$m\" ] && grep -q '^[[:space:]]*min-release-age[[:space:]]*=' \"$m\"; then p=held\n"
        + $"elif [ ! -e \"$m\" ]; then\n"
        + $"  if printf '%s\\n' '{NpmRule}' > \"$m\" && chmod 644 \"$m\"; then p=made; else p=failed; fi\n"
        + $"elif {{ [ -z \"$(tail -c1 \"$m\")\" ] || echo; printf '%s\\n' '{NpmRule}'; }} >> \"$m\"; then p=made\n"
        + $"else p=failed\n"
        + $"fi\n"
        + $"echo \"{Mark} ssh=$s npm=$p\"";
    }

    /// <summary>What one run came to, read from the output's last <c>founderizer-hardening</c> line (the Mac's
    /// <c>outcome</c>). Output without one is a run that did not end where it has the program's first line, and else reads
    /// as a program that did not start.</summary>
    public static SweepOutcome Outcome(string output)
    {
        var all = RootJob.Lines(output);
        var lines = all.Where(l => l != Started).ToList();
        if (lines.FindLast(l => l.StartsWith(Mark + " ", StringComparison.Ordinal)) is not { } last)
        {
            var said = lines.FindLast(l => l.Length > 0) is { } line ? RootJob.Prefix(line, 200) : "nothing";
            return lines.Count == all.Count ? new SweepOutcome.NotStarted("the program did not start: " + said)
                                            : new SweepOutcome.Failed("the program started and did not end: " + said);
        }
        var parts = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var word in last.Split(' ', StringSplitOptions.RemoveEmptyEntries).Skip(1))
        {
            var at = word.IndexOf('=');
            if (at > 0 && at < word.Length - 1) parts[word[..at]] = word[(at + 1)..];
        }
        string ssh = parts.GetValueOrDefault("ssh", ""), npm = parts.GetValueOrDefault("npm", "");
        if (ssh == "no-key") return new SweepOutcome.LeftAsItIs();
        if (ssh is "keys-only" or "off" && npm is "held" or "made") return new SweepOutcome.Holds();
        var before = string.Join(" ", lines.TakeWhile(l => l != last).Where(l => l.Length > 0).TakeLast(3));
        return new SweepOutcome.Failed($"ssh {(ssh.Length == 0 ? "?" : ssh)}, npm {(npm.Length == 0 ? "?" : npm)}"
                                       + (before.Length == 0 ? "" : ": " + RootJob.Prefix(before, 300)));
    }
}

/// <summary>**The hub's own reading of its own server's SSH and npm** (owner API 1.170; the Mac's HubHardening): that
/// server has no server service. A value that cannot be read is null, and a key that cannot be read at all loses its facts
/// and never the list. Null where the row has none, or says null.</summary>
public sealed record HubHardening(bool? SshKeysOnly, bool? NpmRule, double? At, double? ClaimedAt)
{
    /// <summary>The value of a row's <c>hardening</c>: null for a row with none.</summary>
    public static HubHardening? Read(JsonElement? value)
    {
        if (value is not { } given || given.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
        bool? Fact(string name) => RootServer.Member(given, name) is { ValueKind: JsonValueKind.True or JsonValueKind.False } fact
            ? fact.GetBoolean() : null;
        double? Time(string name) => RootServer.Member(given, name) is { ValueKind: JsonValueKind.Number } time &&
                                     time.TryGetDouble(out var number) && double.IsFinite(number) ? number : null;
        return new HubHardening(Fact("ssh_keys_only"), Fact("npm_rule"), Time("at"), Time("claimed_at"));
    }

    /// <summary>Read in the last ten minutes, by the hub's clock.</summary>
    public bool IsCurrent(double time) => At is { } at && time - at >= -5 && time - at < 600;
}
