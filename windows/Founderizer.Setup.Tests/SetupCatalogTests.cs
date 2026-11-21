using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
using Founderizer.Setup.Agents;
using Founderizer.Setup.Cloud;
using Founderizer.Setup.FirstRun;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Setup.Tests;

/// <summary>**The sentences that the PC's first run copies from the Mac's view files stay the Mac's** (piece L4, round 2):
/// the writer of <c>setup-words.json</c> reaches FleetCore alone, so these are held to the Mac's own string catalog,
/// <c>app/Localization/Localizable.xcstrings</c>, whose keys are the English of each <c>String(l10n:)</c> of the Mac,
/// with <c>%@</c> for each value and "Mac" where the PC says "PC" (rule 14).</summary>
[TestClass]
public sealed partial class SetupCatalogTests
{
    /// <summary>Texts of the PC that the Mac's catalog does not hold: the owner's, each with his yes (W8 of set 8; W14's
    /// field and its wrong passphrase's line, his "Yes, as shown" to picture 13d); and the PC's new words, which go to him
    /// with wave A's built pictures and are not his yet (a file that is no key, a key that the server did not take).</summary>
    private static readonly HashSet<string> OwnersOwn = [SetupScreens.AddThisPc, SetupScreens.PassphrasePlaceholder, SetupScreens.WrongPassphrase];
    private static readonly HashSet<string> NewWordsOfThePc = [SetupScreens.NotAKey, PasswordOnce.KeyNotTaken("%@", "%@")];

    private static HashSet<string> Catalog()
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "catalog", "Localizable.xcstrings")));
        return document.RootElement.GetProperty("strings").EnumerateObject().Select(p => p.Name).ToHashSet(StringComparer.Ordinal);
    }

    [GeneratedRegex(@"\]\([^)]*\)")]
    private static partial Regex Link();

    /// <summary>A text of the PC as a key of the catalog: a link's address as <c>%@</c>.</summary>
    private static string Keyed(string text) => Link().Replace(text, "](%@)");

    /// <summary>Every text that <see cref="SetupScreens"/> and the agent setup give, as the catalog's keys name them: each
    /// constant, each list of steps, each text of a function with <c>%@</c> for its values, a provider's name too.</summary>
    private static IEnumerable<(string Where, string Text)> Texts()
    {
        foreach (var field in typeof(SetupScreens).GetFields(BindingFlags.Public | BindingFlags.Static).Where(f => f.IsLiteral))
            yield return (field.Name, (string)field.GetValue(null)!);
        foreach (var field in typeof(AgentSetupModel).GetFields(BindingFlags.Public | BindingFlags.Static).Where(f => f.IsLiteral))
            yield return (field.Name, (string)field.GetValue(null)!);
        foreach (var field in typeof(SetupStore).GetFields(BindingFlags.Public | BindingFlags.Static).Where(f => f.IsLiteral))
            yield return (field.Name, (string)field.GetValue(null)!);
        yield return ("PasswordOnce.SudoRefused", PasswordOnce.SudoRefused("%@"));
        yield return ("PasswordOnce.CannotAdd", PasswordOnce.CannotAdd("%@", "%@"));
        yield return ("PasswordOnce.StillAsks", PasswordOnce.StillAsks("%@", "%@"));
        yield return ("PasswordOnce.KeyNotTaken", PasswordOnce.KeyNotTaken("%@", "%@"));
        foreach (var line in SetupScreens.KeySteps) yield return ("KeySteps", Keyed(line));
        foreach (var line in SetupScreens.HetznerMoreSteps) yield return ("HetznerMoreSteps", Keyed(line).Replace("Hetzner says yes", "%@ says yes"));
        foreach (var provider in CloudProviders.All)
        {
            var name = provider.Name();
            foreach (var line in SetupScreens.TokenSteps(provider)) yield return ("TokenSteps " + name, Keyed(line));
            yield return ("CardLine " + name, SetupScreens.CardLine(provider));
            yield return ("TokenTitle", SetupScreens.TokenTitle(provider).Replace(name, "%@"));
            yield return ("HubServerAt", SetupScreens.HubServerAt(provider).Replace(name, "%@"));
            yield return ("MakingAt", SetupScreens.MakingAt(provider).Replace(name, "%@"));
        }
        yield return ("HetznerMore", SetupScreens.HetznerMore.Replace("Hetzner", "%@"));
        foreach (var (name, text) in new[]
                 {
                     ("AiTitle", SetupScreens.AiTitle("%@")), ("AiDetail", SetupScreens.AiDetail("%@")), ("Checking", SetupScreens.Checking("%@")),
                     ("WaitingFor", SetupScreens.WaitingFor("%@")), ("PasswordFor", SetupScreens.PasswordFor("%@", "%@")),
                     ("ManagersServer", SetupScreens.ManagersServer("%@")), ("MakeManagersServer", SetupScreens.MakeManagersServer("%@")),
                     ("CannotReadServer", AgentSetupModel.CannotReadServer("%@")),
                 })
            yield return (name, text);
    }

    /// <summary>**Each copied sentence is a sentence of the Mac's catalog today**, with "PC" for "Mac". The bug: a Mac
    /// lane that changes a title or a step of the first run, and the PC that keeps the old words, unseen; or a sentence of
    /// the PC's own that has no yes of the owner.</summary>
    [TestMethod]
    public void Each_copied_sentence_is_in_the_Macs_catalog()
    {
        var keys = Catalog();
        var pcKeys = keys.Select(Vectors.Pc).ToHashSet(StringComparer.Ordinal);
        var texts = Texts().ToList();
        Assert.IsTrue(texts.Count > 70, "the test reads the texts: " + texts.Count);
        var missing = texts.Where(t => !OwnersOwn.Contains(t.Text) && !NewWordsOfThePc.Contains(t.Text) && !keys.Contains(t.Text) && !pcKeys.Contains(t.Text))
                           .Select(t => $"{t.Where}: \"{t.Text}\"").ToList();
        Assert.AreEqual(0, missing.Count, "not in the Mac's catalog:\n" + string.Join("\n", missing));
    }
}
