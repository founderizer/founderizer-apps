using System;
using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Founderizer.Install;
using Founderizer.Windows.Fleet;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Windows.Tests;

/// <summary>**The check of a program of another company before it runs** (windows-app-plan-v2.md, 8.2; piece U1):
/// <see cref="Publisher.SignedBy(string, string, string)"/> passes only a file whose signature Windows finds valid, with
/// the revocation of the whole chain, signed by exactly the organisation and the country that the caller names.
/// Tailscale's installer runs with an administrator's rights after this check, so each way of passing a file that is not
/// Tailscale's is a test here. They run on Windows, with the network for the revocation check.</summary>
[TestClass]
public sealed class PublisherTests
{
    private string scratch = "";

    [TestInitialize]
    public void MakeScratch()
    {
        scratch = Path.Combine(Path.GetTempPath(), "founderizer-publisher-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(scratch);
    }

    [TestCleanup]
    public void RemoveScratch() => Directory.Delete(scratch, recursive: true);

    /// <summary>A file that Microsoft signed (.NET's own library, which runs these tests): a valid signature of another
    /// publisher than Tailscale.</summary>
    private static string Microsofts => typeof(object).Assembly.Location;

    /// <summary>The bug: a check of the signature alone, which passes any signed program as Tailscale's installer.</summary>
    [TestMethod]
    public void AFileWithAValidSignatureOfAnotherPublisherIsRefused()
    {
        Assert.IsTrue(Publisher.SignatureIsValid(Microsofts), "the reference file carries a valid signature");
        Assert.IsFalse(Publisher.SignedBy(Microsofts, Signer.Organisation, Signer.Country));
        // The same check passes the publisher that did sign it: the refusal is the publisher's, not a check that fails.
        Assert.IsTrue(Publisher.SignedBy(Microsofts, "Microsoft Corporation", "US"));
    }

    /// <summary>The bug: a file with no signature at all read as one that names nobody wrong.</summary>
    [TestMethod]
    public void AnUnsignedFileIsRefused()
    {
        var file = Path.Combine(scratch, "tailscale-setup-1.104.7-arm64.msi");
        File.WriteAllBytes(file, RandomNumberGenerator.GetBytes(4096));
        Assert.IsFalse(Publisher.SignedBy(file, Signer.Organisation, Signer.Country));
    }

    /// <summary>The bug: the signer read from the file's signature with no check of the file's hash (a changed installer
    /// keeps its old signature block).</summary>
    [TestMethod]
    public void ASignedFileChangedByOneByteIsRefused()
    {
        var same = Path.Combine(scratch, "same.dll");
        var changed = Path.Combine(scratch, "changed.dll");
        var bytes = File.ReadAllBytes(Microsofts);
        File.WriteAllBytes(same, bytes);
        bytes[bytes.Length / 3] ^= 0x01;
        File.WriteAllBytes(changed, bytes);
        Assert.IsTrue(Publisher.SignedBy(same, "Microsoft Corporation", "US"), "a copy as it is passes");
        Assert.IsFalse(Publisher.SignedBy(changed, "Microsoft Corporation", "US"));
    }

    /// <summary>The bug: an organisation or a country matched as a part of the signer's name (step 1 read
    /// <c>Subject.Contains("O=Tailscale Inc.")</c>, which "Tailscale Inc. Evil" passes), or a signer with a second
    /// organisation, or with none of the two.</summary>
    [TestMethod]
    public void TheSignerNamesExactlyThatOrganisationAndCountry()
    {
        foreach (var (subject, takes) in new[]
        {
            ("CN=Tailscale Inc., O=Tailscale Inc., L=Toronto, S=Ontario, C=CA", true),
            ("CN=Tailscale Inc., O=Tailscale Inc. Evil, C=CA", false),
            ("CN=Tailscale Inc., O=tailscale inc., C=CA", false),
            ("CN=Tailscale Inc., O=Tailscale Inc., C=US", false),
            ("CN=Tailscale Inc., C=CA", false),
            ("CN=Tailscale Inc., O=Tailscale Inc.", false),
            ("CN=Tailscale Inc., O=Tailscale Inc., O=Another Inc., C=CA", false),
        })
        {
            using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var request = new CertificateRequest(subject, key, HashAlgorithmName.SHA256);
            using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
            Assert.AreEqual(takes, Publisher.Names(certificate, Signer.Organisation, Signer.Country), subject);
        }
    }

    /// <summary>Tailscale's own program passes the same check (the status read and the sign-in run it), and Windows' own
    /// program does not.</summary>
    [TestMethod]
    public void TailscalesOwnProgramPassesAndWindowsOwnDoesNot()
    {
        if (!File.Exists(WindowsTailscale.Program)) Assert.Inconclusive("Tailscale is not on this PC");
        Assert.IsTrue(Publisher.SignedBy(WindowsTailscale.Program, Signer.Organisation, Signer.Country));
        Assert.IsTrue(new WindowsTailscale().IsTailscales());
        var notepad = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "notepad.exe");
        if (File.Exists(notepad)) Assert.IsFalse(Publisher.SignedBy(notepad, Signer.Organisation, Signer.Country));
    }
}
