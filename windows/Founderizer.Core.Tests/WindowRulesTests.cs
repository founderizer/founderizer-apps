using System;
using System.IO;
using System.Linq;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>Rules of the window's pages. The pages call WinUI, which loads in no test, so their rules are read from their
/// source, which the build copies beside the tests.</summary>
[TestClass]
public sealed class WindowRulesTests
{
    private static readonly string Root = Path.Combine(AppContext.BaseDirectory, "sources", "windows");

    private static string Source(string path) => File.ReadAllText(Path.Combine(Root, path)).Replace("\r\n", "\n");

    /// <summary>The method that starts with these words, to the first line that closes it at its own indent.</summary>
    private static string Method(string source, string head)
    {
        var at = source.IndexOf(head, StringComparison.Ordinal);
        Assert.IsGreaterThanOrEqualTo(0, at, head);
        var indent = new string(source[..at].Reverse().TakeWhile(c => c == ' ').ToArray());
        var end = source.IndexOf("\n" + indent + "}\n", at, StringComparison.Ordinal);
        Assert.IsGreaterThan(at, end, head);
        return source[at..end];
    }

    /// <summary>An icon button has no grey ground at rest, as on the Mac (the owner, 23 November 2026: "dont add the grey
    /// backgroundto the icon buttons unless on hover"); Windows' subtle fill comes under the pointer. The bug that this
    /// catches: the button's face, its fill and its edge, comes back.</summary>
    [TestMethod]
    public void AnIconButtonHasNoGroundAtRest()
    {
        foreach (var (file, head) in new[] { ("Pages/States.cs", "public static Button IconOnly("),
                                             ("Pages/TasksPages.cs", "private Button IconButton(") })
        {
            var method = Method(Source(file), head);
            Assert.Contains("QuietButtonStyle", method, file);
            Assert.DoesNotContain("Background", method, file);
            Assert.DoesNotContain("BorderBrush", method, file);
            Assert.DoesNotContain("Face(", method, file);
        }
    }

    /// <summary>An icon button that cannot be pressed has its mark dimmed, as on the Mac: with no ground at rest, the dim is
    /// its one sign. A mark has a brush of its own, which the style's disabled colour does not reach. The bug that this
    /// catches: a disabled Pause or Stop looks as one that acts.</summary>
    [TestMethod]
    public void AnIconButtonThatCannotBePressedIsDimmed()
    {
        foreach (var (file, head, mark) in new[] { ("Pages/States.cs", "public static Button IconOnly(", "glyph"),
                                                   ("Pages/TasksPages.cs", "private Button IconButton(", "mark") })
            Assert.Contains($"button.IsEnabledChanged += (_, _) => {mark}.Opacity = button.IsEnabled ? 1 : 0.45;",
                            Method(Source(file), head), file);
    }

    /// <summary>A chat's file goes to the shell only through its marked copy (<c>Fleet/ChatFileCopy.cs</c>), which opens
    /// an inert kind in its own app and shows each other kind selected in File Explorer. The starts of a program in the
    /// window and in the launcher are these, counted in each file, and each other start is not of a chat's file: the
    /// shell's open of a web link of Tailscale's setup, Tailscale's own program, the launcher and PowerShell. The bugs
    /// that this catches: a page that starts a file itself, through the shell (<c>UseShellExecute = true</c>), through
    /// <c>Process.Start(copy)</c> (CreateProcess runs a <c>.bat</c> through cmd), through a second start in a file that
    /// has one, through Windows' launcher (<c>LaunchFileAsync</c>), through <c>new Process</c> or <c>ShellExecute</c>, or
    /// through Explorer with the copy and no <c>/select,</c>, as <c>Files.Open</c> did before 26 November 2026; and a
    /// start of the marked copy that is not the whole start of its way.</summary>
    [TestMethod]
    public void AChatsFileGoesToTheShellOnlyThroughItsMarkedCopy()
    {
        var launcher = Path.Combine(AppContext.BaseDirectory, "sources", "launcher");
        var sources = Directory.EnumerateFiles(Root, "*.cs", SearchOption.AllDirectories)
            .Select(f => (Name: Path.GetRelativePath(Root, f), Text: File.ReadAllText(f)))
            .Concat(Directory.EnumerateFiles(launcher, "*.cs", SearchOption.AllDirectories)
                .Select(f => (Name: "launcher/" + Path.GetRelativePath(launcher, f), Text: File.ReadAllText(f))))
            .Select(s => (Name: s.Name.Replace('\\', '/'), Text: s.Text.Replace("\r\n", "\n")))
            .ToList();
        // Each file with its count of the pattern, in the order of the files' names; and the files alone.
        (string Name, int Count)[] Found(string pattern) => sources
            .Select(s => (s.Name, Count: System.Text.RegularExpressions.Regex.Count(s.Text, pattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase)))
            .Where(s => s.Count > 0).OrderBy(s => s.Name, StringComparer.Ordinal).ToArray();
        string Counts(string pattern) => string.Join(", ", Found(pattern).Select(s => $"{s.Name} {s.Count}"));
        string Files(string pattern) => string.Join(", ", Found(pattern).Select(s => s.Name));
        Assert.AreEqual("Fleet/ChatFileCopy.cs 1, Fleet/TailscaleSetup.cs 3, Fleet/WindowsParts.cs 1, Update/Updater.cs 1, launcher/Program.cs 3",
                        Counts(@"Process\s*\.\s*Start\s*\("));
        Assert.AreEqual("Fleet/ChatFileCopy.cs 1, Fleet/TailscaleSetup.cs 1", Counts(@"UseShellExecute\s*=\s*true"));
        foreach (var pattern in new[] { @"\bShellStarts\b", @"\bOpenStart\b", @"\bShowStart\b", @"\bexplorer\.exe\b" })
            Assert.AreEqual("Fleet/ChatFileCopy.cs", Files(pattern), pattern);
        foreach (var pattern in new[] { @"\bLaunchFileAsync\b", @"\bLaunchFolder", @"\bCreateProcess", @"\bShellExecute(Ex)?[AW]?\b",
                                        @"\bSHOpenFolderAndSelectItems\b", @"\bWinExec\b", @"\bnew\s+(System\s*\.\s*Diagnostics\s*\.\s*)?Process\s*[({]" })
            Assert.AreEqual("", Files(pattern), pattern);

        // The marked copy: one start, of the whole start of each way, and the shell's open only in OpenStart.
        var copy = sources.Single(s => s.Name == "Fleet/ChatFileCopy.cs").Text;
        Assert.Contains("public static readonly ShellStarts Shared = new(info => Process.Start(info)?.Dispose());", copy);
        Assert.Contains("public static ProcessStartInfo OpenStart(string copy) => new(copy) { UseShellExecute = true };", copy);
        Assert.Contains("ProcessStartInfo(link.AbsoluteUri) { UseShellExecute = true }",
                        sources.Single(s => s.Name == "Fleet/TailscaleSetup.cs").Text);
        Assert.Contains("public static void Open(MessageAttachment file, byte[] bytes) => ChatFileCopy.Open(file, bytes);",
                        sources.Single(s => s.Name == "Pages/States.cs").Text);
    }
}
