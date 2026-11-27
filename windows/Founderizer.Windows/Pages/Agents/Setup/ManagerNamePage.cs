using System.Linq;
using Founderizer.Setup.Agents;
using Founderizer.Setup.FirstRun;
using Founderizer.Setup.Install;
using Founderizer.Windows.Pages.FirstRun;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages.Agents.Setup;

/// <summary>**"Name your manager" in the manager's setup, for a hub whose first run did not ask** (windows-app-plan-v2.md,
/// piece U3b; the Mac's <c>NameManagerPage</c> in its <c>AgentSetupWizard</c>), in the look of the first run's
/// <see cref="NamePage"/>: the mark that a manager of that name gets, at 72, which follows the name as he types
/// (<see cref="MarkOf"/>); the field with the name; the hub's words of a refused rename in orange; and Continue, which
/// shows only for a name that the hub's installer takes and keeps its room while it does not show, so the page does not
/// move. With any other words the field wears its orange edge. Enter is Continue, which renames the manager on the hub
/// (<see cref="ManagerSetup.TakeNameAsync"/>). One field for the page's life, so that it keeps its focus and its caret
/// while he types.</summary>
internal sealed class ManagerNamePage
{
    private readonly ManagerSetup setup;
    private bool loaded;

    public StepField Field { get; } = new(SetupScreens.NamePlaceholder, "agent-setup-name");
    public Button Next { get; } = StepControls.Primary(SetupScreens.Continue, "agent-setup-name-continue");

    public ManagerNamePage(ManagerSetup setup)
    {
        this.setup = setup;
        Field.Box.TextChanged += (_, _) => setup.TypeName(Field.Box.Text);
        Next.Click += (_, _) => Enter();
    }

    /// <summary>The name of the page's mark: the typed name in the installer's form, else the manager's default.</summary>
    public static string MarkOf(ManagerSetupView view) => ManagerName.AgentName(view.TypedName) ?? ManagerName.Fallback;

    public void Show(ManagerSetupView view, ManagerSetupScreen screen)
    {
        if (!loaded)
        {
            loaded = true;
            Field.Box.Text = view.TypedName;
            Field.Box.SelectionStart = Field.Box.Text.Length;
            Field.Box.Loaded += (_, _) => Field.Box.Focus(FocusState.Programmatic);
        }
        Field.Wrong = screen.Controls.First(c => c.Id == "agent-setup-name").Marked;
        bool takes = screen.Controls.Any(c => c.Id == "agent-setup-name-continue");
        Next.Opacity = takes ? 1 : 0;
        Next.IsHitTestVisible = takes;
        // A rename on its way: Continue waits for it (the Mac's disabled(busy)).
        Next.IsEnabled = takes && !view.Busy;
        AutomationProperties.SetAccessibilityView(Next, takes ? AccessibilityView.Content : AccessibilityView.Raw);
    }

    /// <summary>Continue, by its press or by Enter: false for words that the installer does not take, or while a press of
    /// the setup is on its way.</summary>
    public bool Enter()
    {
        var view = setup.View;
        if (ManagerName.AgentName(view.TypedName) is null || view.Busy) return false;
        _ = setup.TakeNameAsync();
        return true;
    }
}
