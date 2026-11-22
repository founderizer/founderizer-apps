using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Founderizer.Setup.FirstRun;
using Founderizer.Windows.Fleet;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages.FirstRun;

/// <summary>**Other VPS** (set 8, pictures 12, 13, 14, 13d and 14b; the Mac's <c>vpsStep</c> of <c>FirstRunView</c>, with
/// the Mac's "SSH key · Choose key" of <c>MachineInstallForm</c>): the server's tile, or the lock on the password's page,
/// the title that the model gives, and the model's controls in their order (<see cref="SetupScreens.Vps"/>):
/// <list type="bullet">
/// <item>the address (picture 12), whose Enter checks the server;</item>
/// <item>while the check runs, the moving title alone; a busy server's words while the check waits;</item>
/// <item>the check that passed (picture 13): the green check with the server's system, Install, and what the install
/// changes;</item>
/// <item>the password once (picture 14), and on the password's page of an SSH password the key's card under the
/// password's field and its line (picture 14b, W15): the owner gives the password or chooses the key;</item>
/// <item>the stop of a server that takes keys only (picture 13d): its orange line, then the key's card, and only for a key
/// with a passphrase its field and its line (W14); a wrong passphrase's line last;</item>
/// <item>any other stop: its orange line and Try again.</item>
/// </list>
/// The key's row opens Windows' own picker (<see cref="KeyFile"/>): the window reads that one file once and gives its
/// bytes and its name to the model, which checks it off the window's thread; meanwhile the title moves. The passphrase
/// and the password go to the model as characters, and their fields are empty again. Enter sends the way of the field that
/// holds the caret, else the page's one way on.</summary>
internal sealed class VpsPage : IStepView
{
    private readonly StepHost host;
    private readonly StepColumn column = new(StepLook.Width);
    private readonly StepField address = new(SetupScreens.Address, "first-run-vps-address");
    private readonly SecretField password = new(SetupScreens.Password, "first-run-vps-password");
    private readonly SecretField passphrase = new(SetupScreens.PassphrasePlaceholder, "first-run-vps-passphrase");
    private string? drawn;
    private bool? lockMark;
    private bool picking;
    private int keyWork;
    private SetupScreen? screen;

    public VpsPage(StepHost host)
    {
        this.host = host;
        address.Box.Loaded += (_, _) => address.Box.Focus(FocusState.Programmatic);
    }

    public FrameworkElement View => column;

    public void Show(SetupState state, SetupScreen shown)
    {
        screen = shown;
        var v = state.Vps;
        bool asksPassword = v.Phase == VpsPhase.Password;
        if (lockMark != asksPassword)
        {
            lockMark = asksPassword;
            column.Mark = StepLook.Tile(asksPassword ? StepLook.Glyph(SetupParts.LockGlyph, 21) : StepMarks.Server(22));
        }
        column.Show(shown.Title, shown.Waits || keyWork > 0, shown.Detail, host.ReduceMotion());
        var key = v.Phase + "|" + shown.Warning + "|" + string.Join("|", shown.Controls.Select(c => c.Id + "=" + c.Words + "=" + c.Line + "=" + (c.Lines is null ? "" : string.Join(",", c.Lines))));
        if (key == drawn) return;
        drawn = key;
        Draw(shown);
    }

    /// <summary>The model's controls in their order; the warning of a stop first, as the Mac's stop and picture 13d have
    /// it. The fields are the page's own, so what was typed and the caret stay while the model changes around them.</summary>
    private void Draw(SetupScreen s)
    {
        foreach (var old in column.Controls.Children.OfType<Panel>()) if (old is not StepField and not SecretField) old.Children.Clear();
        column.Controls.Children.Clear();
        // A secret field that the model does not list now is emptied: a password typed and not sent does not wait in it
        // while the page shows another state (a check, a stop, the key's page).
        if (!s.Controls.Any(c => c.Id == "first-run-vps-password")) password.Box.Password = "";
        if (!s.Controls.Any(c => c.Id == "first-run-vps-passphrase")) passphrase.Box.Password = "";
        if (s.Warning is { } warning) column.Controls.Children.Add(StepControls.Warning(warning));
        var rows = new List<SetupParts.Row>();
        void Rows()
        {
            if (rows.Count == 0) return;
            column.Controls.Children.Add(SetupParts.Card(rows.ToList()));
            rows.Clear();
        }
        foreach (var control in s.Controls)
        {
            if (control.Kind != SetupControlKind.Row) Rows();
            switch (control.Kind)
            {
                case SetupControlKind.Field when control.Id == "first-run-vps-address":
                    column.Controls.Children.Add(address);
                    break;
                case SetupControlKind.Secret when control.Id == "first-run-vps-password":
                    column.Controls.Children.Add(password);
                    break;
                case SetupControlKind.Secret when control.Id == "first-run-vps-passphrase":
                    column.Controls.Children.Add(passphrase);
                    break;
                case SetupControlKind.Row when control.Id == "first-run-vps-key":
                    // Its own button each time the row is drawn: an element that stood in a card of before cannot stand in
                    // the new one (WinUI ended the app for it).
                    var keyButton = SetupParts.Standard(control.Lines?.FirstOrDefault() ?? SetupScreens.ChooseKeyWords, "first-run-vps-key-choose");
                    keyButton.Click += (_, _) => ChooseKey();
                    // A row of two lines, the chosen file's name under the title, is 56 high; with no file, 44.
                    rows.Add(new SetupParts.Row(SetupParts.KeyGlyph, control.Words, control.Line, Accessory: keyButton, Bold: true,
                                                GlyphBrush: Look.Text, MinHeight: control.Line is null ? 44 : 56, Id: control.Id));
                    break;
                case SetupControlKind.Row:
                    rows.Add(new SetupParts.Row(SetupParts.ShieldGlyph, control.Words, control.Line, Bold: true, GlyphBrush: Look.Text,
                                                MinHeight: 44, Id: control.Id));
                    break;
                case SetupControlKind.Muted:
                    column.Controls.Children.Add(SetupParts.Quiet(control.Words, control.Id));
                    break;
                case SetupControlKind.Checked:
                    column.Controls.Children.Add(SetupParts.Checked(control.Words, control.Id));
                    break;
                case SetupControlKind.Warning:
                    column.Controls.Children.Add(StepControls.Warning(control.Words));
                    break;
                case SetupControlKind.Button:
                    var button = StepControls.Primary(control.Words, control.Id);
                    var id = control.Id;
                    button.Click += (_, _) => Press(id);
                    column.Controls.Children.Add(button);
                    break;
            }
        }
        Rows();
    }

    private void Press(string id)
    {
        switch (id)
        {
            case "first-run-vps-install": host.Store.InstallVps(); break;
            case "first-run-vps-again": _ = host.Store.VpsAgainAsync(); break;
        }
    }

    public bool Enter()
    {
        if (screen is null) return false;
        bool Has(string id) => screen.Controls.Any(c => c.Id == id);
        if (Has("first-run-vps-passphrase") && passphrase.Focused) return GivePassphrase();
        if (Has("first-run-vps-password") && password.Focused) return GivePassword();
        if (Has("first-run-vps-address"))
        {
            if (address.Box.Text.Trim().Length == 0) return false;
            _ = host.Store.CheckVpsAsync(address.Box.Text);
            return true;
        }
        if (Has("first-run-vps-passphrase")) return GivePassphrase();
        if (Has("first-run-vps-password")) return GivePassword();
        if (Has("first-run-vps-install")) { host.Store.InstallVps(); return true; }
        if (Has("first-run-vps-again")) { _ = host.Store.VpsAgainAsync(); return true; }
        return false;
    }

    private bool GivePassword()
    {
        if (password.Take() is not { } typed) return false;
        _ = host.Store.GivePasswordAsync(typed);
        return true;
    }

    private bool GivePassphrase()
    {
        if (passphrase.Take() is not { } typed) return false;
        Busy(host.Store.GiveKeyPassphrase(typed));
        return true;
    }

    /// <summary>**Choose key, or Change**: Windows' own picker, the one file read once (at most 64 KiB), and its bytes and
    /// name given to the model, which takes the bytes; the window keeps no copy and no path.</summary>
    private async void ChooseKey()
    {
        if (picking) return;
        picking = true;
        (byte[] Bytes, string Name)? file = null;
        try
        {
            var path = await KeyFile.PickAsync(host.Window, SetupViewWords.ChooseKeyTitle);
            if (path is not null) file = await Task.Run(() => KeyFile.Read(path));
        }
        // A picker that Windows could not show, or a file that it could not hand over, chooses nothing (async void: an
        // exception here would end the app).
        catch (Exception) { }
        finally { picking = false; }
        if (file is { } chosen) Busy(host.Store.ChooseKey(chosen.Bytes, chosen.Name));
    }

    /// <summary>The model checks the key off the window's thread; the title moves meanwhile (5.5).</summary>
    private async void Busy(Task work)
    {
        keyWork++;
        Redraw();
        // The model ends each of these with a state of its own; an exception here would end the app (async void).
        try { await work; }
        catch (Exception) { }
        finally
        {
            keyWork--;
            Redraw();
        }
    }

    private void Redraw()
    {
        var state = host.Store.State;
        if (state.Page == SetupPage.Vps) Show(state, SetupScreens.Of(state, host.Store.Runs, host.Store.ShowsBuild));
    }

    public void Left()
    {
        address.Box.Text = "";
        password.Box.Password = "";
        passphrase.Box.Password = "";
    }
}
