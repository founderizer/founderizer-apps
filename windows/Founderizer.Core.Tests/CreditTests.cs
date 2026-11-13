using System;
using System.IO;
using System.Text.RegularExpressions;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The credit of Settings is FleetCore's (Credit.swift), value for value. The values are read from that file,
/// which the build copies beside the tests, so they stand in no test here.</summary>
[TestClass]
public sealed class CreditTests
{
    private static string Swift(string source, string pattern)
    {
        var match = Regex.Match(source, pattern);
        Assert.IsTrue(match.Success, pattern);
        return match.Groups[1].Value;
    }

    [TestMethod]
    public void TheCreditIsCreditSwiftsAndSettingsShowsItInThePhonesOneLine()
    {
        var source = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "sources", "Credit.swift"));
        // The line as a plain text, or (since the Spanish table of 260b2b3c1) as String(l10n:) with the name put in it:
        // its English words are the same.
        var l10n = Regex.Match(source, @"static let line = String\(l10n: ""([^""\\]*)\\\(""([^""]+)""\)([^""\\]*)""\)");
        var line = l10n.Success ? l10n.Groups[1].Value + l10n.Groups[2].Value + l10n.Groups[3].Value
                                : Swift(source, @"static let line = ""([^""]+)""");
        var handle = Swift(source, @"static let handle = ""([^""]+)""");
        var profile = Swift(source, @"static let profile = URL\(string: ""([^""]+)""\)");
        Assert.AreEqual(line, Credit.Founderizer.Line);
        Assert.AreEqual(handle, Credit.Founderizer.Handle);
        Assert.AreEqual(new Uri(profile), Credit.Founderizer.Profile);
        // Credit.oneLine: the words, a dot, and the handle, which alone is the link.
        Assert.AreEqual(line + " · ", Credit.Founderizer.Words);
        Assert.AreEqual(line + " · " + handle, Credit.Founderizer.OneLine);
        var settings = Screens.Settings(SampleFleet.State(SampleFleet.Decode(SampleFleet.Snapshot()), SampleFleet.Clock), "",
                                        SampleFleet.Clock, SampleFleet.Utc);
        Assert.AreSame(Credit.Founderizer, settings.Credit, "Settings shows Founderizer's credit unless a caller gives another");
    }
}
