using System;
using System.Collections.Generic;
using System.Linq;

namespace Founderizer.Core;

/// <summary>The AI whose mark stands on a bubble that its session sent for him (FleetCore's OwnerHand.Runtime): the name
/// of its logo is <see cref="OwnerHand.Logo"/>.</summary>
public enum AiMark { Claude, Codex, Grok, OpenCode }

/// <summary>How one bubble of his is drawn (FleetCore's OwnerHand.Look): <see cref="Outlined"/>, the bubble in its outline
/// with a clear fill, for words that he did not write with his own hand; <see cref="Mark"/>, the mark of the AI session
/// that sent them, or null.</summary>
public sealed record HandLook(bool Outlined, AiMark? Mark)
{
    /// <summary>His own words: the filled bubble with no mark.</summary>
    public static readonly HandLook His = new(false, null);

    /// <summary>**What an assistive app reads for a line of his talk with these words** (FleetCore's Look.spoken): "You: "
    /// only before his own words; the mark's words before an AI session's; another hand's words alone. It never tells him
    /// that he wrote what he did not.</summary>
    public string Spoken(string text) => !Outlined ? $"You: {text}" : Mark is null ? text : $"{OwnerHand.Words}: {text}";
}

/// <summary>**A message that an AI session sent for him does not look like his own** (owner feature `message_hands`, owner
/// API 1.332; the owner's "B, go ahead" of 24 November 2026 to the picture
/// <c>ai-session-mark-2026-11-24/1b-outline-and-mark.png</c>, after "why does it look like I sent that message? I
/// didn't"; his decision 2 "Match the Mac" for the PC). The hub gives each of his messages the hand that sent it
/// (`hand`) and, for an AI session, its program (`runtime`): on the items of a chat, on `agents[].last`, on his guidance of
/// a task (`steers`) and on his lines of a card's talk. The filled bubble stays his own words; words that another hand
/// sent stand in the bubble's outline, still at the right, and an AI session's have its mark at the bubble's lower left
/// corner, with <see cref="Words"/> on hover. One rule for every place, FleetCore's <c>OwnerHand.look</c>.</summary>
public static class OwnerHand
{
    /// <summary>`ui_features` of a hub that gives `hand` and `runtime`. Without it every bubble is drawn as before.</summary>
    public const string Feature = "message_hands";

    /// <summary>The mark's hover words and what an assistive app reads for it: the Mac's sentence (its catalog's key, with
    /// its Spanish "Enviado por tu sesión de IA").</summary>
    public const string Words = "Sent by your AI session";

    /// <summary>The hands of his own words: the Mac's app, a device of his (the iPhone, this PC), and a chat app of his.
    /// A row from before owner API 1.289 has no hand (null), and it keeps the look that it always had.</summary>
    private static readonly HashSet<string> HisHands = new(StringComparer.Ordinal) { "app", "device", "chat" };

    /// <summary>**The look of one bubble of his** (FleetCore's OwnerHand.look): the filled bubble for his own hands and for
    /// a row with no hand; the outline for every other hand (`tool`, an AI session through the owner tools; `connected`,
    /// a connected app; `other`), and for a hand that this app does not know, which is not proved his; and the AI's mark
    /// only for `tool` with a program that has a mark. On a hub without the feature, as before.</summary>
    public static HandLook Of(IReadOnlyList<string>? features, string? hand, string? runtime)
    {
        if (features is null || !features.Contains(Feature) || hand is null || HisHands.Contains(hand)) return HandLook.His;
        return new HandLook(true, hand == "tool" ? MarkOf(runtime) : null);
    }

    /// <summary>The hub's name of the program (the labels of its runtime table: `claude-code`, `codex`, `grok`,
    /// `opencode`) as its mark; null for a program that has none.</summary>
    public static AiMark? MarkOf(string? runtime) => runtime switch
    {
        "claude-code" => AiMark.Claude,
        "codex" => AiMark.Codex,
        "grok" => AiMark.Grok,
        "opencode" => AiMark.OpenCode,
        _ => null,
    };

    /// <summary>The name of the mark's logo: the window's <c>Assets/&lt;name&gt;.png</c>, the Mac's own bytes
    /// (ProviderLogo's "claude", "codex", whose logo is ChatGPT's, "grok" and "opencode"). OpenCode's has a name of its
    /// own, because the panel beside a chat and the first run show <c>Assets/&lt;runtime&gt;.png</c>, and no logo of
    /// OpenCode stands there.</summary>
    public static string Logo(AiMark mark) => mark switch
    {
        AiMark.Claude => "claude",
        AiMark.Codex => "codex",
        AiMark.Grok => "grok",
        _ => "opencode-mark",
    };

    /// <summary>The window's embedded resource of the mark's logo: <c>Founderizer.Windows.Assets.&lt;name&gt;.png</c>, the
    /// logical name that <c>Founderizer.Windows.csproj</c> gives each <c>Assets/*.png</c>.</summary>
    public static string LogoResource(AiMark mark) => $"Founderizer.Windows.Assets.{Logo(mark)}.png";

    /// <summary>What of the mark's logo is its glyph (ProviderLogo's tones): Claude's white star on its orange; ChatGPT's
    /// dark knot on its white; Grok's light ball on its near-black, with its two eyes open; OpenCode's light frame on its
    /// near-black, with the grey of its inner lower half as a faint part of it.</summary>
    public static GlyphTones Tones(AiMark mark) => mark switch
    {
        AiMark.Claude => new(170, 215),
        AiMark.Codex => new(215, 170),
        AiMark.Grok => new(90, 150),
        _ => new(40, 215),
    };
}

/// <summary>What of a logo is its glyph, in luminance of 255 (ProviderLogo.Tones): a pixel at <see cref="Clear"/> (the tile's
/// side) is no part of it, one at <see cref="Solid"/> is whole, and one between them is in proportion. A solid under the
/// clear is a dark glyph on a light tile.</summary>
public readonly record struct GlyphTones(double Clear, double Solid);

/// <summary>Whole pixels of the screen: a place that a transform gives is not rounded by the layout, so at 125, 150 and
/// 175 % it can stand between two pixels, and Windows then draws what stands there between them too.</summary>
public static class ScreenPixels
{
    /// <summary>The length in the window's units that is the nearest whole number of the screen's pixels.</summary>
    public static double Whole(double units, double scale) => Math.Round(units * scale, MidpointRounding.AwayFromZero) / scale;

    /// <summary>The whole number of the screen's pixels of a side, one at least.</summary>
    public static int Side(double units, double scale) => Math.Max(1, (int)Math.Round(units * scale, MidpointRounding.AwayFromZero));
}

/// <summary>A glyph alone, cut to its own bounds: one opacity for each pixel, row by row (0 clear, 255 opaque).</summary>
public sealed record GlyphMask(int Width, int Height, byte[] Opacity)
{
    /// <summary>Its pixels in the colour (<paramref name="r"/>, <paramref name="g"/>, <paramref name="b"/>), as Windows'
    /// bitmaps take them: blue, green, red, opacity, each colour premultiplied by its opacity.</summary>
    public byte[] Bgra(byte r, byte g, byte b)
    {
        var pixels = new byte[Width * Height * 4];
        for (int i = 0; i < Opacity.Length; i++)
        {
            int a = Opacity[i];
            pixels[i * 4] = (byte)((b * a + 127) / 255);
            pixels[i * 4 + 1] = (byte)((g * a + 127) / 255);
            pixels[i * 4 + 2] = (byte)((r * a + 127) / 255);
            pixels[i * 4 + 3] = (byte)a;
        }
        return pixels;
    }

    /// <summary>**The glyph at the size that the screen draws it** (the Mac's <c>.interpolation(.high)</c>): its longer side
    /// <paramref name="side"/> pixels and its proportions kept, each pixel the mean opacity of the area of the glyph that
    /// it covers, so its edges keep their intermediate opacities. A glyph that is not larger stays as it is.</summary>
    public GlyphMask Scaled(int side)
    {
        if (side <= 0 || (Width <= side && Height <= side)) return this;
        double k = (double)side / Math.Max(Width, Height);
        int w = Math.Max(1, (int)Math.Round(Width * k, MidpointRounding.AwayFromZero));
        int h = Math.Max(1, (int)Math.Round(Height * k, MidpointRounding.AwayFromZero));
        double fx = (double)Width / w, fy = (double)Height / h;
        var scaled = new byte[w * h];
        for (int oy = 0; oy < h; oy++)
        {
            double y0 = oy * fy, y1 = y0 + fy;
            for (int ox = 0; ox < w; ox++)
            {
                double x0 = ox * fx, x1 = x0 + fx, sum = 0;
                for (int sy = (int)y0; sy < Math.Min(Height, (int)Math.Ceiling(y1)); sy++)
                {
                    double wy = Math.Min(y1, sy + 1) - Math.Max(y0, sy);
                    for (int sx = (int)x0; sx < Math.Min(Width, (int)Math.Ceiling(x1)); sx++)
                        sum += Opacity[sy * Width + sx] * wy * (Math.Min(x1, sx + 1) - Math.Max(x0, sx));
                }
                scaled[oy * w + ox] = (byte)Math.Round(sum / (fx * fy), MidpointRounding.AwayFromZero);
            }
        }
        return new GlyphMask(w, h, scaled);
    }
}

/// <summary>**The glyph of a provider's logo alone** (FleetMark's ProviderLogo.glyphMask): the mark of an AI session on the
/// corner of a bubble that it sent for him, drawn from the logo's own pixels, so the app carries no image of its own for
/// it.</summary>
public static class ProviderGlyph
{
    /// <summary>The glyph of a square logo of straight RGBA pixels, row by row: each pixel as opaque as its luminance stands
    /// from the tile's to the glyph's (<paramref name="tones"/>). Only the pixels inside the circle that holds the glyph
    /// count (36 % of the side from the middle), and only opaque ones, so the tile's edge and its shadow are no part of it
    /// (Grok's ball runs off the icon's lower edge, and the circle is its edge there). Null for pixels that are no square
    /// picture, or where no pixel stands out.</summary>
    public static GlyphMask? Mask(ReadOnlySpan<byte> rgba, int width, int height, GlyphTones tones)
    {
        if (width <= 0 || width != height || rgba.Length != width * height * 4) return null;
        int side = width;
        var mask = new byte[side * side];
        double middle = side / 2.0, reach = side * 0.36;
        int left = side, top = side, right = -1, bottom = -1;
        for (int y = 0; y < side; y++)
        {
            for (int x = 0; x < side; x++)
            {
                double dx = x + 0.5 - middle, dy = y + 0.5 - middle;
                int at = (y * side + x) * 4;
                if (dx * dx + dy * dy > reach * reach || rgba[at + 3] < 250) continue;
                double luminance = 0.299 * rgba[at] + 0.587 * rgba[at + 1] + 0.114 * rgba[at + 2];
                double share = Math.Min(1, Math.Max(0, (luminance - tones.Clear) / (tones.Solid - tones.Clear)));
                if (share <= 0) continue;
                mask[y * side + x] = (byte)Math.Round(share * 255, MidpointRounding.AwayFromZero);
                left = Math.Min(left, x); right = Math.Max(right, x); top = Math.Min(top, y); bottom = Math.Max(bottom, y);
            }
        }
        if (right < left || bottom < top) return null;
        int w = right - left + 1, h = bottom - top + 1;
        var glyph = new byte[w * h];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                glyph[y * w + x] = mask[(top + y) * side + left + x];
        return new GlyphMask(w, h, glyph);
    }
}

public static class OwnerHandLooks
{
    /// <summary>The look of his bubble of this chat item (OwnerHand.Of): a report is no bubble of his.</summary>
    public static HandLook Look(this MobileChatItem item, MobileSnapshot? fleet) =>
        item.Kind == "message" ? OwnerHand.Of(fleet?.UiFeatures, item.Hand, item.Runtime) : HandLook.His;

    /// <summary>The look of this line of a card's talk: his line by its hand; an agent's reply is no bubble.</summary>
    public static HandLook Look(this NeedMessage line, MobileSnapshot? fleet) =>
        line.FromOwner ? OwnerHand.Of(fleet?.UiFeatures, line.Hand, line.Runtime) : HandLook.His;

    /// <summary>The look of this guidance's bubble in a task's thread: an AI session steers through the owner tools too.</summary>
    public static HandLook Look(this TaskSteer steer, MobileSnapshot? fleet) =>
        OwnerHand.Of(fleet?.UiFeatures, steer.Hand, steer.Runtime);
}
