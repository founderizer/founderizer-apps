using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Remote;

namespace Founderizer.Setup.Install;

/// <summary>**The check of a server before an install** (the Mac's FleetCore/ServerCheck.swift): one SSH session runs
/// one POSIX <c>sh</c> script, <see cref="Script"/>, as the user this PC logs in as. It changes nothing on the server and
/// prints <c>key=value</c> lines, which <see cref="Read"/> takes and <see cref="VerdictOf"/> judges. The same script is the
/// first step of both installs, so the install checks the server that the page checked.
///
/// The Mac's run reads <c>ssh</c>'s words when it did not run the script. The PC has no such words: IRemote says which
/// way it failed (<see cref="RemoteFailure"/>), and <see cref="Failed"/> gives the Mac's sentence for each, with
/// "PC" where the Mac says "Mac".</summary>
public static class ServerCheck
{
    public const string Title = "Read the server";

    /// <summary>What the server must reach over HTTPS and IPv4.</summary>
    public static readonly IReadOnlyList<string> Hosts = ["github.com", "tailscale.com", "claude.ai", "chatgpt.com"];

    /// <summary>The floors of the Mac's <c>ServerCheck</c>: about 2 GB for the hub and for a server for agents (the hub
    /// had 1 GB until 21 November 2026), and 10 GB of free disk. A plan sold as 2 GB reports some 1,900 MB.</summary>
    internal const int HubMemoryMegabytes = 1800, AgentMemoryMegabytes = 1800, FreeDiskMegabytes = 10 * 1024;
    internal const string HubMemoryWords = "2 GB", AgentMemoryWords = "2 GB", FreeDiskWords = "10 GB";

    /// <summary>While a server is busy with its first start, the install's own check reads it again this often, and
    /// this long.</summary>
    internal const double WaitEvery = 15, WaitWithin = 1200;

    internal static readonly IReadOnlyDictionary<string, string> Architectures =
        new Dictionary<string, string> { ["x86_64"] = "x86", ["aarch64"] = "Arm" };

    /// <summary>**The script, read by <c>sh -s</c> from standard input** (the Mac's script, byte for byte: the vector
    /// file holds it).</summary>
    public const string Script =
        "{\n" +
        "PATH=\"$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"; export PATH\n" +
        "r=\"${FOUNDERIZER_CHECK_ROOT:-}\"\n" +
        "limited() { if command -v timeout >/dev/null 2>&1; then timeout 10 \"$@\"; else \"$@\"; fi; }\n" +
        "uid=$(id -u)\n" +
        "echo \"user=$(id -un)\"\n" +
        "echo \"uid=$uid\"\n" +
        "if [ \"$uid\" = 0 ]; then sudo=root\n" +
        "elif ! command -v sudo >/dev/null 2>&1; then sudo=none\n" +
        "elif sudo -n true >/dev/null 2>&1; then sudo=nopasswd\n" +
        "elif id -nG | tr ' ' '\\n' | grep -qx -e sudo -e admin -e wheel; then sudo=password\n" +
        "else sudo=none; fi\n" +
        "echo \"sudo=$sudo\"\n" +
        "for f in \"$r/etc/os-release\" \"$r/usr/lib/os-release\"; do\n" +
        "    if [ -r \"$f\" ]; then (. \"$f\"; echo \"os_id=${ID:-}\"; echo \"os_version=${VERSION_ID:-}\"; echo \"os_name=${NAME:-}\"); break; fi\n" +
        "done\n" +
        "echo \"arch=$(uname -m)\"\n" +
        "echo \"memory_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' \"$r/proc/meminfo\" 2>/dev/null)\"\n" +
        "echo \"disk_free_mb=$(df -Pk / 2>/dev/null | awk 'NR == 2 {print int($4 / 1024)}')\"\n" +
        "if [ -d \"$r/run/systemd/system\" ]; then echo systemd=yes; else echo systemd=no; fi\n" +
        "if awk 'NR > 1 && $2 == \"00000000\" {f = 1} END {exit !f}' \"$r/proc/net/route\" 2>/dev/null; then echo ipv4_route=yes\n" +
        "else echo ipv4_route=no; fi\n" +
        "if command -v curl >/dev/null 2>&1; then fetch=curl; elif command -v wget >/dev/null 2>&1; then fetch=wget; else fetch=none; fi\n" +
        "reach() {\n" +
        "    case $fetch in\n" +
        "        curl) if curl -4 -s -I -o /dev/null -m 5 \"https://$1/\"; then said=yes; else said=no; fi ;;\n" +
        "        wget) wget -4 -q --spider -T 5 -t 1 \"https://$1/\"; case $? in 0|8) said=yes ;; *) said=no ;; esac ;;\n" +
        "        *) said=none ;;\n" +
        "    esac\n" +
        "    echo \"reach=$1 $said\"\n" +
        "}\n" +
        "for h in github.com tailscale.com claude.ai chatgpt.com; do reach \"$h\" & done\n" +
        "wait\n" +
        "if command -v cloud-init >/dev/null 2>&1; then\n" +
        "    case $(limited cloud-init status 2>/dev/null | sed -n 's/^status: *//p' | head -n 1) in\n" +
        "        running|\"degraded running\") echo cloud_init=running ;;\n" +
        "        done|error|\"degraded done\") echo cloud_init=done ;;\n" +
        "        *) echo cloud_init=none ;;\n" +
        "    esac\n" +
        "else echo cloud_init=none; fi\n" +
        "lock=no\n" +
        "for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do\n" +
        "    i=$(stat -c %i \"$r$f\" 2>/dev/null) || continue\n" +
        "    awk -v i=\"$i\" '{for (k = 1; k <= NF; k++) if ($k ~ /^[0-9a-f]+:[0-9a-f]+:[0-9]+$/) {split($k, a, \":\"); if (a[3] == i) f = 1}}\n" +
        "        END {exit !f}' \"$r/proc/locks\" 2>/dev/null && lock=yes\n" +
        "done\n" +
        "echo \"dpkg_lock=$lock\"\n" +
        "if command -v ss >/dev/null 2>&1; then\n" +
        "    case $sudo in\n" +
        "        root) ss -H -tulpn ;;\n" +
        "        nopasswd) sudo -n ss -H -tulpn ;;\n" +
        "        *) ss -H -tuln ;;\n" +
        "    esac 2>/dev/null | awk '\n" +
        "    { at = $5; port = at; sub(/.*:/, \"\", port)\n" +
        "      host = substr(at, 1, length(at) - length(port) - 1)\n" +
        "      gsub(/\\[/, \"\", host); gsub(/\\]/, \"\", host); sub(/%.*/, \"\", host); split(host, o, \".\")\n" +
        "      if (host ~ /^127\\./ || host == \"::1\" || host ~ /^::ffff:127\\./ || host ~ /^169\\.254\\./ || host ~ /^fe[89ab]/ ||\n" +
        "          (o[1] == 100 && o[2] >= 64 && o[2] <= 127) || host ~ /^fd7a:115c:a1e0:/) next\n" +
        "      name = \"-\"; if (match($0, /\\(\\(\"[^\"]*\"/)) name = substr($0, RSTART + 3, RLENGTH - 4)\n" +
        "      print \"listen=\" $1 \"/\" port \"/\" name }' | sort -u\n" +
        "fi\n" +
        "if [ -x \"$r/usr/sbin/ufw\" ] || command -v ufw >/dev/null 2>&1; then\n" +
        "    if grep -qs '^ENABLED=yes' \"$r/etc/ufw/ufw.conf\"; then echo ufw=active; else echo ufw=inactive; fi\n" +
        "else echo ufw=absent; fi\n" +
        "if command -v tailscale >/dev/null 2>&1; then\n" +
        "    status=$(limited tailscale status --json 2>/dev/null)\n" +
        "    case $status in\n" +
        "        *'\"BackendState\": \"Running\"'*) echo tailscale=running\n" +
        "            printf '%s\\n' \"$status\" | awk '/\"CurrentTailnet\"/ {t = 1}\n" +
        "                t && /\"Name\":/ {sub(/^[^:]*: *\"/, \"\"); sub(/\".*$/, \"\"); print \"tailnet=\" $0; exit}' ;;\n" +
        "        *) echo tailscale=loggedout ;;\n" +
        "    esac\n" +
        "else echo tailscale=none; fi\n" +
        "echo end=yes\n" +
        "} </dev/null";

    // ------------------------------------------------------------ what it read

    public enum Sudo { Root, Nopasswd, Password, None }
    public enum Reach { Yes, No, None }
    public enum CloudInit { Running, Done, None }
    public enum Firewall { Active, Inactive, Absent }
    public enum TailscaleState { None, LoggedOut, Running }

    /// <summary>One port open to more than the server itself and the private network, and the program that holds it
    /// (<c>-</c> where the login user may not see it).</summary>
    public sealed record Listener(string Proto, int Port, string Process);

    /// <summary>One server, as the script read it.</summary>
    public sealed record Reading(string User, int Uid, Sudo Sudo, string System, string Version, string SystemName,
                                 string Arch, int? MemoryMB, int? DiskFreeMB, bool Systemd, bool Ipv4Route,
                                 IReadOnlyDictionary<string, Reach> Reaches, CloudInit CloudInit, bool DpkgLock,
                                 IReadOnlyList<Listener> Listeners, Firewall Firewall, TailscaleState Tailscale,
                                 string? Tailnet);

    /// <summary>The script's answer as values, or null when it is not one: a user, a uid and its last line are the
    /// least of it. Lines of anything else are left out.</summary>
    public static Reading? Read(string output)
    {
        var one = new Dictionary<string, string>(StringComparer.Ordinal);
        var reach = new Dictionary<string, Reach>(StringComparer.Ordinal);
        var listeners = new List<Listener>();
        foreach (var raw in Lines(output))
        {
            var line = raw.Trim(' ', '\t');
            var equals = line.IndexOf('=');
            if (equals <= 0) continue;
            string key = line[..equals], value = line[(equals + 1)..];
            switch (key)
            {
                case "reach":
                {
                    var parts = value.Split(' ', 2);
                    if (parts.Length == 2 && Hosts.Contains(parts[0]) && ReachOf(parts[1]) is { } said) reach[parts[0]] = said;
                    break;
                }
                case "listen":
                {
                    var parts = value.Split('/', 3);
                    if (parts.Length != 3 || parts[0] is not ("tcp" or "udp") || !WholeNumber(parts[1], out var port) ||
                        port is < 1 or > 65535 || listeners.Any(l => l.Proto == parts[0] && l.Port == port)) continue;
                    listeners.Add(new Listener(parts[0], port, parts[2].Length == 0 ? "-" : parts[2]));
                    break;
                }
                default:
                    one.TryAdd(key, value);
                    break;
            }
        }
        if (one.GetValueOrDefault("end") != "yes" || !one.TryGetValue("user", out var user) || user.Length == 0 ||
            !one.TryGetValue("uid", out var uidText) || !WholeNumber(uidText, out var uid)) return null;
        var tailscale = one.GetValueOrDefault("tailscale") switch
        {
            "running" => TailscaleState.Running,
            "loggedout" => TailscaleState.LoggedOut,
            _ => TailscaleState.None,
        };
        var tailnet = tailscale == TailscaleState.Running && one.TryGetValue("tailnet", out var name) && name.Length > 0 ? name : null;
        return new Reading(user, uid,
            one.GetValueOrDefault("sudo") switch { "root" => Sudo.Root, "nopasswd" => Sudo.Nopasswd, "password" => Sudo.Password, _ => Sudo.None },
            one.GetValueOrDefault("os_id") ?? "", one.GetValueOrDefault("os_version") ?? "", one.GetValueOrDefault("os_name") ?? "",
            one.GetValueOrDefault("arch") ?? "",
            one.TryGetValue("memory_mb", out var memory) && WholeNumber(memory, out var mb) ? mb : null,
            one.TryGetValue("disk_free_mb", out var disk) && WholeNumber(disk, out var free) ? free : null,
            one.GetValueOrDefault("systemd") == "yes", one.GetValueOrDefault("ipv4_route") == "yes", reach,
            one.GetValueOrDefault("cloud_init") switch { "running" => CloudInit.Running, "done" => CloudInit.Done, _ => CloudInit.None },
            one.GetValueOrDefault("dpkg_lock") == "yes",
            listeners.OrderBy(l => l.Proto, StringComparer.Ordinal).ThenBy(l => l.Port).ToList(),
            one.GetValueOrDefault("ufw") switch { "active" => Firewall.Active, "inactive" => Firewall.Inactive, _ => Firewall.Absent },
            tailscale, tailnet);
    }

    private static Reach? ReachOf(string said) => said switch
    {
        "yes" => Reach.Yes,
        "no" => Reach.No,
        "none" => Reach.None,
        _ => null,
    };

    /// <summary>A whole number as Swift's <c>Int(_:)</c> reads one: an optional sign and ASCII digits only.</summary>
    internal static bool WholeNumber(string text, out int value) =>
        int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value) &&
        text.Length > 0 && text.Trim().Length == text.Length;

    /// <summary>Lines as Swift's <c>split(whereSeparator: \.isNewline)</c> gives them: no empty ones, and "\r\n" is
    /// one line end.</summary>
    internal static IEnumerable<string> Lines(string text) =>
        text.Split(['\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029'], StringSplitOptions.RemoveEmptyEntries);

    // ------------------------------------------------------------ the verdict

    /// <summary>What the password is for: SSH itself, or the <c>sudo</c> of the login user.</summary>
    public enum PasswordNeed { Ssh, Sudo }

    /// <summary>**The one answer of a check.**</summary>
    public abstract record Verdict
    {
        private Verdict() { }
        /// <summary>The install can start: the server in a few words, and the one line of what it changes.</summary>
        public sealed record Ready(string Summary, string Changes) : Verdict;
        /// <summary>The server is busy with its first start; the same check later answers again.</summary>
        public sealed record Wait(string Says) : Verdict;
        /// <summary>The server asks for a password that this PC does not hold.</summary>
        public sealed record NeedsPassword(PasswordNeed Need) : Verdict;
        /// <summary>**The server takes SSH keys only, and not this PC's key** (piece L4c; the owner's "Key row here too" of
        /// 21 November 2026): it named its ways with its refusal of the app's key, and no password way among them. The
        /// owner's key is the way in; no password is asked. <c>Says</c> is <see cref="ServerCheck.KeysOnly"/>.</summary>
        public sealed record KeysOnly(string Says) : Verdict;
        /// <summary>The install cannot go on this server: one plain line of the cause and the fix.</summary>
        public sealed record Stop(string Says) : Verdict;
    }

    /// <summary>**The verdict on one reading** (the Mac's <c>verdict</c>): the stops first, then the password, then the
    /// wait for a server that still starts.</summary>
    public static Verdict VerdictOf(Reading reading, InstallJob job, int sshPort = 22, bool holdsSudoPassword = false,
                                    string? tailnet = null)
    {
        var system = InstallPlan.Systems(job).FirstOrDefault(s => s.Id == reading.System && s.Version == reading.Version);
        if (system is null) return new Verdict.Stop(job == InstallJob.Hub ? InstallPlan.HubSystems : InstallPlan.JoinSystems);
        if (!Architectures.TryGetValue(reading.Arch, out var arch))
            return new Verdict.Stop(reading.Arch.Length == 0
                ? "This server is of an unknown kind, and this install needs a 64-bit x86 or Arm server."
                : $"This server is a {reading.Arch} machine, and this install needs a 64-bit x86 or Arm server.");
        if (!reading.Systemd) return new Verdict.Stop("This server does not run systemd, and this install needs a full VPS that does.");
        if (reading.Sudo == Sudo.None) return new Verdict.Stop(NotRoot(reading.User));
        var (floor, words) = job == InstallJob.Hub ? (HubMemoryMegabytes, HubMemoryWords) : (AgentMemoryMegabytes, AgentMemoryWords);
        if (reading.MemoryMB is { } have && have < floor)
            return new Verdict.Stop(job == InstallJob.Hub
                ? $"This server has {Size(have)} of memory, and the hub needs about {words}. Choose a plan with more memory."
                : $"This server has {Size(have)} of memory, and a server for agents needs about {words}. Choose a plan with more memory.");
        if (reading.DiskFreeMB is { } free && free < FreeDiskMegabytes)
            return new Verdict.Stop($"This server has {Size(free)} of free disk, and the install needs about {FreeDiskWords}. Free some space, or choose a bigger disk.");
        if (!reading.Ipv4Route)
            return new Verdict.Stop("This server has no IPv4 route now, and GitHub answers over IPv4 only. Restart the server. If it still has no route, give it a public IPv4 address at your provider.");
        string[] ai = ["claude.ai", "chatgpt.com"];
        bool No(string host) => reading.Reaches.TryGetValue(host, out var said) && said == Reach.No;
        var unreached = Hosts.Where(h => !ai.Contains(h) && No(h)).ToList();
        if (job == InstallJob.Join && ai.All(No)) unreached.AddRange(ai);
        if (unreached.Count > 0)
            return new Verdict.Stop($"This server cannot reach {Spoken(unreached, "or")} over HTTPS. Let it make outgoing HTTPS connections.");
        if (tailnet is not null && reading.Tailscale == TailscaleState.Running && reading.Tailnet is { } theirs &&
            !string.Equals(theirs.ToLowerInvariant(), tailnet.ToLowerInvariant(), StringComparison.Ordinal))
            return new Verdict.Stop($"This server is on another Tailscale network, {theirs}. Run tailscale logout on it, then check again.");
        if (reading.Sudo == Sudo.Password && !holdsSudoPassword) return new Verdict.NeedsPassword(PasswordNeed.Sudo);
        if (reading.CloudInit == CloudInit.Running) return new Verdict.Wait("The server is still setting itself up after its first start.");
        if (reading.DpkgLock) return new Verdict.Wait("The server is installing its updates.");
        return new Verdict.Ready($"{system.Name} {system.Version} · {RoundGigabytes(reading.MemoryMB)} · {arch}",
                                 Changes(reading, sshPort));
    }

    /// <summary>**What the install changes, in one line**: SSH moves onto the private network, and every other TCP port
    /// that was open before stays open.</summary>
    internal static string Changes(Reading reading, int sshPort)
    {
        var ports = reading.Listeners.Where(l => l.Proto == "tcp" && l.Port != sshPort && l.Process is not ("sshd" or "ssh"))
                           .Select(l => l.Port).Distinct().Order().ToList();
        return ports.Count switch
        {
            0 => "SSH moves to Tailscale.",
            1 => $"SSH moves to Tailscale. Port {ports[0]} stays open.",
            _ => $"SSH moves to Tailscale. Ports {Spoken(ports.Select(p => p.ToString(CultureInfo.InvariantCulture)).ToList(), "and")} stay open.",
        };
    }

    // ------------------------------------------------------------ the words

    /// <summary>The words of a user that cannot become root.</summary>
    public static string NotRoot(string user) =>
        $"The user {user} is not root on that server. Give a user that is root, or that can become root.";

    /// <summary>A server that SSH did not reach, in the words of no particular way.</summary>
    public static string Unreached(string server) => $"This PC could not reach {server} over SSH.";

    /// <summary>A server that took the connection and printed no reading.</summary>
    public static string NoAnswer(string server) => $"{server} did not answer the check. Give a user that can run commands there.";

    /// <summary>**A server whose host key is not the one this PC kept for it** (windows-app-plan-v2.md, 5.5): the Mac
    /// sends the owner to a console (<c>ssh-keygen -R</c>), and the PC has none. In the first run the way out is Start
    /// again; after it, the removal of the server and its add again. New words of the PC (set 8).</summary>
    public static string HostKeyChanged(string server, bool firstRun) => firstRun
        ? $"{server} answers with another host key than this PC knows. If the server was rebuilt, start again."
        : $"{server} answers with another host key than this PC knows. If the server was rebuilt, remove it and add it again.";

    /// <summary>**A server that has no host key on this PC's record**, under the rule that takes known servers only: the
    /// PC lost its record of the server, or never added it. The way out is the one of a changed key. New words of the PC
    /// (set 8).</summary>
    public static string HostKeyUnknown(string server, bool firstRun) => firstRun
        ? $"This PC has no host key on record for {server}. Start again."
        : $"This PC has no host key on record for {server}. Remove the server and add it again.";

    /// <summary>**A server that did not take the app's own key** (the Mac's keyRefused says "Choose its key", and the PC
    /// has no key to choose): the way out is the password once, which puts the key there again. New words of the PC
    /// (set 8).</summary>
    public static string KeyRefused(string server) => $"{server} did not take this PC's SSH key. Check the server again.";

    /// <summary>A password to a server that takes keys only (the Mac's PasswordOnce.refusal): its second sentence names the
    /// step's own way in, the owner's key once (the owner's "Choose key, as Mac" of 21 November 2026, and his words for
    /// set 8: "… Choose its key." in place of the Mac's "Give it this Mac's key at your provider").</summary>
    public static string KeysOnly(string server) =>
        $"{server} takes SSH keys only, so a password cannot open it. Choose its key.";

    /// <summary>A password that the server did not take (the Mac's PasswordOnce.refusal).</summary>
    public static string PasswordRefused(string server, string user) => $"{server} did not take that password for {user}.";

    /// <summary>Where the owner's Tailscale policy is kept, for the words of a server on the private network that did
    /// not answer (the Mac's PolicyPlace, which the piece of Tailscale's API keeps): at an address, by another tool, or
    /// not known (null).</summary>
    public sealed record PolicyPlace(string? Address, bool Tool);

    /// <summary>**Why a call did not reach a server, as the Mac says it** (ServerCheck.unreached(_:said:) and
    /// FleetReach.dropped), from the way IRemote failed: a name not found, a port that refused, a port that did not
    /// answer (on the private network, a policy that does not let this PC in), a server that closed the connection
    /// before any login. A connection that broke, and anything else, is a server that SSH did not reach.</summary>
    public static string Unreached(string server, int port, RemoteFailure failure, PolicyPlace? policy = null)
    {
        var p = port.ToString(CultureInfo.InvariantCulture);
        return failure switch
        {
            RemoteFailure.NotFound => $"This PC could not find {server}. Check its address.",
            RemoteFailure.Refused => $"{server} refused SSH on port {p}. Check that SSH runs on that port and lets this PC in.",
            RemoteFailure.NoAnswer when ClaimCode.IsPrivateAddress(server) => Dropped(server, p, policy),
            RemoteFailure.NoAnswer => $"{server} did not answer SSH on port {p}. Check that the server is on and that its firewall lets SSH in.",
            RemoteFailure.Closed => $"{server} closed the SSH connection before any login. Check that it lets this PC in.",
            _ => Unreached(server),
        };
    }

    /// <summary>A server that did not answer SSH at its address on the private network, where the policy decides what
    /// arrives (the Mac's FleetReach.unreached).</summary>
    private static string Dropped(string server, string port, PolicyPlace? policy)
    {
        var ports = "tcp:" + port;
        if (policy?.Address is { } address)
            return $"{server} did not answer SSH on port {port}. Check that the server is on, and that your Tailscale policy in {address} lets this PC reach it on {ports}.";
        if (policy?.Tool == true)
            return $"{server} did not answer SSH on port {port}. Check that the server is on, and that your Tailscale policy, which another tool keeps, lets this PC reach it on {ports}.";
        return $"{server} did not answer SSH on port {port}. Check that the server is on, and that your Tailscale policy lets this PC reach it on {ports}.";
    }

    /// <summary>**The words of one failure of IRemote**, for a step that stopped or a check that did not run: the ways
    /// of not reaching a server (<see cref="Unreached(string, int, RemoteFailure, PolicyPlace?)"/>), the host key, and
    /// the login.</summary>
    public static string Failed(string server, int port, string user, RemoteFailure failure, RemoteLogin login, bool firstRun,
                                PolicyPlace? policy = null) => failure switch
    {
        RemoteFailure.HostKeyChanged => HostKeyChanged(server, firstRun),
        RemoteFailure.HostKeyUnknown => HostKeyUnknown(server, firstRun),
        RemoteFailure.LoginRefused when login is RemoteLogin.PasswordOnce => PasswordRefused(server, user),
        RemoteFailure.LoginRefused => KeyRefused(server),
        RemoteFailure.LoginNotOffered => KeysOnly(server),
        _ => Unreached(server, port, failure, policy),
    };

    /// <summary>"80 and 443", "github.com, claude.ai or chatgpt.com".</summary>
    internal static string Spoken(IReadOnlyList<string> items, string last) =>
        items.Count > 1 ? string.Join(", ", items.Take(items.Count - 1)) + $" {last} " + items[^1] : items.FirstOrDefault() ?? "";

    /// <summary>"640 MB", "1.9 GB": a size as a server's page says one (the Mac's LoadWords.memory), the fraction in
    /// this PC's own numbers.</summary>
    internal static string Size(int megabytes)
    {
        double mb = Math.Max(megabytes, 0);
        if (Math.Round(mb, MidpointRounding.AwayFromZero) < 1000)
            return ((int)Math.Round(mb, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture) + " MB";
        return (mb / 1024).ToString("N1", CultureInfo.CurrentCulture) + " GB";
    }

    /// <summary>"4 GB": the memory of a plan in the round figure it is sold by.</summary>
    internal static string RoundGigabytes(int? megabytes) =>
        megabytes is { } mb
            ? Math.Max(1, (int)Math.Round(mb / 1024.0, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture) + " GB"
            : "memory not read";

    // ------------------------------------------------------------ one check of one server

    /// <summary>**Whether a password can open a server**, by the ways that it named with a refusal (SSH's names): the
    /// password method, or keyboard-interactive (PAM's prompt, which the Mac's <c>ssh</c> asks first and which
    /// <see cref="RemoteLogin.PasswordOnce"/> answers). A server that named no way may still take one, so it is asked.</summary>
    internal static bool TakesPassword(IReadOnlyList<string>? ways) =>
        ways is not { Count: > 0 } || ways.Contains("password", StringComparer.Ordinal) ||
        ways.Contains("keyboard-interactive", StringComparer.Ordinal);

    /// <summary>One check and what it read: null when the server could not be read at all.</summary>
    public sealed record Result(Verdict Verdict, Reading? Reading);

    /// <summary>The longest that one check takes (the Mac's 120 seconds).</summary>
    internal static readonly TimeSpan Limit = TimeSpan.FromSeconds(120);

    /// <summary>**One check of one server**: one SSH session as the login user, with the script on standard input, under
    /// the host key rule of an install (a new server's key is kept). Where the call failed, its words say why: a server
    /// not reached, another host key, and a login refused. **The app's own key refused** asks for the way in by the ways
    /// that the server named with its refusal (<see cref="RemoteResult.LoginWays"/>; piece L4c): a password way among
    /// them, or no list, asks for the password once (<see cref="PasswordNeed.Ssh"/>), whose page also takes the owner's
    /// key; ways with no password way are <see cref="Verdict.KeysOnly"/> at once, with no password try. The list chooses
    /// the verdict and nothing else: a password that such a server then refuses says its own sentence, as before.
    /// <paramref name="firstRun"/> chooses the words of a changed host key.</summary>
    public static async Task<Result> RunAsync(IRemote remote, InstallTarget target, InstallJob job, RemoteLogin login,
                                              bool holdsSudoPassword = false, string? tailnet = null, bool firstRun = true,
                                              PolicyPlace? policy = null, CancellationToken cancel = default)
    {
        var input = Encoding.UTF8.GetBytes(Script);
        var call = new RemoteCall(target.Remote, InstallPlan.Command("/bin/sh -s", target, Runs.Login), input, login,
                                  HostKeyRule.TakeNew, RemoteCall.ConnectTimeout) { Limit = Limit };
        var answer = await remote.RunAsync(call, null, cancel);
        if (answer.Failure == RemoteFailure.Canceled) throw new OperationCanceledException(cancel);
        if (answer.Failure == RemoteFailure.LoginRefused && login is RemoteLogin.AppKey)
            return new Result(TakesPassword(answer.LoginWays) ? new Verdict.NeedsPassword(PasswordNeed.Ssh)
                                                              : new Verdict.KeysOnly(KeysOnly(target.Host)), null);
        if (answer.Failure is { } failure)
            return new Result(new Verdict.Stop(Failed(target.Host, target.Port, target.User, failure, login, firstRun, policy)), null);
        if (Read(answer.Output) is not { } reading) return new Result(new Verdict.Stop(NoAnswer(target.Host)), null);
        return new Result(VerdictOf(reading, job, target.Port, holdsSudoPassword, tailnet), reading);
    }
}
