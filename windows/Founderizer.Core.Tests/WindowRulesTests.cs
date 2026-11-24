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
}
