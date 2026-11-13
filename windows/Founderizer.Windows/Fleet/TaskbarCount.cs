using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Founderizer.Windows.Fleet;

/// <summary>The count of open requests on the app's taskbar button, as the Mac's Dock badge (the owner's "Yes, add
/// it"): the number in the ink on the product's orange, as the overlay that Windows gives an app that is not packaged
/// (ITaskbarList3.SetOverlayIcon), and nothing while no request is open (Screens.TaskbarCount). The window draws the
/// badge (<see cref="Badge"/>) and gives Windows its pixels.</summary>
internal sealed class TaskbarCount
{
    private readonly IntPtr window;
    private readonly FrameworkElement badge;
    private readonly Action<string> words;
    private ITaskbarList3? taskbar;
    private string? shown;
    private IntPtr icon;

    /// <param name="badge">The badge in the window's tree, out of sight, whose words <paramref name="words"/> sets.</param>
    public TaskbarCount(IntPtr window, FrameworkElement badge, Action<string> words)
    {
        this.window = window;
        this.badge = badge;
        this.words = words;
    }

    public async Task Show(string? count)
    {
        if (count == shown) return;
        shown = count;
        try
        {
            taskbar ??= Make();
            if (count is null)
            {
                taskbar.SetOverlayIcon(window, IntPtr.Zero, null);
                Free();
                return;
            }
            // Up to two digits fit Windows' overlay; from 100 on it says 99. Its words for assistive apps are the whole
            // count: the library gives no sentence for it, and the screens put none together.
            int n = int.TryParse(count, out var whole) ? whole : 0;
            words(n > 99 ? "99" : count);
            badge.UpdateLayout();
            var bitmap = new RenderTargetBitmap();
            await bitmap.RenderAsync(badge, 32, 32);
            var pixels = (await bitmap.GetPixelsAsync()).ToArray();
            var next = Icon(pixels, bitmap.PixelWidth, bitmap.PixelHeight);
            taskbar.SetOverlayIcon(window, next, count);
            Free();
            icon = next;
        }
        catch (Exception e) when (e is COMException or InvalidCastException or ArgumentException)
        {
            Readings.Note("taskbar count: " + e.Message);
        }
    }

    private void Free()
    {
        if (icon != IntPtr.Zero) DestroyIcon(icon);
        icon = IntPtr.Zero;
    }

    private static ITaskbarList3 Make()
    {
        var list = (ITaskbarList3)new TaskbarList();
        list.HrInit();
        return list;
    }

    /// <summary>An icon from premultiplied BGRA pixels: a 32-bit colour bitmap with its alpha, and an empty mask.</summary>
    private static IntPtr Icon(byte[] bgra, int width, int height)
    {
        var info = new BitmapInfo { Size = 40, Width = width, Height = -height, Planes = 1, BitCount = 32 };
        var color = CreateDIBSection(IntPtr.Zero, ref info, 0, out var bits, IntPtr.Zero, 0);
        Marshal.Copy(bgra, 0, bits, bgra.Length);
        var mask = CreateBitmap(width, height, 1, 1, IntPtr.Zero);
        var icon = new IconInfo { IsIcon = true, Mask = mask, Color = color };
        var handle = CreateIconIndirect(ref icon);
        DeleteObject(color);
        DeleteObject(mask);
        return handle;
    }

    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090"), ClassInterface(ClassInterfaceType.None)]
    private class TaskbarList { }

    [ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITaskbarList3
    {
        void HrInit();
        void AddTab(IntPtr window);
        void DeleteTab(IntPtr window);
        void ActivateTab(IntPtr window);
        void SetActiveAlt(IntPtr window);
        void MarkFullscreenWindow(IntPtr window, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
        void SetProgressValue(IntPtr window, ulong completed, ulong total);
        void SetProgressState(IntPtr window, int flags);
        void RegisterTab(IntPtr tab, IntPtr main);
        void UnregisterTab(IntPtr tab);
        void SetTabOrder(IntPtr tab, IntPtr before);
        void SetTabActive(IntPtr tab, IntPtr main, uint reserved);
        void ThumbBarAddButtons(IntPtr window, uint count, IntPtr buttons);
        void ThumbBarUpdateButtons(IntPtr window, uint count, IntPtr buttons);
        void ThumbBarSetImageList(IntPtr window, IntPtr images);
        void SetOverlayIcon(IntPtr window, IntPtr icon, [MarshalAs(UnmanagedType.LPWStr)] string? description);
        void SetThumbnailTooltip(IntPtr window, [MarshalAs(UnmanagedType.LPWStr)] string? tip);
        void SetThumbnailClip(IntPtr window, IntPtr clip);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfo
    {
        public int Size;
        public int Width;
        public int Height;
        public short Planes;
        public short BitCount;
        public int Compression;
        public int SizeImage;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public int ClrUsed;
        public int ClrImportant;
        public int Colors;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IconInfo
    {
        [MarshalAs(UnmanagedType.Bool)] public bool IsIcon;
        public int HotspotX;
        public int HotspotY;
        public IntPtr Mask;
        public IntPtr Color;
    }

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage, out IntPtr bits, IntPtr section, uint offset);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bitCount, IntPtr bits);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr handle);

    [DllImport("user32.dll")]
    private static extern IntPtr CreateIconIndirect(ref IconInfo icon);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);
}
