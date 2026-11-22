using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using Founderizer.Core;
using Founderizer.Windows.Fleet;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Windows.Tests;

/// <summary>The Windows parts behind the library's interfaces: the device key under Windows' protection of the user's
/// data, and Tailscale's status from its own signed program (whose publisher check is <see cref="PublisherTests"/>'s).
/// They run on Windows.</summary>
[TestClass]
public sealed class WindowsPartsTests
{
    private static readonly byte[] DpapiHeader = Convert.FromHexString("01000000d08c9ddf0115d1118c7a00c04fc297eb");

    [TestMethod]
    public void TheKeyIsProtectedForThisUserAndOpensAgain()
    {
        var protection = new UserKeyProtection();
        var key = Encoding.UTF8.GetBytes("an-example-device-key-of-43-characters-abcd");
        var stored = protection.Protect(key);
        CollectionAssert.AreEqual(DpapiHeader, stored.Take(20).ToArray());
        Assert.IsFalse(Encoding.UTF8.GetString(stored).Contains("an-example-device-key", StringComparison.Ordinal));
        CollectionAssert.AreEqual(key, protection.Unprotect(stored));
        // Each use has its own purpose: the device key does not open as the secret box's, nor the box's as the device key.
        // The bug: one purpose for both, so a value of the box can be read as a device key, and the other way round.
        Assert.ThrowsExactly<IOException>(() => new UserKeyProtection(UserKeyProtection.SecretBox).Unprotect(stored));
        var boxed = new UserKeyProtection(UserKeyProtection.SecretBox).Protect(key);
        Assert.ThrowsExactly<IOException>(() => protection.Unprotect(boxed));
        CollectionAssert.AreEqual(key, new UserKeyProtection(UserKeyProtection.SecretBox).Unprotect(boxed));
    }

    [TestMethod]
    public void TheKeyFileHoldsNoTextAndGoesAway()
    {
        var folder = Path.Combine(Path.GetTempPath(), "fz-key-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new FileKeyStore(Path.Combine(folder, "device-key"), new UserKeyProtection());
            Assert.IsFalse(store.Has);
            store.Write("an-example-device-key");
            Assert.IsTrue(store.Has);
            var bytes = File.ReadAllBytes(store.FilePath);
            Assert.IsFalse(Encoding.UTF8.GetString(bytes).Contains("an-example-device-key", StringComparison.Ordinal));
            Assert.IsFalse(Encoding.Unicode.GetString(bytes).Contains("an-example-device-key", StringComparison.Ordinal));
            Assert.AreEqual("an-example-device-key", store.Read());
            store.Remove();
            Assert.IsFalse(store.Has);
            Assert.IsNull(store.Read());
        }
        finally
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public void AnAddressThatCannotBeAHubsIsRefusedWithTheIPhonesWords()
    {
        var folder = Path.Combine(Path.GetTempPath(), "fz-store-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new OwnerStore(new StoreSettings { Folder = folder, Keys = new MemoryKeyStore() });
            var words = store.ConnectAsync("hub.example:8765").GetAwaiter().GetResult();
            Assert.AreEqual("Enter an HTTP or HTTPS hub address without a path or login.", words);
            Assert.AreEqual(words, store.State.AddressError);
            Assert.IsTrue(store.State.HasNoHub);
            store.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        finally
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
    }

    [TestMethod]
    public void TailscalesStatusComesAsJson()
    {
        if (!File.Exists(WindowsTailscale.Program)) Assert.Inconclusive("Tailscale is not on this PC");
        var status = new WindowsTailscale().ReadAsync(CancellationToken.None).GetAwaiter().GetResult();
        Assert.IsNotNull(status);
        StringAssert.StartsWith(status.TrimStart(), "{");
        StringAssert.Contains(status, "BackendState");
    }

    /// <summary>**A write to the clipboard that Windows refuses copies nothing and ends nothing** (the read of U3: the app
    /// catches no exception of its window's thread). Another program that holds the clipboard open makes Windows refuse a
    /// write with CLIPBRD_E_CANT_OPEN, as a COMException; a refusal of access comes as another exception. The bug: a Copy
    /// that ends the app, or one that says Copied for nothing.</summary>
    [TestMethod]
    public void AClipboardWriteThatWindowsRefusesCopiesNothingAndEndsNothing()
    {
        const int cannotOpen = unchecked((int)0x800401D0);
        Assert.IsFalse(ClipboardGuard.Write(() => throw new System.Runtime.InteropServices.COMException("OpenClipboard failed", cannotOpen)));
        Assert.IsFalse(ClipboardGuard.Write(() => throw new UnauthorizedAccessException()));
        Assert.IsFalse(ClipboardGuard.Write(() => false), "Windows did not take a code with its options");
        Assert.IsTrue(ClipboardGuard.Write(() => true));
    }
}
