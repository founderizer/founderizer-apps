using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Windows.Tests;

/// <summary>The owner key on this PC (windows-app-plan-v2.md, piece U4, and section 5.4): in the TPM, and a software key
/// only where this PC's TPM gives none. Each test keeps its box in a folder of its own, through Windows' protection of the
/// user's data as the app's box does, and takes its keys away at its end, in the TPM too.
///
/// <c>FOUNDERIZER_TPM_TESTS</c> says what the machine has, from a fact outside the code under test (the Azure lanes'
/// <c>cloud.sh test</c> reads it from Azure: the machine's vTPM): <c>1</c>, a TPM, so a test that needs one fails when
/// the TPM gives no key (a wrong provider or a property that a real TPM refuses cannot pass as "no TPM here"); <c>0</c>,
/// no TPM, so the test of this PC's own absent TPM runs with the real provider. Not set, the tests that depend on the
/// machine fail and say to set it.</summary>
[TestClass]
public sealed class TpmOwnerKeyTests
{
    private const string Statement = "{\"fleet\":\"0123456789abcdef\",\"kind\":\"pin\",\"machine\":\"build-1\"}";
    /// <summary>A provider that no PC has.</summary>
    private const string NoProvider = "Founderizer test: no such key storage provider";

    // The codes, written here and not read from the lists under test.
    private const int DeviceNotReady = unchecked((int)0x80090030);      // NTE_DEVICE_NOT_READY (CNG, also with no TPM)
    private const int NotSupported = unchecked((int)0x80090029);        // NTE_NOT_SUPPORTED
    private const int StatusNotFound = unchecked((int)0xC0000225);      // STATUS_NOT_FOUND (no such provider, measured)
    private const int ProviderDllNotFound = unchecked((int)0x8009001E); // NTE_PROV_DLL_NOT_FOUND
    private const int TpmNotFound = unchecked((int)0x8028400F);         // TBS_E_TPM_NOT_FOUND (no TPM, measured)
    private const int ServiceDisabled = unchecked((int)0x80284010);     // TBS_E_SERVICE_DISABLED
    private const int ServiceStartPending = unchecked((int)0x8028400B); // TBS_E_SERVICE_START_PENDING
    private const int ServiceNotRunning = unchecked((int)0x80284008);   // TBS_E_SERVICE_NOT_RUNNING
    private const int Lockout = unchecked((int)0x80280921);             // TPM_20_E_LOCKOUT
    private const uint Tpm12 = 1, Tpm20 = 2;

    public TestContext TestContext { get; set; } = null!;

    private string folder = "";
    private string fleet = "";

    [TestInitialize]
    public void MakeFolder()
    {
        folder = Path.Combine(Path.GetTempPath(), "founderizer-owner-key-" + Guid.NewGuid().ToString("N"));
        fleet = NewFleet();
    }

    [TestCleanup]
    public void RemoveKeys()
    {
        try { if (Directory.Exists(folder)) foreach (var each in Fleets()) new OwnerKeys(Box()).Remove(each); }
        finally { if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true); }
    }

    /// <summary>What FOUNDERIZER_TPM_TESTS says the machine has: true, a TPM; false, none. Not set, the test fails.</summary>
    private static bool MachineHasTpm()
    {
        switch (Environment.GetEnvironmentVariable("FOUNDERIZER_TPM_TESTS"))
        {
            case "1": return true;
            case "0": return false;
            default:
                Assert.Fail("set FOUNDERIZER_TPM_TESTS to 1 on a machine with a TPM, or to 0 on one with none " +
                            "(cloud.sh test sets it from Azure's own fact of the machine)");
                return false;
        }
    }

    private static string NewFleet() => Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();

    /// <summary>Each fleet that has a value in this test's box.</summary>
    private string[] Fleets() =>
        Directory.Exists(Path.Combine(folder, "owner-key"))
            ? Directory.GetFiles(Path.Combine(folder, "owner-key")).Select(f => Path.GetFileName(f)).OfType<string>()
                       .Where(n => !n.StartsWith('.')).ToArray()
            : [];

    /// <summary>A new box over the same folder, as a later start of the app opens it.</summary>
    private FileSecretBox Box() => new(folder, new UserKeyProtection("Founderizer for Windows: test of the owner key"));

    /// <summary>A stand-in of the TPM that fails with this code.</summary>
    private static Func<string, CngKeyCreationParameters, CngKey> Failing(int code, int wait = 0) => (_, _) =>
    {
        if (wait > 0) Thread.Sleep(wait);
        throw new CryptographicException(code);
    };

    /// <summary>A stand-in of TBS that says this code and TPM version.</summary>
    private static Func<(int Code, uint Version)> Says(int code, uint version = 0) => () => (code, version);

    /// <summary>The OwnerKeys of a PC with no TPM, as measured: CNG says NTE_DEVICE_NOT_READY, TBS says TBS_E_TPM_NOT_FOUND.</summary>
    private OwnerKeys NoTpmHere(int wait = 0) => new(Box(), create: Failing(DeviceNotReady, wait), tbs: Says(TpmNotFound));

    private static TpmOwnerKey InTheTpm(IOwnerKey key, OwnerKeys keys)
    {
        if (key is TpmOwnerKey tpm) return tpm;
        (key as IDisposable)?.Dispose();
        var why = $"this PC's TPM gave no key (CNG, TBS, version: {keys.TpmCodes})";
        if (MachineHasTpm()) Assert.Fail(why + ", and FOUNDERIZER_TPM_TESTS=1 says that it has a TPM");
        Assert.Inconclusive(why + ": FOUNDERIZER_TPM_TESTS=0, and this test needs a TPM");
        throw new InvalidOperationException();
    }

    /// <summary>Bug: the TPM's signature goes out as r and s (CNG's own form), the public half is not the point of the key
    /// that signs, or the key is the machine's, asks for a prompt or can be exported: the central vault refuses every pin
    /// of this PC, or the key is not the owner's alone. 32 statements, so that each run meets an r or s whose high bit is
    /// set (the DER form then needs a zero byte).</summary>
    [TestMethod]
    public void TheTpmKeysSignatureVerifiesWithOwnerSignatureVerify()
    {
        MachineHasTpm();
        var keys = new OwnerKeys(Box());
        using var key = InTheTpm(keys.Make(fleet), keys);
        Assert.AreEqual(TpmOwnerKey.Provider, key.ProviderName);
        Assert.AreEqual(CngExportPolicies.None, key.ExportPolicy, "the private half never leaves the TPM");
        Assert.AreEqual(CngUIProtectionLevels.None, key.Prompt, "no prompt");
        Assert.IsFalse(key.IsMachineKey, "this Windows user's key, not the machine's");
        for (int i = 0; i < 32; i++)
        {
            var statement = Statement + i;
            var signature = key.Sign(statement);
            Assert.IsTrue(OwnerSignature.Verify(key.PublicKey, statement, signature), statement);
            Assert.IsFalse(OwnerSignature.Verify(key.PublicKey, statement.Replace("build-1", "build-2"), signature));
        }
    }

    /// <summary>Bug: a later start does not find the key that the first one made (the box names another key than the
    /// TPM holds, or a start makes a key of its own): the vault holds the public half of a key that no start signs with.</summary>
    [TestMethod]
    public void ASecondStartFindsTheSameKey()
    {
        MachineHasTpm();
        var keys = new OwnerKeys(Box());
        string publicKey;
        using (var first = InTheTpm(keys.Make(fleet), keys))
            publicKey = first.PublicKey;
        var again = new OwnerKeys(Box()).Key(fleet);
        Assert.AreEqual(OwnerKeyState.Held, again.State, again.Why);
        using var tpm = (TpmOwnerKey)again.Key!;
        Assert.AreEqual(publicKey, tpm.PublicKey);
        Assert.IsTrue(OwnerSignature.Verify(publicKey, Statement, tpm.Sign(Statement)));
    }

    /// <summary>Bug: a PC with no TPM (CNG's NTE_DEVICE_NOT_READY with TBS's TBS_E_TPM_NOT_FOUND, as measured) gets no
    /// owner key at all, or one that a later start does not find: its owner can never pin a machine or keep a recovery key.</summary>
    [TestMethod]
    public void APcWithNoTpmGetsTheSoftwareKey()
    {
        var keys = NoTpmHere();
        var made = keys.Make(fleet);
        Assert.IsInstanceOfType<SoftwareOwnerKey>(made);
        Assert.AreEqual(TpmNotFound, keys.SoftwareBecause);
        var publicKey = made.PublicKey;
        Assert.IsTrue(OwnerSignature.Verify(publicKey, Statement, made.Sign(Statement)));
        ((IDisposable)made).Dispose();
        var again = new OwnerKeys(Box()).Key(fleet);
        Assert.AreEqual(OwnerKeyState.Held, again.State, again.Why);
        Assert.IsInstanceOfType<SoftwareOwnerKey>(again.Key);
        Assert.AreEqual(publicKey, again.Key!.PublicKey);
        Assert.IsTrue(OwnerSignature.Verify(publicKey, Statement, again.Key.Sign(Statement)));
        ((IDisposable)again.Key).Dispose();
    }

    /// <summary>Bug: a PC whose TPM gives no P-256 key is not seen as one, so it gets no owner key. Each case of the rule
    /// gives the software key: no such provider; NTE_DEVICE_NOT_READY with no TPM or its services turned off; a TPM 1.2.</summary>
    [TestMethod]
    public void EachPcWhoseTpmGivesNoKeyGetsTheSoftwareKey()
    {
        foreach (var (cng, tbs, version, because) in new[]
        {
            (StatusNotFound, 0, Tpm20, StatusNotFound),
            (ProviderDllNotFound, 0, Tpm20, ProviderDllNotFound),
            (DeviceNotReady, TpmNotFound, 0u, TpmNotFound),
            (DeviceNotReady, ServiceDisabled, 0u, ServiceDisabled),
            (NotSupported, 0, Tpm12, NotSupported),
        })
        {
            var keys = new OwnerKeys(Box(), create: Failing(cng), tbs: Says(tbs, version));
            using var made = (SoftwareOwnerKey)keys.Make(NewFleet());
            Assert.AreEqual(because, keys.SoftwareBecause, $"CNG 0x{cng:x8}, TBS 0x{tbs:x8}, version {version}");
        }
        var real = new OwnerKeys(Box(), NoProvider);
        using var absent = (SoftwareOwnerKey)real.Make(NewFleet());
        TestContext.WriteLine($"a provider that this PC does not have: CNG, TBS, version {real.TpmCodes}");
    }

    /// <summary>Bug: a TPM that is not ready yet (a sign-in while TBS starts), in a lockout, or that refuses what the app
    /// asks for (NTE_NOT_SUPPORTED of a TPM 2.0) gets a software key for life, a new identity that nothing reports. Each
    /// such pair goes to the caller, and the box keeps nothing.</summary>
    [TestMethod]
    public void EveryOtherFailureGoesToTheCaller()
    {
        foreach (var (cng, tbs, version) in new[]
        {
            (DeviceNotReady, 0, Tpm20),
            (DeviceNotReady, ServiceStartPending, 0u),
            (Lockout, 0, Tpm20),
            (NotSupported, 0, Tpm20),
            (NotSupported, TpmNotFound, 0u),
            (Lockout, ServiceDisabled, 0u),
        })
        {
            var one = NewFleet();
            var keys = new OwnerKeys(Box(), create: Failing(cng), tbs: Says(tbs, version));
            var refused = Assert.ThrowsExactly<CryptographicException>(() => keys.Make(one), $"CNG 0x{cng:x8}, TBS 0x{tbs:x8}");
            Assert.AreEqual(cng, refused.HResult);
            Assert.AreEqual(OwnerKeyState.None, new OwnerKeys(Box()).Key(one).State);
        }
    }

    /// <summary>Bug: a make over a fleet that has a key, or a value that does not open, writes a new key over it (and
    /// deletes the TPM's key): the vault keeps the old public half and refuses each pin of the new key. Make throws, and
    /// the key that was there stays, in the box and in the TPM.</summary>
    [TestMethod]
    public void MakeRefusesAFleetThatHasAValue()
    {
        var keys = new OwnerKeys(Box());
        var first = keys.Make(fleet);
        var publicKey = first.PublicKey;
        (first as IDisposable)?.Dispose();
        Assert.ThrowsExactly<InvalidOperationException>(() => new OwnerKeys(Box()).Make(fleet));
        var still = new OwnerKeys(Box()).Key(fleet);
        Assert.AreEqual(OwnerKeyState.Held, still.State, still.Why);
        Assert.AreEqual(publicKey, still.Key!.PublicKey);
        Assert.IsTrue(OwnerSignature.Verify(publicKey, Statement, still.Key.Sign(Statement)));
        (still.Key as IDisposable)?.Dispose();
    }

    /// <summary>Bug: of two processes that make the key at once (two starts of the app at a first install), both write,
    /// the box keeps one key and the other's install sends its public half to the vault. The other start writes its value
    /// after this make looked at the box (the stand-in of CNG runs there): this make throws, its own new key goes (out of
    /// the TPM too, on a machine with one), and the other's stays.</summary>
    [TestMethod]
    public void OfTwoStartsThatMakeTheKeyAtOnceOneWins()
    {
        foreach (var inTheTpm in new[] { false, true })
        {
            if (inTheTpm && !MachineHasTpm()) continue;
            var one = NewFleet();
            string other = "", made = "";
            var keys = new OwnerKeys(Box(), create: (name, parameters) =>
            {
                // The other start, in full: it finds no value, makes a software key and keeps it.
                using (var key = (SoftwareOwnerKey)NoTpmHere().Make(one)) other = key.PublicKey;
                if (!inTheTpm) throw new CryptographicException(DeviceNotReady);
                made = name;
                return CngKey.Create(CngAlgorithm.ECDsaP256, name, parameters);
            }, tbs: Says(TpmNotFound));
            Assert.ThrowsExactly<InvalidOperationException>(() => keys.Make(one));
            var kept = new OwnerKeys(Box()).Key(one);
            Assert.AreEqual(OwnerKeyState.Held, kept.State, kept.Why);
            Assert.AreEqual(other, kept.Key!.PublicKey, "the other start's key stays");
            (kept.Key as IDisposable)?.Dispose();
            if (inTheTpm) Assert.IsFalse(CngKey.Exists(made, new CngProvider(TpmOwnerKey.Provider)), "this make's TPM key goes");
        }
    }

    /// <summary>Bug: a value that does not open, or a key that the TPM does not give now, reads as "no key", so the
    /// caller's "key, else make" makes a new one. It is Unavailable, and Make refuses it.</summary>
    [TestMethod]
    public void AValueThatDoesNotOpenIsUnavailableAndMakeRefusesIt()
    {
        // A file in the box's place that Windows' protection does not open.
        Directory.CreateDirectory(Path.Combine(folder, "owner-key"));
        File.WriteAllBytes(Path.Combine(folder, "owner-key", fleet), RandomNumberGenerator.GetBytes(64));
        var unopened = new OwnerKeys(Box()).Key(fleet);
        Assert.AreEqual(OwnerKeyState.Unavailable, unopened.State);
        Assert.ThrowsExactly<InvalidOperationException>(() => new OwnerKeys(Box()).Make(fleet));

        // A value that names a key of the TPM, read where that storage does not answer.
        var other = NewFleet();
        using var point = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        Box().Write(OwnerKeys.Name(other), Encoding.UTF8.GetBytes(
            $"tpm\nFounderizer owner key {other} 00000000\n{OwnerKeys.Point(point.ExportParameters(false))}\n"));
        var silent = new OwnerKeys(Box(), NoProvider).Key(other);
        Assert.AreEqual(OwnerKeyState.Unavailable, silent.State, $"code 0x{silent.Code:x8}");
        Assert.ThrowsExactly<InvalidOperationException>(() => new OwnerKeys(Box(), NoProvider).Make(other));
        Box().Remove(OwnerKeys.Name(other));
    }

    /// <summary>Bug: a key that the provider says it does not have (NTE_BAD_KEYSET; here the key was deleted) reads as
    /// "not now" or as "no key": the first hides that it must be made again, the second lets a make write over the box.
    /// It is Gone. What a clear of the TPM gives is not measured.</summary>
    [TestMethod]
    public void AKeyThatTheProviderDoesNotHaveIsGone()
    {
        MachineHasTpm();
        var keys = new OwnerKeys(Box());
        using (var made = InTheTpm(keys.Make(fleet), keys))
        {
            using var same = CngKey.Open(made.Name, new CngProvider(TpmOwnerKey.Provider));
            same.Delete();
        }
        var gone = new OwnerKeys(Box()).Key(fleet);
        Assert.AreEqual(OwnerKeyState.Gone, gone.State, gone.Why);
        Assert.ThrowsExactly<InvalidOperationException>(() => new OwnerKeys(Box()).Make(fleet));
    }

    /// <summary>Bug: two callers of one start see no key at the same time, and both make one: one key is written over,
    /// and the vault gets the public half of the other. One make wins, the other is refused.</summary>
    [TestMethod]
    public void TwoMakesAtOnceMakeOneKey()
    {
        var tries = Enumerable.Range(0, 2).Select(_ => Task.Run(() =>
        {
            try { return (IOwnerKey?)NoTpmHere(wait: 300).Make(fleet); }
            catch (InvalidOperationException) { return null; }
        })).ToArray();
        Task.WaitAll(tries);
        var made = tries.Select(t => t.Result).Where(k => k is not null).ToArray();
        Assert.AreEqual(1, made.Length, "one make wins");
        var kept = new OwnerKeys(Box()).Key(fleet);
        Assert.AreEqual(made[0]!.PublicKey, kept.Key!.PublicKey);
        foreach (var key in made) (key as IDisposable)?.Dispose();
        (kept.Key as IDisposable)?.Dispose();
    }

    /// <summary>On a machine with no TPM (FOUNDERIZER_TPM_TESTS=0), the real provider and the real TBS: the owner key is a
    /// software key. Bug: the pair that a PC with no TPM gives is not in the rule.</summary>
    [TestMethod]
    public void ThisPcsAbsentTpmGivesTheSoftwareKey()
    {
        if (MachineHasTpm()) Assert.Inconclusive("only on a machine with no TPM: FOUNDERIZER_TPM_TESTS=0");
        var keys = new OwnerKeys(Box());
        var made = keys.Make(fleet);
        TestContext.WriteLine($"this PC's TPM: CNG, TBS, version {keys.TpmCodes}");
        Assert.IsInstanceOfType<SoftwareOwnerKey>(made);
        Assert.IsTrue(OwnerSignature.Verify(made.PublicKey, Statement, made.Sign(Statement)));
        ((IDisposable)made).Dispose();
    }
}
