using Founderizer.Windows.Fleet;
using Windows.ApplicationModel.DataTransfer;

namespace Founderizer.Windows.Pages;

/// <summary>**Text to Windows' clipboard, from every Copy of the app**: a code block, a message, a value, the Tailscale
/// policy's lines and a sign-in code. A write that Windows refuses copies nothing and ends nothing
/// (<see cref="ClipboardGuard"/>).</summary>
internal static class ClipboardText
{
    /// <summary>Puts <paramref name="text"/> on the clipboard; false when nothing was copied. <paramref name="once"/>: not in
    /// the clipboard's history and not in its sync to the owner's other devices (a sign-in code is the owner's, for one
    /// sign-in); where Windows does not take it so, it is not copied at all.</summary>
    public static bool Copy(string text, bool once = false) => ClipboardGuard.Write(() =>
    {
        var package = new DataPackage();
        package.SetText(text);
        if (once) return Clipboard.SetContentWithOptions(package, new ClipboardContentOptions { IsAllowedInHistory = false, IsRoamable = false });
        Clipboard.SetContent(package);
        return true;
    });
}
