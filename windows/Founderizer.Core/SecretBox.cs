using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Founderizer.Core;

/// <summary>The one box of each secret at rest on this PC (windows-app-plan-v2.md, rule 15 and section 5.4): the key of
/// the owner's computer, and later the app's SSH key, the fleet's Tailscale client, a provider's token, the recovery
/// code and the owner access key. A name is one or more parts of small letters, digits, ".", "_" and "-", joined by "/"
/// (<see cref="SecretNames.IsName"/>), as <c>owner-keys/100.64.0.9_8765</c>. <see cref="Read"/> gives null for a name that holds
/// nothing, and throws when a kept value does not open. No value goes into a log, an address or a message.</summary>
public interface ISecretBox
{
    byte[]? Read(string name);
    void Write(string name, byte[] value);
    /// <summary>Takes the value of a name away. A name that holds nothing is no error.</summary>
    void Remove(string name);

    /// <summary>**Writes the value only where the name holds none**, in one step for every process that writes the box:
    /// true when it wrote, false (and nothing written) when the name holds a value, also one that does not open. A box
    /// that cannot do it in one step reads first and then writes.</summary>
    bool WriteNew(string name, byte[] value)
    {
        try
        {
            if (Read(name) is { } held)
            {
                CryptographicOperations.ZeroMemory(held);
                return false;
            }
        }
        catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException)
        {
            return false;
        }
        Write(name, value);
        return true;
    }
}

/// <summary>The rule of the names of a box.</summary>
public static partial class SecretNames
{
    /// <summary>One or more parts of 1 to 100 small letters, digits, ".", "_" and "-", joined by "/": no part is "." or
    /// "..", and no part starts with ".", so a name never leaves its folder and never names a file that the box writes
    /// for itself.</summary>
    public static bool IsName(string name) => name.Length <= 200 && Name().IsMatch(name);

    [GeneratedRegex(@"\A[a-z0-9_-][a-z0-9._-]{0,99}(/[a-z0-9_-][a-z0-9._-]{0,99})*\z", RegexOptions.CultureInvariant)]
    private static partial Regex Name();

    internal static string Checked(string name) =>
        IsName(name) ? name : throw new ArgumentException("not the name of a secret: small letters, digits, '.', '_', '-' and '/'", nameof(name));
}

/// <summary>A box in memory, for the tests and for a run that keeps nothing.</summary>
public sealed class MemorySecretBox : ISecretBox
{
    private readonly Dictionary<string, byte[]> values = new(StringComparer.Ordinal);
    private readonly object gate = new();

    public byte[]? Read(string name)
    {
        lock (gate) return values.TryGetValue(SecretNames.Checked(name), out var value) ? (byte[])value.Clone() : null;
    }

    public void Write(string name, byte[] value)
    {
        lock (gate) values[SecretNames.Checked(name)] = (byte[])value.Clone();
    }

    public void Remove(string name)
    {
        lock (gate) values.Remove(SecretNames.Checked(name));
    }

    public bool WriteNew(string name, byte[] value)
    {
        lock (gate) return values.TryAdd(SecretNames.Checked(name), (byte[])value.Clone());
    }
}

/// <summary>The box as files under one folder (on Windows <c>%LOCALAPPDATA%\Founderizer\keys</c>), each value through the
/// screens' <see cref="IKeyProtection"/>: Windows' protection of the user's data. One file for each name.
///
/// **One kept value never opens as another.** The bytes that the protection seals start with the box's mark and the
/// value's own name, and a read takes a value only when they are the name that it asked for. So a file that is copied
/// or moved to another name of the box does not open there, and a value that another part of the app protected (the
/// device key of step 1) is no value of the box. The window gives the box a protection with a purpose text of its own,
/// beside the device key's.
///
/// A file is written whole or not at all (a new file, then moved over the old one), and on a system with file modes
/// only this user may read it. The plain bytes are cleared from memory once they are sealed or read.
///
/// **What it does not guard against, as on the Mac:** a program that runs as the owner's Windows user can ask Windows
/// to open the box. The Mac binds its Keychain items to the app's signature; Windows has no such rule for an app that is
/// not packaged.</summary>
public sealed class FileSecretBox(string folder, IKeyProtection protection) : ISecretBox
{
    private static readonly byte[] Mark = Encoding.ASCII.GetBytes("founderizer-secret-box/1\n");

    public string Folder { get; } = Path.GetFullPath(folder);

    private string PathOf(string name) =>
        Path.Combine([Folder, .. SecretNames.Checked(name).Split('/')]);

    public byte[]? Read(string name)
    {
        var path = PathOf(name);
        if (!File.Exists(path)) return null;
        var plain = protection.Unprotect(File.ReadAllBytes(path));
        try
        {
            var head = Head(name);
            if (plain.Length < head.Length || !plain.AsSpan(0, head.Length).SequenceEqual(head))
                throw new CryptographicException($"the kept value of {name} is not the value of that name");
            return plain[head.Length..];
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
        }
    }

    public void Write(string name, byte[] value)
    {
        var path = PathOf(name);
        Place(path, Seal(name, value), Temporary(path), overwrite: true);
    }

    /// <summary>A new file moved into the name's place with no overwrite, so that of two processes that write a new value
    /// at once one wins and the other gets false; each writes its own temporary file.</summary>
    public bool WriteNew(string name, byte[] value)
    {
        var path = PathOf(name);
        if (File.Exists(path)) return false;
        var temporary = Path.Combine(Path.GetDirectoryName(path)!,
            "." + Path.GetFileName(path) + "." + Convert.ToHexString(RandomNumberGenerator.GetBytes(4)).ToLowerInvariant() + ".new");
        try
        {
            Place(path, Seal(name, value), temporary, overwrite: false);
            return true;
        }
        catch (IOException) when (File.Exists(path))
        {
            return false;
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    /// <summary>The bytes that the protection seals: the box's mark, the name and the value.</summary>
    private byte[] Seal(string name, byte[] value)
    {
        var head = Head(name);
        var plain = new byte[head.Length + value.Length];
        byte[] stored;
        try
        {
            head.CopyTo(plain, 0);
            value.CopyTo(plain, head.Length);
            stored = protection.Protect(plain);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
        }
        return stored;
    }

    /// <summary>The sealed bytes written whole to a temporary file, then moved to the name's place.</summary>
    private static void Place(string path, byte[] stored, string temporary, bool overwrite)
    {
        if (Path.GetDirectoryName(path) is { } parent) CreateFolder(parent);
        var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        using (var stream = new FileStream(temporary, options))
        {
            stream.Write(stored);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temporary, path, overwrite);
    }

    public void Remove(string name)
    {
        var path = PathOf(name);
        File.Delete(Temporary(path));
        File.Delete(path);
    }

    /// <summary>Where a value is written before it is moved to its place: a name that starts with ".", which no name of
    /// the box has, so it is never another name's file.</summary>
    private static string Temporary(string path) =>
        Path.Combine(Path.GetDirectoryName(path)!, "." + Path.GetFileName(path) + ".new");

    /// <summary>The box's mark and the name, before the value.</summary>
    private static byte[] Head(string name) => [.. Mark, .. Encoding.ASCII.GetBytes(name), (byte)'\n'];

    /// <summary>The box's folders, for this user alone on a system with file modes.</summary>
    private static void CreateFolder(string path)
    {
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(path);
        else Directory.CreateDirectory(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }
}
