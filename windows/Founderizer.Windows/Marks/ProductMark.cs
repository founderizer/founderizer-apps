using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace Founderizer.Windows.Marks;

/// <summary>The product's own mark (FleetMark's FounderizerMark, founderizer-mark.svg): a violet plate and two white
/// chevrons, from the same 512-point drawing. In the title bar it is 16 (W1 of the approved pictures); in an empty chat
/// it is 96 and muted (<see cref="Muted"/>).</summary>
public sealed class ProductMark : Grid
{
    public static readonly Color Violet = Color.FromArgb(255, 0x63, 0x5B, 0xFF);

    public ProductMark() : this(Violet, Color.FromArgb(255, 255, 255, 255))
    {
    }

    private ProductMark(Color plate, Color chevrons)
    {
        IsHitTestVisible = false;
        var canvas = new Canvas { Width = 512, Height = 512 };
        canvas.Children.Add(new Rectangle { Width = 512, Height = 512, RadiusX = 116, RadiusY = 116, Fill = new SolidColorBrush(plate) });
        canvas.Children.Add(Chevron("M172 217L256 133L340 217", 50, chevrons));
        canvas.Children.Add(Chevron("M148 373L256 265L364 373", 62, chevrons));
        Children.Add(new Viewbox { Child = canvas });
    }

    /// <summary>The mark of an empty chat (the Mac's ManagerView, FounderizerMark at 96): white at 0.05 under white at
    /// 0.13, as picture 5a of the third set draws it.</summary>
    public static ProductMark Muted(double side) =>
        new(Color.FromArgb(13, 255, 255, 255), Color.FromArgb(33, 255, 255, 255)) { Width = side, Height = side, IsHitTestVisible = true, named = true };

    // The mark of an empty chat says its words to an assistive app (ChatModel.EmptyWords); the title bar's mark is
    // decoration.
    private bool named;

    protected override Microsoft.UI.Xaml.Automation.Peers.AutomationPeer OnCreateAutomationPeer() =>
        named ? new Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer(this) : base.OnCreateAutomationPeer();

    private static Path Chevron(string data, double width, Color ink) => new()
    {
        Data = (Geometry)Microsoft.UI.Xaml.Markup.XamlBindingHelper.ConvertValue(typeof(Geometry), data),
        Stroke = new SolidColorBrush(ink),
        StrokeThickness = width,
        StrokeStartLineCap = PenLineCap.Round,
        StrokeEndLineCap = PenLineCap.Round,
        StrokeLineJoin = PenLineJoin.Round,
    };
}
