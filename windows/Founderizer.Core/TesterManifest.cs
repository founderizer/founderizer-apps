#if TESTER
namespace Founderizer.Core;

/// <summary>**The tester build's own manifest and key** (windows-app-plan-v2.md, section 4, rule 20, and piece T1): only
/// a tester build (TESTER) has this class, so a signed build holds no tester key, no tester line and no tester check. The
/// first line of a tester manifest's signed text is <see cref="SignedPrefix"/>, so a signature of one kind verifies as no
/// other kind. Its one key is the line of app/windows/release/tester-key.pub, which Founderizer.Core.csproj makes the
/// constant <c>KeyLine</c> when the build is made: the file is the line's one copy.</summary>
public static partial class TesterManifest
{
    public const string SignedPrefix = "founderizer-windows-tester-1";
}
#endif
