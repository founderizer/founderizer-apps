using System;

namespace Founderizer.Windows;

/// <summary>The one switch of the proofs in the build VM (app/windows/vm/README.md, "The window in the VM"): a build
/// with <c>-p:FounderizerProofs=true</c> reads the variables of the proofs (the sample fleet, a hub for the store, the
/// readings' logs); any other build, a release among them, reads none, so a clean PC opens on Add this PC and never shows
/// the sample.</summary>
public static class Proofs
{
#if PROOFS
    public const bool On = true;
#else
    public const bool On = false;
#endif

    /// <summary>A variable of the proofs, or null in a build without the switch.</summary>
    public static string? Variable(string name) => On ? Environment.GetEnvironmentVariable(name) : null;
}
