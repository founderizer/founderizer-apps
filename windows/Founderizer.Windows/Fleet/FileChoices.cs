using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using Founderizer.Setup.FirstRun;

namespace Founderizer.Windows.Fleet;

/// <summary>**The owner's answers of the first run that this PC keeps between starts** (the library's
/// <see cref="ISetupChoices"/>; the Mac's settings <c>firstRunManagerName</c>, <c>firstRunAIProvider</c>,
/// <c>firstRunServersStep</c>, <c>firstRunErrorReports</c>, the answer that waits for a hub, and where the Tailscale
/// policy is kept): one small JSON file of names and words in the first run's folder. The library never gives it a key,
/// a token, a password or a server's address, except the hub's own address in the mark of the manager's first setup
/// (<c>ManagerSetupMark</c>: the hub's scheme, host and port, its generation, the manager, its chosen provider and the
/// name of the server that joined for it). A file that does not read is no answer: the first run asks again.</summary>
internal sealed class FileChoices(string path) : ISetupChoices
{
    private readonly object gate = new();
    private Dictionary<string, string>? values;

    public string? Get(string name)
    {
        lock (gate) return Values().GetValueOrDefault(name);
    }

    public void Set(string name, string? value)
    {
        lock (gate)
        {
            var all = Values();
            if (value is null ? !all.Remove(name) : all.TryGetValue(name, out var was) && was == value) return;
            if (value is not null) all[name] = value;
            var json = new JsonObject();
            foreach (var (key, word) in all) json[key] = word;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var next = path + ".new";
                File.WriteAllText(next, json.ToJsonString());
                File.Move(next, path, overwrite: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // The answer holds in this run; the next start asks again.
            }
        }
    }

    private Dictionary<string, string> Values()
    {
        if (values is not null) return values;
        values = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            if (File.Exists(path) && JsonNode.Parse(File.ReadAllText(path)) is JsonObject json)
                foreach (var (key, node) in json)
                    if (node is JsonValue value && value.TryGetValue<string>(out var word)) values[key] = word;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
        }
        return values;
    }
}
