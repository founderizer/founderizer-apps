using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;
using Microsoft.Win32;

namespace Founderizer.Install;

/// <summary>The two entries that Windows keeps for an installed app of one user, both under the user's own part of
/// Windows (no administrator): the Start menu entry, which starts the launcher, and the entry in Windows' list of
/// installed apps, whose removal runs the launcher with <c>--uninstall</c>.</summary>
public static partial class WindowsEntries
{
    /// <summary>The app's identity on the taskbar and in the Start menu. The running app takes it too, so that a pin of
    /// its window pins the Start menu entry (the launcher), not a build's folder that a later update removes.</summary>
    public const string AppId = "Founderizer.Founderizer";
    public const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Founderizer";

    public static string StartMenuEntry =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Founderizer.lnk");

    /// <summary>This process is the app of <see cref="AppId"/>. Call it before the first window.</summary>
    public static void TakeAppId() => _ = SetCurrentProcessExplicitAppUserModelID(AppId);

    /// <summary>Gives the process that the launcher started the right to come to the front, which Windows gave the
    /// launcher for the owner's click in the Start menu: without it, the window shows behind and its first click only
    /// brings it to the front.</summary>
    public static void LetComeToFront(int processId) => _ = AllowSetForegroundWindow(processId);

    /// <summary>Writes the Start menu entry: the launcher, its folder, its icon, and <see cref="AppId"/>.</summary>
    public static void WriteStartMenuEntry(InstallFolder folder)
    {
        Marshal.ThrowExceptionForHR(CoCreateInstance(ShellLinkClass, IntPtr.Zero, 1 /* CLSCTX_INPROC_SERVER */,
                                                     ShellLinkInterface, out var pointer));
        object instance;
        try
        {
            instance = new StrategyBasedComWrappers().GetOrCreateObjectForComInstance(pointer, CreateObjectFlags.UniqueInstance);
        }
        finally
        {
            Marshal.Release(pointer);
        }
        var link = (IShellLinkW)instance;
        link.SetPath(folder.Launcher);
        link.SetWorkingDirectory(folder.Root);
        link.SetIconLocation(folder.Launcher, 0);
        var value = new PropVariant { Type = 31 /* VT_LPWSTR */, Pointer = Marshal.StringToCoTaskMemUni(AppId) };
        try
        {
            var store = (IPropertyStore)instance;
            store.SetValue(AppIdKey, value);
            store.Commit();
        }
        finally
        {
            Marshal.FreeCoTaskMem(value.Pointer);
        }
        Directory.CreateDirectory(Path.GetDirectoryName(StartMenuEntry)!);
        ((IPersistFile)instance).Save(StartMenuEntry, true);
    }

    /// <summary>Writes the entry of Windows' list of installed apps for the build that runs now.</summary>
    public static void WriteUninstallEntry(InstallFolder folder, BuildInfo build)
    {
        using var key = Registry.CurrentUser.CreateSubKey(UninstallKey, writable: true);
        var command = $"\"{folder.Launcher}\" --uninstall";
        key.SetValue("DisplayName", "Founderizer");
        key.SetValue("DisplayVersion", build.Version);
        key.SetValue("Publisher", "Founderizer");
        key.SetValue("DisplayIcon", folder.Launcher + ",0");
        key.SetValue("InstallLocation", folder.Root);
        key.SetValue("UninstallString", command);
        key.SetValue("QuietUninstallString", command);
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        key.SetValue("EstimatedSize", (int)Math.Min(int.MaxValue, Size(folder.BuildFolder(build.Build)) / 1024), RegistryValueKind.DWord);
        if (key.GetValue("InstallDate") is null)
            key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd", CultureInfo.InvariantCulture));
    }

    /// <summary>The entry of Windows' list names this install.</summary>
    public static bool UninstallEntryIsOurs(InstallFolder folder)
    {
        using var key = Registry.CurrentUser.OpenSubKey(UninstallKey);
        return key?.GetValue("InstallLocation") is string place &&
               Path.TrimEndingDirectorySeparator(place).Equals(folder.Root, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>The key of the app's identity, where Windows keeps its notifications' name, picture and activator.</summary>
    public const string IdentityKey = @"Software\Classes\AppUserModelId\" + AppId;

    /// <summary>Removes both entries, when they are this install's, and the app's registration with Windows'
    /// notifications (its identity's key and the activator that the Windows App SDK registered under it).</summary>
    public static void Remove(InstallFolder folder)
    {
        if (UninstallEntryIsOurs(folder)) Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, throwOnMissingSubKey: false);
        if (File.Exists(StartMenuEntry)) File.Delete(StartMenuEntry);
        using (var identity = Registry.CurrentUser.OpenSubKey(IdentityKey))
        {
            if (identity?.GetValue("CustomActivator") is string activator && Guid.TryParse(activator, out var id))
                Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\CLSID\" + id.ToString("B"), throwOnMissingSubKey: false);
        }
        Registry.CurrentUser.DeleteSubKeyTree(IdentityKey, throwOnMissingSubKey: false);
    }

    private static long Size(string folder)
    {
        try
        {
            return Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return 0;
        }
    }

    private static readonly Guid ShellLinkClass = new("00021401-0000-0000-C000-000000000046");
    private static readonly Guid ShellLinkInterface = new("000214F9-0000-0000-C000-000000000046");
    private static readonly PropertyKey AppIdKey = new(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5); // PKEY_AppUserModel_ID

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey(Guid format, uint id)
    {
        public Guid Format = format;
        public uint Id = id;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropVariant
    {
        public ushort Type;
        public ushort Reserved1;
        public ushort Reserved2;
        public ushort Reserved3;
        public IntPtr Pointer;
        public IntPtr Second;
    }

    [GeneratedComInterface(StringMarshalling = StringMarshalling.Utf16)]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    internal partial interface IShellLinkW
    {
        void GetPath(IntPtr file, int size, IntPtr data, uint flags);
        void GetIDList(out IntPtr list);
        void SetIDList(IntPtr list);
        void GetDescription(IntPtr name, int size);
        void SetDescription(string name);
        void GetWorkingDirectory(IntPtr folder, int size);
        void SetWorkingDirectory(string folder);
        void GetArguments(IntPtr arguments, int size);
        void SetArguments(string arguments);
        void GetHotkey(out ushort key);
        void SetHotkey(ushort key);
        void GetShowCmd(out int show);
        void SetShowCmd(int show);
        void GetIconLocation(IntPtr path, int size, out int index);
        void SetIconLocation(string path, int index);
        void SetRelativePath(string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath(string file);
    }

    [GeneratedComInterface(StringMarshalling = StringMarshalling.Utf16)]
    [Guid("0000010B-0000-0000-C000-000000000046")]
    internal partial interface IPersistFile
    {
        void GetClassID(out Guid id);
        [PreserveSig] int IsDirty();
        void Load(string file, uint mode);
        void Save(string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted(string file);
        void GetCurFile(out IntPtr file);
    }

    [GeneratedComInterface]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    internal partial interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(in PropertyKey key, out PropVariant value);
        void SetValue(in PropertyKey key, in PropVariant value);
        void Commit();
    }

    [LibraryImport("ole32.dll")]
    private static partial int CoCreateInstance(in Guid type, IntPtr outer, uint context, in Guid interfaceId, out IntPtr instance);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(int processId);

    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int SetCurrentProcessExplicitAppUserModelID(string id);
}
