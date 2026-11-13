using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using Founderizer.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Founderizer.Windows.Fleet;

/// <summary>The notification of a new request (picture 10 of the second set, the Mac's FleetNotifications): Windows' own
/// notification for the app, its header with the product's mark and name, the asking agent as its title and the
/// request's title as its text, and no buttons. The store says which are due, once each, also while the window is
/// behind (OwnerStore.Notified); a shown one goes when its request is no longer open; a press opens Needs you at that
/// request (Screens.NoticeTarget), or only brings the window to the front. The manager's warning (a notice with no
/// request) waits for the owner's word, so none is shown.</summary>
internal sealed class WindowsNotices
{
    private readonly DispatcherQueue ui;
    private readonly Func<StoreState> state;
    private readonly Action<long?> open;
    private readonly Dictionary<string, Notice> shown = new();
    private bool registered;

    public WindowsNotices(IFleetSource source, DispatcherQueue ui, Func<StoreState> state, Action<long?> open)
    {
        this.ui = ui;
        this.state = state;
        this.open = open;
        source.Notified += (_, due) => ui.TryEnqueue(() => Show(due));
    }

    /// <summary>Registers the app with Windows' notifications, with its name and the product's mark (a picture that the
    /// window drew of it, in the app's own folder, <paramref name="mark"/>).</summary>
    public void Start(string mark)
    {
        AppNotificationManager.Default.NotificationInvoked += Invoked;
        try
        {
            AppNotificationManager.Default.Register();
            registered = true;
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            Readings.Note("notifications: not registered: " + e.Message);
            return;
        }
        // Windows takes the header's name and picture of an app that is not packaged from its identity's key in the
        // user's part of the registry. (Register's own name and picture refuse a file's address: ERROR_INVALID_NAME.)
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Install.WindowsEntries.IdentityKey, writable: true);
            key.SetValue("DisplayName", "Founderizer");
            key.SetValue("IconUri", mark);
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException or System.Security.SecurityException)
        {
            Readings.Note("notifications: the header's name and mark were not written: " + e.Message);
        }
    }

    public void Stop()
    {
        if (!registered) return;
        try { AppNotificationManager.Default.Unregister(); } catch (COMException) { }
    }

    private void Show(IReadOnlyList<Notice> due)
    {
        if (!registered) return;
        foreach (var notice in due)
        {
            if (notice.Need is not { } need) continue;
            var (tag, group) = Ids(notice);
            var toast = new AppNotificationBuilder()
                .AddArgument("need", need.ToString(CultureInfo.InvariantCulture))
                .AddArgument("context", notice.Context)
                .AddText(notice.Title)
                .AddText(notice.Body)
                .BuildNotification();
            toast.Tag = tag;
            toast.Group = group;
            try
            {
                AppNotificationManager.Default.Show(toast);
                shown[notice.Tag] = notice;
                Readings.Note($"notification: {notice.Title} · {notice.Body}");
            }
            catch (COMException e)
            {
                Readings.Note("notification not shown: " + e.Message);
            }
        }
    }

    /// <summary>Takes away the shown notifications whose request is no longer open.</summary>
    public void Prune(StoreState s)
    {
        if (shown.Count == 0 || s.Hub is not { } hub || s.Fleet is not { } fleet) return;
        var open = Notifications.Open(hub, fleet);
        foreach (var gone in shown.Keys.Where(tag => !open.Contains(tag)).ToList())
        {
            var (tag, group) = Ids(shown[gone]);
            shown.Remove(gone);
            _ = AppNotificationManager.Default.RemoveByTagAndGroupAsync(tag, group).AsTask();
        }
    }

    /// <summary>Windows takes a tag and a group of at most 64 characters each: the request's number, and the hub's
    /// context cut to 64.</summary>
    private static (string Tag, string Group) Ids(Notice notice) =>
        ((notice.Need ?? 0).ToString(CultureInfo.InvariantCulture), notice.Context.Length > 64 ? notice.Context[..64] : notice.Context);

    private void Invoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) =>
        ui.TryEnqueue(() => Pressed(args.Arguments));

    /// <summary>A press on a notification: Needs you at its request while the reading still lists it, else only the
    /// window to the front.</summary>
    public void Pressed(IDictionary<string, string> arguments)
    {
        long? target = null;
        if (arguments.TryGetValue("need", out var text) && long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var need) &&
            arguments.TryGetValue("context", out var context))
        {
            target = Screens.NoticeTarget(state(), new Notice(context, need, "", ""));
        }
        Readings.Note("notification pressed: " + (target is { } t ? "Needs you at request " + t : "the window to the front"));
        open(target);
    }

    /// <summary>The product's mark as a picture for Windows' notification header, drawn by the window from its own mark
    /// (the title bar's), into the app's folder.</summary>
    public static async Task<string?> MarkFile(FrameworkElement mark, string folder)
    {
        try
        {
            var bitmap = new RenderTargetBitmap();
            await bitmap.RenderAsync(mark, 64, 64);
            var pixels = (await bitmap.GetPixelsAsync()).ToArray();
            var path = Path.Combine(folder, "mark.png");
            Directory.CreateDirectory(folder);
            File.WriteAllBytes(path, Png.Encode(pixels, bitmap.PixelWidth, bitmap.PixelHeight));
            return path;
        }
        catch (Exception e) when (e is COMException or IOException or UnauthorizedAccessException or ArgumentException)
        {
            Readings.Note("mark: " + e.Message);
            return null;
        }
    }
}

/// <summary>A PNG of premultiplied BGRA pixels (RenderTargetBitmap's), with Windows' zlib from .NET.</summary>
internal static class Png
{
    public static byte[] Encode(byte[] bgra, int width, int height)
    {
        var raw = new byte[height * (width * 4 + 1)];
        for (int y = 0; y < height; y++)
        {
            raw[y * (width * 4 + 1)] = 0;
            for (int x = 0; x < width; x++)
            {
                int s = (y * width + x) * 4, d = y * (width * 4 + 1) + 1 + x * 4;
                byte a = bgra[s + 3];
                // Back from premultiplied alpha.
                raw[d] = a == 0 ? (byte)0 : (byte)Math.Min(255, bgra[s + 2] * 255 / a);
                raw[d + 1] = a == 0 ? (byte)0 : (byte)Math.Min(255, bgra[s + 1] * 255 / a);
                raw[d + 2] = a == 0 ? (byte)0 : (byte)Math.Min(255, bgra[s] * 255 / a);
                raw[d + 3] = a;
            }
        }
        using var output = new MemoryStream();
        output.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        var header = new byte[13];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(header, width);
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), height);
        header[8] = 8; header[9] = 6;
        Chunk(output, "IHDR", header);
        using (var packed = new MemoryStream())
        {
            using (var zlib = new System.IO.Compression.ZLibStream(packed, System.IO.Compression.CompressionLevel.Optimal, leaveOpen: true))
                zlib.Write(raw);
            Chunk(output, "IDAT", packed.ToArray());
        }
        Chunk(output, "IEND", []);
        return output.ToArray();
    }

    private static void Chunk(Stream output, string type, byte[] data)
    {
        Span<byte> length = stackalloc byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(length, data.Length);
        output.Write(length);
        var typed = new byte[4 + data.Length];
        System.Text.Encoding.ASCII.GetBytes(type).CopyTo(typed, 0);
        data.CopyTo(typed, 4);
        output.Write(typed);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(length, Crc(typed));
        output.Write(length);
    }

    private static uint[]? table;

    /// <summary>PNG's CRC-32 (ISO 3309), over a chunk's type and data.</summary>
    private static uint Crc(byte[] bytes)
    {
        if (table is null)
        {
            table = new uint[256];
            for (uint n = 0; n < 256; n++)
            {
                uint c = n;
                for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                table[n] = c;
            }
        }
        uint crc = 0xFFFFFFFFu;
        foreach (var b in bytes) crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }
}
