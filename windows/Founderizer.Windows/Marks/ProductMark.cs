using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace Founderizer.Windows.Marks;

/// <summary>The product's own mark (FleetMark's FounderizerMark, founderizer-mark.svg): a violet plate and two white
/// chevrons, from the same 512-point drawing. In the title bar it is 16 (W1 of the approved pictures).</summary>
public sealed class ProductMark : Grid
{
    public static readonly Color Violet = Color.FromArgb(255, 0x63, 0x5B, 0xFF);

    public ProductMark()
    {
        IsHitTestVisible = false;
        var canvas = new Canvas { Width = 512, Height = 512 };
        canvas.Children.Add(new Rectangle { Width = 512, Height = 512, RadiusX = 116, RadiusY = 116, Fill = new SolidColorBrush(Violet) });
        canvas.Children.Add(Chevron("M172 217L256 133L340 217", 50));
        canvas.Children.Add(Chevron("M148 373L256 265L364 373", 62));
        Children.Add(new Viewbox { Child = canvas });
    }

    private static Path Chevron(string data, double width) => new()
    {
        Data = (Geometry)Microsoft.UI.Xaml.Markup.XamlBindingHelper.ConvertValue(typeof(Geometry), data),
        Stroke = new SolidColorBrush(Color.FromArgb(255, 255, 255, 255)),
        StrokeThickness = width,
        StrokeStartLineCap = PenLineCap.Round,
        StrokeEndLineCap = PenLineCap.Round,
        StrokeLineJoin = PenLineJoin.Round,
    };
}
