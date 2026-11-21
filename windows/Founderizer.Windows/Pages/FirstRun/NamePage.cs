using System.Linq;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Founderizer.Windows.Marks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**"Name your manager"** (set 8, picture 3; the Mac's <c>NameManagerPage</c>): the mark that a manager of that
/// name gets, at 72, which follows the name as he types; the title and its line; the field with the name; and Continue,
/// which shows only for a name that the hub's installer takes and keeps its room while it does not show, so the page
/// does not move. With any other words the field wears its orange edge. Enter is Continue.</summary>
internal sealed class NamePage : IStepView
{
    private readonly StepHost host;
    private readonly StepColumn column = new(StepLook.Width);
    private readonly StepField field = new(SetupScreens.NamePlaceholder, "first-run-name");
    private readonly Button next = StepControls.Primary(SetupScreens.Continue, "first-run-name-continue");
    private AgentGlyph? mark;
    private string? markFor;
    private bool loaded;

    public NamePage(StepHost host)
    {
        this.host = host;
        column.Controls.Children.Add(field);
        column.Controls.Children.Add(next);
        field.Box.TextChanged += (_, _) => host.Store.TypeName(field.Box.Text);
        next.Click += (_, _) => Enter();
    }

    public FrameworkElement View => column;

    public void Show(SetupState state, SetupScreen screen)
    {
        column.Show(screen.Title, screen.Waits, screen.Detail, host.ReduceMotion());
        if (!loaded)
        {
            loaded = true;
            field.Box.Text = state.ManagerName;
            field.Box.SelectionStart = field.Box.Text.Length;
            field.Box.Loaded += (_, _) => field.Box.Focus(FocusState.Programmatic);
        }
        var name = ManagerName.AgentName(state.ManagerName) ?? ManagerName.Fallback;
        if (name != markFor)
        {
            markFor = name;
            mark = StepLook.AgentMark(name, 72);
            column.Mark = mark;
        }
        field.Wrong = screen.Controls.First(c => c.Id == "first-run-name").Marked;
        bool takes = screen.Controls.Any(c => c.Id == "first-run-name-continue");
        next.Opacity = takes ? 1 : 0;
        next.IsHitTestVisible = next.IsEnabled = takes;
        AutomationProperties.SetAccessibilityView(next, takes ? Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Content : Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
    }

    public bool Enter()
    {
        if (ManagerName.AgentName(host.Store.State.ManagerName) is null) return false;
        host.Store.ChooseName();
        return true;
    }
}
