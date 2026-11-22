using System;

namespace Founderizer.Windows.Fleet;

/// <summary>**A write to the clipboard never ends the app** (windows-app-plan-v2.md, the read of U3: no write to the
/// clipboard was guarded, and the app catches no exception of its window's thread). Windows refuses a write while another
/// program holds the clipboard open: a COMException with CLIPBRD_E_CANT_OPEN, and other refusals come as other
/// exceptions. Each write of the app goes through <c>Pages.ClipboardText</c>, which runs it here.</summary>
internal static class ClipboardGuard
{
    /// <summary>Runs one write of the clipboard: true when it went, false when Windows refused it. Nothing was copied then,
    /// and the control that copies says nothing of a copy.</summary>
    public static bool Write(Func<bool> write)
    {
        try
        {
            return write();
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            return false;
        }
    }
}
