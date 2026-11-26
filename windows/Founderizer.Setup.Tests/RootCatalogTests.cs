using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Founderizer.Setup.RootJobs;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The sentences that the root jobs copy from the Mac's view files stay the Mac's** (piece L6): the two files of
/// the Mac that hold them (the vault's section and its install) are view files, so no writer reaches them; a test holds each
/// to the Mac's own string catalog, with "PC" for "Mac" (rule 14). The bug: a Mac lane that changes a sentence, and the PC
/// that keeps the old words.</summary>
[TestClass]
public sealed class RootCatalogTests
{
    [TestMethod]
    public void Each_sentence_of_the_root_jobs_is_in_the_Macs_catalog()
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "catalog", "Localizable.xcstrings")));
        var keys = document.RootElement.GetProperty("strings").EnumerateObject().Select(p => p.Name).ToHashSet(StringComparer.Ordinal);
        var pcKeys = keys.Select(Vectors.Pc).ToHashSet(StringComparer.Ordinal);
        var texts = new List<(string Where, string Text)>
        {
            ("TailscaleSaysOther", VaultPins.TailscaleSaysOther("%@", "%@")), ("OtherVaultKey", VaultPins.OtherVaultKey("%@")),
            ("CannotRead", VaultPins.CannotRead("%@", "%@")), ("ItsVaultKey", VaultPins.ItsVaultKey),
            ("GaveNoReason", VaultInstall.GaveNoReason), ("NoKeyToRead", VaultInstall.NoKeyToRead),
            ("NoConnection", VaultPins.NoConnection("%@")),
        };
        var missing = texts.Where(t => !keys.Contains(t.Text) && !pcKeys.Contains(t.Text)).Select(t => $"{t.Where}: \"{t.Text}\"").ToList();
        Assert.AreEqual(0, missing.Count, "not in the Mac's catalog:\n" + string.Join("\n", missing));
    }
}
