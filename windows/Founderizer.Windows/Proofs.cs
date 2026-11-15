using System;
#if PROOFS
using System.Collections.Generic;
using System.IO;
#endif

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
    public static string? Variable(string name) => On ? Environment.GetEnvironmentVariable(name) ?? FromFile(name) : null;

#if PROOFS
    /// <summary>The proofs' variables also come from %LOCALAPPDATA%\Founderizer-proofs\variables.txt (a line
    /// NAME=value each), for an app that Windows starts for a notification: it gets the session's environment of the
    /// sign-in, not the user's variables that the proofs set later.</summary>
    private static readonly Lazy<Dictionary<string, string>> File = new(() =>
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Founderizer-proofs", "variables.txt");
            if (!System.IO.File.Exists(path)) return values;
            foreach (var line in System.IO.File.ReadAllLines(path))
            {
                int equals = line.IndexOf('=');
                if (equals > 0) values[line[..equals]] = line[(equals + 1)..];
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        return values;
    });

    private static string? FromFile(string name) => File.Value.TryGetValue(name, out var value) ? value : null;
#else
    private static string? FromFile(string name) => null;
#endif
}
