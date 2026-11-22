using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace Founderizer.Windows.Fleet;

/// <summary>**The owner's own key file, once** (windows-app-plan-v2.md, 5.5 "The owner's key, once", and piece U2; the
/// Mac's <c>chooseKey()</c>): Windows' own picker for one file, every file shown (a key has no extension, or <c>.pem</c>,
/// or <c>.ppk</c>), hidden ones too, opening in <c>%USERPROFILE%\.ssh</c> when that folder is there; then the one file
/// read once, at most <see cref="Founderizer.Remote.OwnerKeyFile.MaxLength"/> bytes. This is the one exception to "never
/// read <c>%USERPROFILE%\.ssh</c>": no folder is listed, no other file is opened, nothing is written there, and the app
/// asks for no lasting access to it. The path goes when the read ends; the model gets the bytes and the file's name, and
/// the window keeps no copy.
///
/// **What Windows keeps of a pick** (measured in the build VM on 22 November 2026, after picks of three keys in
/// <c>.ssh</c>): no entry with the file's name in its recent files (<c>FOS_DONTADDTORECENT</c>) or in the file dialog's
/// list of opened files (<c>ComDlg32\OpenSavePidlMRU</c>); but the dialog's own list of last folders
/// (<c>ComDlg32\LastVisitedPidlMRU</c>) keeps one entry: the app's name, <c>Founderizer.App.exe</c>, with the folder of
/// the last pick (<c>.ssh</c>), so that the picker opens there again. That is Windows' record of the dialog, of the
/// folder and not of the file.</summary>
internal static class KeyFile
{
    /// <summary>**One read of the file at <paramref name="path"/>**: its bytes, at most the model's limit (a longer file
    /// gives its first bytes, which are no key that the model reads), and its name alone, never its folder. Null when the
    /// file cannot be read. The buffer of the read is cleared; the caller gives the bytes to the model and keeps none.</summary>
    public static (byte[] Bytes, string Name)? Read(string path)
    {
        var limit = Founderizer.Remote.OwnerKeyFile.MaxLength;
        var buffer = new byte[limit + 1];
        try
        {
            int read = 0;
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1, FileOptions.None))
            {
                while (read < buffer.Length && file.Read(buffer, read, buffer.Length - read) is var n and > 0) read += n;
            }
            var bytes = buffer.AsSpan(0, Math.Min(read, limit)).ToArray();
            return (bytes, Path.GetFileName(path));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(buffer);
        }
    }

    /// <summary>The folder where the picker opens: <c>%USERPROFILE%\.ssh</c> when it is there, else none (Windows' own
    /// choice).</summary>
    public static string? StartFolder()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (home.Length == 0) return null;
        var folder = Path.Combine(home, ".ssh");
        return Directory.Exists(folder) ? folder : null;
    }

    /// <summary>**The picker on a thread of its own**: its modal loop never runs inside the window's own input handling,
    /// which WinUI does not take (the app ended in CoreMessaging when the picker ran on the window's thread from a press).
    /// The window stays the picker's owner, so it takes no input while the picker shows.</summary>
    public static System.Threading.Tasks.Task<string?> PickAsync(IntPtr window, string title)
    {
        var done = new System.Threading.Tasks.TaskCompletionSource<string?>();
        var thread = new System.Threading.Thread(() =>
        {
            try { done.SetResult(Pick(window, title)); }
            catch (Exception e) { done.SetException(e); }
        }) { IsBackground = true, Name = "key picker" };
        thread.SetApartmentState(System.Threading.ApartmentState.STA);
        thread.Start();
        return done.Task;
    }

    /// <summary>**Windows' own picker for one file** (<c>IFileOpenDialog</c>, which can open in any folder, as the Mac's
    /// panel opens in <c>~/.ssh</c>), modal to <paramref name="window"/>, on the calling thread (an STA thread). Null when
    /// the owner closes it.</summary>
    public static string? Pick(IntPtr window, string title)
    {
        var dialog = (IFileOpenDialog)new FileOpenDialog();
        try
        {
            dialog.GetOptions(out var options);
            dialog.SetOptions(options | Fos.ForceFileSystem | Fos.FileMustExist | Fos.PathMustExist | Fos.ForceShowHidden |
                              Fos.DontAddToRecent | Fos.NoChangeDir);
            dialog.SetTitle(title);
            if (StartFolder() is { } folder && SHCreateItemFromParsingName(folder, IntPtr.Zero, typeof(IShellItem).GUID, out var item) == 0)
            {
                dialog.SetFolder(item);
                Marshal.ReleaseComObject(item);
            }
            if (dialog.Show(window) != 0) return null;
            dialog.GetResult(out var chosen);
            try
            {
                chosen.GetDisplayName(SigdnFileSysPath, out var name);
                try { return Marshal.PtrToStringUni(name); }
                finally { Marshal.FreeCoTaskMem(name); }
            }
            finally { Marshal.ReleaseComObject(chosen); }
        }
        catch (COMException)
        {
            return null;
        }
        finally
        {
            Marshal.ReleaseComObject(dialog);
        }
    }

    private const uint SigdnFileSysPath = 0x80058000;

    [Flags]
    private enum Fos : uint
    {
        NoChangeDir = 0x8,
        ForceFileSystem = 0x40,
        PathMustExist = 0x800,
        FileMustExist = 0x1000,
        DontAddToRecent = 0x2000000,
        ForceShowHidden = 0x10000000,
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
                                                          out IShellItem item);

    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7"), ClassInterface(ClassInterfaceType.None)]
    private class FileOpenDialog { }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr bindContext, [MarshalAs(UnmanagedType.LPStruct)] Guid handler, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IntPtr value);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint sigdn, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }

    // IFileDialog's methods in their order, then IFileOpenDialog's two; only those that the picker calls take real types.
    [ComImport, Guid("D57C7288-D4AD-4768-BE02-9D969532D960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint count, IntPtr types);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(Fos options);
        void GetOptions(out Fos options);
        void SetDefaultFolder(IShellItem folder);
        void SetFolder(IShellItem folder);
        void GetFolder(out IShellItem folder);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName(out IntPtr name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void GetResult(out IShellItem item);
        void AddPlace(IShellItem item, int placement);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
        void Close(int result);
        void SetClientGuid([MarshalAs(UnmanagedType.LPStruct)] Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr filter);
        void GetResults(out IntPtr items);
        void GetSelectedItems(out IntPtr items);
    }
}
