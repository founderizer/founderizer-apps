using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using Founderizer.Core;
using Founderizer.Windows.Pages;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;

namespace Founderizer.Windows.Marks;

/// <summary>**The mark of the AI session that sent a message for him** (owner feature `message_hands`,
/// <see cref="OwnerHand"/>; the owner's "B, go ahead" of 24 November 2026 to picture 1b, and "Match the Mac"): the Mac's
/// <c>AISessionMark</c>, a small round tile of 18 on the card's surface with a hairline ring (white at 14 %, half a
/// pixel), and the AI's glyph in the words' colour, 58 % of the tile, over the lower left corner of his bubble, which is in
/// its outline: 7 left of the bubble's edge and 5 under it (the Mac's <c>ChatAppMark.onBubble</c> and <c>corner</c>). The
/// glyph is read from the provider's logo (<see cref="OwnerHand.LogoResource"/>: the Mac's own bytes) by
/// <see cref="ProviderGlyph"/>, as the Mac reads it, and made at the pixels that the screen draws
/// (<see cref="GlyphMask.Scaled"/>, the Mac's smooth interpolation): a bitmap of the logo's size that the image shrank
/// seven times was jagged. Its place is whole pixels of the screen (<see cref="ScreenPixels.Whole"/>): between two pixels,
/// at 125, 150 and 175 %, the glyph lost contrast. "Sent by your AI session" is its hover words and what an assistive app
/// reads. Put it in the bubble's own cell, after the bubble.</summary>
internal sealed class AiSessionMark : Grid
{
    public const double Side = 18;
    /// <summary>The glyph's side in the tile, in the window's units: 58 % of it.</summary>
    private const double GlyphSide = Side * 0.58;

    /// <summary>Each AI's glyph at the logo's size, read once for the window.</summary>
    private static readonly Dictionary<AiMark, Task<GlyphMask?>> Masks = new();
    /// <summary>Each AI's glyph as a bitmap of one size in pixels, made once for the window.</summary>
    private static readonly Dictionary<(AiMark, int), ImageSource?> Bitmaps = new();

    private readonly Image glyph = new() { Stretch = Stretch.Fill, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly TranslateTransform corner = new() { X = -7, Y = 5 };
    private AiMark? mark;
    private (AiMark Mark, double Scale)? drawn;
    private XamlRoot? root;

    public AiSessionMark()
    {
        Width = Height = Side;
        HorizontalAlignment = HorizontalAlignment.Left;
        VerticalAlignment = VerticalAlignment.Bottom;
        // As SwiftUI's offset: no change of the layout, so the bubble keeps its place and its size (Draw puts it on whole
        // pixels, which the layout does not do for a transform).
        RenderTransform = corner;
        Visibility = Visibility.Collapsed;
        Children.Add(new Border
        {
            CornerRadius = new CornerRadius(Side / 2),
            Background = Look.SurfaceBrush,
            BorderBrush = Look.MarkRing,
            BorderThickness = new Thickness(0.5),
            Child = glyph,
        });
        ToolTipService.SetToolTip(this, OwnerHand.Words);
        AutomationProperties.SetName(glyph, OwnerHand.Words);
        // The screen's scale is known in the window, and changes on another screen: the glyph is made again for it.
        Loaded += (_, _) =>
        {
            // A list can load a row again with no Unloaded between: one subscription at a time.
            if (root is null && XamlRoot is { } shown)
            {
                root = shown;
                root.Changed += RootChanged;
            }
            Draw();
        };
        Unloaded += (_, _) =>
        {
            if (root is not null) root.Changed -= RootChanged;
            root = null;
        };
    }

    private void RootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => Draw();

    /// <summary>The mark of this AI, or none (collapsed).</summary>
    public void Show(AiMark? mark)
    {
        this.mark = mark;
        Draw();
    }

    private void Draw()
    {
        Visibility = mark is null ? Visibility.Collapsed : Visibility.Visible;
        if (mark is not { } ai)
        {
            drawn = null;
            glyph.Source = null;
            return;
        }
        if (XamlRoot is not { } window) return;
        var scale = window.RasterizationScale;
        if (drawn == (ai, scale)) return;
        drawn = (ai, scale);
        corner.X = ScreenPixels.Whole(-7, scale);
        corner.Y = ScreenPixels.Whole(5, scale);
        var pixels = ScreenPixels.Side(GlyphSide, scale);
        glyph.Source = null;
        var read = Mask(ai);
        if (read.IsCompletedSuccessfully) Put(ai, pixels, scale, read.Result);
        else _ = Later(read, ai, pixels, scale);
    }

    private async Task Later(Task<GlyphMask?> read, AiMark ai, int pixels, double scale)
    {
        var mask = await read;
        if (drawn == (ai, scale)) Put(ai, pixels, scale, mask);
    }

    /// <summary>The glyph at <paramref name="pixels"/> on its longer side, one pixel of the bitmap for each pixel of the
    /// screen: the image is the bitmap's size in the window's units.</summary>
    private void Put(AiMark ai, int pixels, double scale, GlyphMask? mask)
    {
        if (mask is null) return;
        var scaled = mask.Scaled(pixels);
        if (!Bitmaps.TryGetValue((ai, pixels), out var bitmap)) Bitmaps[(ai, pixels)] = bitmap = Bitmap(scaled);
        double k = pixels / (double)Math.Max(scaled.Width, scaled.Height);
        glyph.Width = scaled.Width * k / scale;
        glyph.Height = scaled.Height * k / scale;
        glyph.Source = bitmap;
    }

    private static ImageSource? Bitmap(GlyphMask mask)
    {
        try
        {
            var bitmap = new WriteableBitmap(mask.Width, mask.Height);
            mask.Bgra(Look.TextColor.R, Look.TextColor.G, Look.TextColor.B).CopyTo(bitmap.PixelBuffer);
            bitmap.Invalidate();
            return bitmap;
        }
        catch (Exception e) when (e is COMException or ArgumentException)
        {
            Readings.Note("AI session mark: " + e.Message);
            return null;
        }
    }

    private static Task<GlyphMask?> Mask(AiMark mark)
    {
        if (!Masks.TryGetValue(mark, out var read)) Masks[mark] = read = Read(mark);
        return read;
    }

    /// <summary>The glyph of the logo alone, at the logo's size: none where the logo cannot be read.</summary>
    private static async Task<GlyphMask?> Read(AiMark mark)
    {
        try
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(OwnerHand.LogoResource(mark));
            if (stream is null) return null;
            var memory = new MemoryStream();
            stream.CopyTo(memory);
            memory.Position = 0;
            var decoder = await BitmapDecoder.CreateAsync(memory.AsRandomAccessStream());
            var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Rgba8, BitmapAlphaMode.Straight, new BitmapTransform(),
                                                       ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
            return ProviderGlyph.Mask(data.DetachPixelData(), (int)decoder.PixelWidth, (int)decoder.PixelHeight, OwnerHand.Tones(mark));
        }
        catch (Exception e) when (e is COMException or IOException or ArgumentException or InvalidOperationException)
        {
            Readings.Note("AI session mark: " + e.Message);
            return null;
        }
    }
}
