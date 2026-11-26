using System;
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.Json;

namespace Founderizer.Remote;

/// <summary>What a server's host key is against the record.</summary>
internal enum HostKeyVerdict
{
    /// <summary>The key on record, or a key that <c>TakeNew</c> kept now.</summary>
    Trusted,
    /// <summary>No key on record, under <c>Known</c>; or a key that could not be kept.</summary>
    Unknown,
    /// <summary>Another key than the one on record, or a record that cannot be read.</summary>
    Changed,
}

/// <summary>
/// **The app's own record of each server's host key**: one file, <c>known-hosts.json</c>, in the app's folder. The
/// owner's own <c>known_hosts</c> (<c>%USERPROFILE%\.ssh</c>) is never read or changed.
///
/// One key for each server (its address as given, and its port), as one line "<c>type base64</c>". A server whose key
/// is on record must show that same key, of that same type, under either rule: the app has no way to take a changed
/// key. Only <see cref="Forget"/> (the removal of a server) and <see cref="ForgetAll"/> (start again) take a key away.
///
/// **The rule by port** (the Mac's <c>InstallTarget.hostKeyOptions</c>, the hole of 22 November 2026): a hub that is
/// broken into names a high port of a server in its record, where an agent's own small SSH server answers with a key of
/// its own. So only port 22, or a port that the owner gave for this very host (<see cref="RemoteTarget.PortIsOwners"/>),
/// has a line of its own and can keep a new key. At any other port the server must show the key of the host's port 22
/// line (the Mac's <c>HostKeyAlias</c>), under either rule, and a key that is not known there is refused: a line for
/// "<c>[host]:port</c>" is not read at all, so a key that an earlier build kept there opens nothing.
///
/// The file is written to a new file beside it and moved over it, so a reader never sees half of it. A file that is
/// there and cannot be read is no record of nothing: every server is then <see cref="HostKeyVerdict.Changed"/>, and
/// nothing is written over it, until start again removes it. So an older build that cannot read a newer file, or a
/// damaged file, never lets a server in with a key that nobody checked.
/// </summary>
public sealed class HostKeys
{
    /// <summary>The file's name in the app's folder.</summary>
    public const string FileName = "known-hosts.json";

    // One lock for each file in this process, so two SshRemote of one folder never write over each other's key: kept by
    // the whole path with no regard to case, which Windows' and macOS's file systems do not tell apart. Two locks of one
    // file let two keeps at once each write the file that they read, and the key that is lost is then taken anew from
    // whatever server answers first; one lock of two files only makes one wait for the other.
    private static readonly ConcurrentDictionary<string, object> Locks = new(StringComparer.OrdinalIgnoreCase);

    private readonly object gate;

    public HostKeys(string folder)
    {
        ArgumentException.ThrowIfNullOrEmpty(folder);
        Path = System.IO.Path.GetFullPath(System.IO.Path.Combine(folder, FileName));
        gate = Locks.GetOrAdd(Path, _ => new object());
    }

    /// <summary>The file's whole path.</summary>
    public string Path { get; }

    /// <summary>The line on record for this host and port ("<c>ssh-ed25519 AAAA…</c>"), or null.</summary>
    public string? Find(string host, int port)
    {
        lock (gate)
        {
            var read = Read();
            return read is { } hosts && hosts.TryGetValue(Name(host, port), out var line) ? line : null;
        }
    }

    /// <summary>Takes this server's key away (the server is removed). Nothing happens to a file that cannot be read.</summary>
    public void Forget(string host, int port)
    {
        lock (gate)
        {
            if (Read() is not { } hosts || !hosts.Remove(Name(host, port))) return;
            Write(hosts);
        }
    }

    /// <summary>Takes every key away (start again): the file goes.</summary>
    public void ForgetAll()
    {
        lock (gate)
        {
            File.Delete(Path);
        }
    }

    /// <summary>The key that a server at this target must show: the line of its port, or of the host's port 22 at a port
    /// that is not the owner's (<see cref="RemoteTarget.PortIsOwners"/>); null when there is none.</summary>
    public string? Find(RemoteTarget target)
    {
        ArgumentNullException.ThrowIfNull(target);
        return Find(target.Host, target.PortIsOwners ? target.Port : 22);
    }

    /// <summary>
    /// The verdict on the key that a server showed (its SSH public key blob), under the call's rule, as one step: two
    /// calls to one new server at once keep one key, and the second must show it. At a port that is not the owner's
    /// (<see cref="RemoteTarget.PortIsOwners"/>) the key must be the one of the host's port 22, and none is kept.
    /// </summary>
    internal HostKeyVerdict Check(RemoteTarget target, byte[] blob, HostKeyRule rule)
    {
        ArgumentNullException.ThrowIfNull(target);
        if (Line(blob) is not { } shown) return HostKeyVerdict.Changed;
        var owners = target.PortIsOwners;
        var name = Name(target.Host, owners ? target.Port : 22);
        lock (gate)
        {
            if (Read() is not { } hosts) return HostKeyVerdict.Changed;
            if (hosts.TryGetValue(name, out var kept))
                return string.Equals(kept, shown, StringComparison.Ordinal) ? HostKeyVerdict.Trusted : HostKeyVerdict.Changed;
            if (rule != HostKeyRule.TakeNew || !owners) return HostKeyVerdict.Unknown;
            hosts[name] = shown;
            try { Write(hosts); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return HostKeyVerdict.Unknown; }
            return HostKeyVerdict.Trusted;
        }
    }

    /// <summary>A server's name in the file: "<c>[host]:port</c>", the host in lower case (DNS names are not case-bound).</summary>
    internal static string Name(string host, int port) => "[" + host.ToLowerInvariant() + "]:" + port.ToString(System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>The key's type, the first string of its SSH blob ("<c>ssh-ed25519</c>"), or null for a blob that is not one.</summary>
    internal static string? KeyType(ReadOnlySpan<byte> blob)
    {
        if (blob.Length < 4) return null;
        var length = BinaryPrimitives.ReadUInt32BigEndian(blob);
        if (length is 0 or > 64 || length > (uint)(blob.Length - 4)) return null;
        var type = blob.Slice(4, (int)length);
        foreach (var b in type) if (b is < 0x21 or > 0x7e) return null;
        return Encoding.ASCII.GetString(type);
    }

    /// <summary>The record's line for a blob: its type, a space, its base64.</summary>
    internal static string? Line(byte[] blob) =>
        blob is { Length: > 0 and <= 16384 } && KeyType(blob) is { } type ? type + " " + Convert.ToBase64String(blob) : null;

    /// <summary>The kept keys, an empty set where there is no file, or null for a file that cannot be read.</summary>
    private Dictionary<string, string>? Read()
    {
        byte[] bytes;
        try { bytes = File.ReadAllBytes(Path); }
        catch (FileNotFoundException) { return new Dictionary<string, string>(StringComparer.Ordinal); }
        catch (DirectoryNotFoundException) { return new Dictionary<string, string>(StringComparer.Ordinal); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        try
        {
            using var document = JsonDocument.Parse(bytes);
            if (document.RootElement.ValueKind != JsonValueKind.Object
                || !document.RootElement.TryGetProperty("hosts", out var list) || list.ValueKind != JsonValueKind.Object) return null;
            var hosts = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var host in list.EnumerateObject())
            {
                if (host.Value.ValueKind != JsonValueKind.String || !host.Name.StartsWith('[')) return null;
                var line = host.Value.GetString()!;
                var space = line.IndexOf(' ');
                if (space <= 0) return null;
                byte[] blob;
                try { blob = Convert.FromBase64String(line[(space + 1)..]); } catch (FormatException) { return null; }
                if (Line(blob) != line) return null;
                hosts[host.Name] = line;
            }
            return hosts;
        }
        catch (JsonException) { return null; }
    }

    private void Write(Dictionary<string, string> hosts)
    {
        var folder = System.IO.Path.GetDirectoryName(Path)!;
        Directory.CreateDirectory(folder);
        var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
        {
            json.WriteStartObject();
            json.WriteNumber("version", 1);
            json.WriteStartObject("hosts");
            var names = new List<string>(hosts.Keys);
            names.Sort(StringComparer.Ordinal);
            foreach (var name in names) json.WriteString(name, hosts[name]);
            json.WriteEndObject();
            json.WriteEndObject();
        }
        buffer.WriteByte((byte)'\n');
        var fresh = System.IO.Path.Combine(folder, FileName + "." + Guid.NewGuid().ToString("N") + ".new");
        try
        {
            using (var file = new FileStream(fresh, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                buffer.Position = 0;
                buffer.CopyTo(file);
                file.Flush(flushToDisk: true);
            }
            File.Move(fresh, Path, overwrite: true);
        }
        finally
        {
            try { File.Delete(fresh); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
