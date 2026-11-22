using System.Linq;
using Founderizer.Setup.FirstRun;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**"Your Tailscale key"** (set 8, picture 8; the Mac's <c>key</c> step of <c>FirstRunView</c>): Tailscale's
/// logo on its white tile, the title, the two steps at Tailscale over the field, and the field that the access token is
/// pasted into (<see cref="PasteField"/>: it takes only <c>tskey-api-</c>, and sends itself). While the key is made the
/// title moves ("Connecting your network") and nothing else shows. A policy file that the PC may not write gets the
/// Mac's <c>PolicyLines</c>: the words over the lines in orange, the lines whole in their box, and Copy. What stopped is
/// the one orange line under them.</summary>
internal sealed class KeyPage : IStepView
{
    private readonly StepHost host;
    private readonly StepColumn column = new(StepLook.Width) { Mark = StepMarks.Network() };
    private readonly StackPanel steps = SetupParts.Steps(SetupScreens.KeySteps, id: "first-run-key-steps");
    private readonly PasteField paste;
    private readonly StackPanel policy = new() { Spacing = StepLook.Gap };
    private readonly TextBlock policySays = StepControls.Warning("");
    private readonly TextBlock policyLines = Look.Words("", 13, 18);
    private readonly Button copy;
    private readonly TextBlock warning = StepControls.Warning("");
    private bool copied;

    public KeyPage(StepHost host)
    {
        this.host = host;
        paste = new PasteField(SetupScreens.PasteHere, "first-run-tailscale-key", t => t.StartsWith("tskey-api-", System.StringComparison.Ordinal),
                               token => _ = host.Store.SendKeyAsync(token));
        // The lines in the box of the Mac's PolicyLines: their own type, selectable, left in a box of the canvas's colour.
        policyLines.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas");
        policyLines.IsTextSelectionEnabled = true;
        AutomationProperties.SetAutomationId(policyLines, "policy-lines");
        copy = StepControls.Primary(SetupViewWords.Copy, "policy-lines-copy");
        copy.Click += (_, _) => Copy();
        policy.Children.Add(policySays);
        policy.Children.Add(new Border
        {
            Padding = new Thickness(10),
            CornerRadius = new CornerRadius(4),
            Background = Look.CanvasBrush,
            BorderBrush = Look.Line,
            BorderThickness = new Thickness(0.5),
            Child = policyLines,
        });
        policy.Children.Add(copy);
        column.Controls.Children.Add(steps);
        column.Controls.Children.Add(paste.Field);
        column.Controls.Children.Add(policy);
        column.Controls.Children.Add(warning);
    }

    public FrameworkElement View => column;

    public void Show(SetupState state, SetupScreen screen)
    {
        column.Show(screen.Title, screen.Waits, screen.Detail, host.ReduceMotion());
        bool asks = screen.Controls.Any(c => c.Id == "first-run-tailscale-key");
        steps.Visibility = paste.Field.Visibility = asks ? Visibility.Visible : Visibility.Collapsed;
        var lines = screen.Controls.FirstOrDefault(c => c.Id == "first-run-key-lines");
        policy.Visibility = lines is null ? Visibility.Collapsed : Visibility.Visible;
        if (lines is not null && policyLines.Text != (lines.Line ?? ""))
        {
            policySays.Text = lines.Words;
            policyLines.Text = lines.Line ?? "";
            copied = false;
            ShowCopy();
        }
        warning.Text = screen.Warning ?? "";
        warning.Visibility = screen.Warning is null ? Visibility.Collapsed : Visibility.Visible;
    }

    public bool Enter() => paste.Field.Visibility == Visibility.Visible && paste.Enter();

    /// <summary>Copy takes the lines as they are; its words say Copied until the next lines.</summary>
    private void Copy()
    {
        var package = new DataPackage();
        package.SetText(policyLines.Text);
        Clipboard.SetContent(package);
        copied = true;
        ShowCopy();
    }

    private void ShowCopy()
    {
        var words = copied ? SetupViewWords.Copied : SetupViewWords.Copy;
        if (copy.Content is Border { Child: TextBlock label }) label.Text = words;
        AutomationProperties.SetName(copy, words);
    }
}
