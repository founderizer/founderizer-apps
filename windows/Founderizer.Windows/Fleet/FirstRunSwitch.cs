namespace Founderizer.Windows.Fleet;

/// <summary>**Whether this build has the welcome page of the first run** (windows-app-plan-v2.md, piece U1, and section
/// 13): only a build with <c>-p:FounderizerWelcome=true</c>. No build that a person gets has the welcome page before the
/// pieces U3, U4 and U5 are in it (the start text of a PC fleet tells each agent that a key card, a team card and a new
/// agent's setup work with no page, which is true from wave B on). Without it a PC with no hub opens on Add this PC, as
/// in step 1 (<c>StoreSettings.Welcome</c>).</summary>
internal static class FirstRunSwitch
{
#if WELCOME
    public const bool Welcome = true;
#else
    public const bool Welcome = false;
#endif
}
