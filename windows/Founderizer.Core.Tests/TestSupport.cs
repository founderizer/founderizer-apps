using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

[assembly: DoNotParallelize]

namespace Founderizer.Core.Tests;

/// <summary>The shared vectors of app/vectors, which the build copies beside the tests.</summary>
internal static class Vectors
{
    public static JsonElement Read(string name)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "vectors", name);
        using var document = JsonDocument.Parse(File.ReadAllBytes(path));
        return document.RootElement.Clone();
    }
}

/// <summary>One request as the loopback hub received it.</summary>
internal sealed record Seen(string Method, string Target, IReadOnlyDictionary<string, string> Headers, byte[] Body)
{
    public string Text => Encoding.UTF8.GetString(Body);
    public string? Header(string name) => Headers.TryGetValue(name.ToLowerInvariant(), out var value) ? value : null;
}

/// <summary>A hub on 127.0.0.1 that answers each request with what the test says, one connection per request, and keeps
/// what it received. It stops, with its socket, when the test disposes it.</summary>
internal sealed class LoopbackHub : IDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly Func<Seen, byte[]?> answer;
    private readonly CancellationTokenSource stop = new();
    public ConcurrentQueue<Seen> Received { get; } = new();

    public LoopbackHub(Func<Seen, byte[]?> answer)
    {
        this.answer = answer;
        listener.Start();
        _ = Task.Run(Serve);
    }

    public Uri Address => new($"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/");

    /// <summary>An answer with a JSON body.</summary>
    public static byte[] Json(int status, string json, params (string Name, string Value)[] headers) =>
        Raw(status, Encoding.UTF8.GetBytes(json), [("Content-Type", "application/json"), .. headers]);

    public static byte[] Raw(int status, byte[] body, params (string Name, string Value)[] headers)
    {
        var head = new StringBuilder($"HTTP/1.1 {status} X\r\nConnection: close\r\nContent-Length: {body.Length}\r\n");
        foreach (var (name, value) in headers) head.Append(name).Append(": ").Append(value).Append("\r\n");
        head.Append("\r\n");
        return [.. Encoding.ASCII.GetBytes(head.ToString()), .. body];
    }

    private async Task Serve()
    {
        while (!stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(stop.Token); }
            catch (Exception) { return; }
            _ = Task.Run(async () =>
            {
                using (client)
                {
                    try
                    {
                        var stream = client.GetStream();
                        var seen = await ReadRequest(stream);
                        Received.Enqueue(seen);
                        var reply = answer(seen);
                        if (reply is null)
                        {
                            await Task.Delay(Timeout.Infinite, stop.Token);     // a hub that never answers
                            return;
                        }
                        await stream.WriteAsync(reply, stop.Token);
                    }
                    catch (Exception) { }
                }
            });
        }
    }

    private static async Task<Seen> ReadRequest(NetworkStream stream)
    {
        var buffer = new List<byte>();
        var one = new byte[1];
        while (true)
        {
            if (await stream.ReadAsync(one) == 0) throw new IOException("closed");
            buffer.Add(one[0]);
            if (buffer.Count >= 4 && buffer[^4] == '\r' && buffer[^3] == '\n' && buffer[^2] == '\r' && buffer[^1] == '\n')
                break;
        }
        var lines = Encoding.ASCII.GetString(buffer.ToArray()).Split("\r\n");
        var first = lines[0].Split(' ');
        var headers = new Dictionary<string, string>();
        foreach (var line in lines[1..])
        {
            var colon = line.IndexOf(':');
            if (colon > 0) headers[line[..colon].Trim().ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }
        var body = new byte[headers.TryGetValue("content-length", out var length) ? int.Parse(length) : 0];
        var read = 0;
        while (read < body.Length) read += await stream.ReadAsync(body.AsMemory(read));
        return new Seen(first[0], first[1], headers, body);
    }

    public void Dispose()
    {
        stop.Cancel();
        listener.Stop();
        stop.Dispose();
    }
}

internal static class Expect
{
    public static HubException Hub(Func<Task> call)
    {
        try
        {
            call().GetAwaiter().GetResult();
        }
        catch (HubException e)
        {
            return e;
        }
        Assert.Fail("no HubException");
        return null!;
    }

    public static HubException Hub(Action call) => Hub(() => { call(); return Task.CompletedTask; });
}
