using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;

[assembly: DoNotParallelize]

namespace Founderizer.Setup.Tests;

/// <summary>The shared vectors of app/vectors, which the build copies beside the tests. One class for every piece's tests
/// in this project: a piece that needs more of it adds to it here.</summary>
internal static class Vectors
{
    public static JsonElement Read(string name)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "vectors", name)));
        return document.RootElement.Clone();
    }

    public static string? Text(this JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetString();

    public static string? Text(this JsonElement value, string name) => value.GetProperty(name).Text();

    public static List<string> Texts(this JsonElement value) => value.EnumerateArray().Select(v => v.GetString()!).ToList();

    /// <summary>**A sentence of the Mac with the PC's word** (windows-app-plan-v2.md, rule 14): where it says "Mac" for
    /// the owner's computer, the PC says "PC".</summary>
    public static string Pc(string mac) =>
        mac.Replace("This Mac's", "This PC's", StringComparison.Ordinal).Replace("this Mac's", "this PC's", StringComparison.Ordinal)
           .Replace("This Mac", "This PC", StringComparison.Ordinal).Replace("this Mac", "this PC", StringComparison.Ordinal);
}
