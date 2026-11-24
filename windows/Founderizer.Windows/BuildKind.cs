namespace Founderizer.Windows;

/// <summary>**The kind of this build** (windows-app-plan-v2.md, section 4, rule 20, and piece T1): a tester build, which
/// only <c>-p:FounderizerTester=true</c> makes (TESTER, Directory.Build.props), or a signed build. The kind is chosen
/// when the build is made, never from a file, a variable or a missing signature. release/build-release.ps1 reads this
/// constant from the built Founderizer.App.dll and stops when it is not the kind of the build's build.json.</summary>
public static class BuildKind
{
#if TESTER
    public const bool Tester = true;
#else
    public const bool Tester = false;
#endif
}
