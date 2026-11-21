using System;
using System.IO;
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
}
