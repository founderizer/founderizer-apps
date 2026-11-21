namespace Founderizer.Remote;

/// <summary>What the file that the owner picked is, before any connection (plan 5.5, "The owner's key, once").</summary>
public enum OwnerKeyCheck
{
    /// <summary>A private key that the app can use: with no passphrase, or opened with the passphrase given.</summary>
    Usable,
    /// <summary>
    /// Not a private key that the app reads: another file, a public key, a damaged key, a key of a format or a type
    /// that the app does not read, or a file over <see cref="OwnerKeyFile.MaxLength"/>.
    /// </summary>
    NotAKey,
    /// <summary>A private key with a passphrase, and none was given: the step asks for it in one field.</summary>
    NeedsPassphrase,
    /// <summary>A private key with a passphrase, and the passphrase given does not open it.</summary>
    WrongPassphrase,
}

/// <summary>
/// **The owner's key file, checked before any connection**, so that a wrong file or a wrong passphrase costs no login
/// try at the server. The formats: OpenSSH's own (<c>-----BEGIN OPENSSH PRIVATE KEY-----</c>, what <c>ssh-keygen</c>
/// writes), PEM (PKCS#1 <c>RSA PRIVATE KEY</c>, SEC 1 <c>EC PRIVATE KEY</c>, PKCS#8 <c>PRIVATE KEY</c> and
/// <c>ENCRYPTED PRIVATE KEY</c>), and PuTTY's <c>.ppk</c> (versions 2 and 3); the types Ed25519, ECDSA and RSA. The
/// tests prove each with a key that <c>ssh-keygen</c> or <c>puttygen</c> makes. A key that opens is also made to sign
/// and its signature checked, so a damaged key, or one that a wrong passphrase seemed to open, is no key.
///
/// The check keeps nothing and changes neither array: the caller gives the same two to
/// <see cref="RemoteLogin.KeyOnce"/>, which clears them. It never throws for a file's content, and no exception or
/// text of it holds the key or the passphrase.
/// </summary>
public static class OwnerKeyFile
{
    /// <summary>The longest file that the window reads and the check takes: 64 KiB (a 16384-bit RSA key is 13 KiB).</summary>
    public const int MaxLength = 64 * 1024;

    /// <summary>What the file is. <c>passphrase</c> is null, or empty, when the owner gave none.</summary>
    public static OwnerKeyCheck Check(byte[]? file, char[]? passphrase)
    {
        var state = SshRemote.OpenOwnerKey(file, passphrase, out var key);
        key?.Dispose();
        return state;
    }
}
