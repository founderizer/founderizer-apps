using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace Founderizer.Core;

/// <summary>The pictures of a page's files: a message's, and a request option's (owner feature `need_pictures`). A page
/// asks for a picture each time it draws its tile (<see cref="Of"/>), and this keeps the reads in order:
/// - **one read at a time, in the order asked**: a card asks for its pictures in the order of its options, so on a slow
///   link the first comes first, and no read waits behind others for its whole timeout;
/// - **a failed read stays failed** (a hub that does not answer, 409 or 410, bytes whose SHA-256 is not the file's, a
///   picture that does not decode) until Read again (<see cref="Again"/>): a draw after the failure starts no new read;
/// - **a picture is its id and its SHA-256**, within one generation of one hub (<see cref="Generation"/>): after a
///   restore or a new database an id can name another file, and no picture stands over another option.
/// <typeparamref name="T"/> is what a picture becomes (the window's image); <c>changed</c> runs after each read that
/// ended, on the context of the first ask (the window's thread), and the page draws again then.</summary>
public sealed class PictureLoads<T> where T : class
{
    private readonly Func<MessageAttachment, Task<byte[]>> read;
    private readonly Func<byte[], Task<T?>> decode;
    private readonly Action changed;
    private readonly object gate = new();
    private readonly Dictionary<(long Id, string Sha256), T> done = new();
    private readonly HashSet<(long Id, string Sha256)> failed = new();
    private readonly List<MessageAttachment> waiting = new();
    private (long Id, string Sha256)? running;
    private string? generation;
    /// <summary>One more for each new generation: a read of an older one keeps nothing.</summary>
    private long epoch;
    private Task pump = Task.CompletedTask;

    public PictureLoads(Func<MessageAttachment, Task<byte[]>> read, Func<byte[], Task<T?>> decode, Action changed)
    {
        this.read = read;
        this.decode = decode;
        this.changed = changed;
    }

    private static (long, string) Key(MessageAttachment file) => (file.Id, file.Sha256);

    /// <summary>The hub and the generation that the page shows, at each draw: a new one forgets every picture, every
    /// failure and every read that waits.</summary>
    public void Generation(string? key)
    {
        lock (gate)
        {
            if (key == generation) return;
            generation = key;
            epoch++;
            done.Clear();
            failed.Clear();
            waiting.Clear();
            running = null;
        }
    }

    /// <summary>A picture once its bytes came and decoded; null until then, and after a read that failed. The first ask
    /// puts its read at the end of the line; a failed one waits for <see cref="Again"/>.</summary>
    public T? Of(MessageAttachment file)
    {
        if (!file.IsImage) return null;
        lock (gate)
        {
            var key = Key(file);
            if (done.TryGetValue(key, out var picture)) return picture;
            if (failed.Contains(key) || running == key || waiting.Exists(w => Key(w) == key)) return null;
            waiting.Add(file);
            Start();
            return null;
        }
    }

    /// <summary>Its read waits or runs: the tile says "Reading…".</summary>
    public bool Reads(MessageAttachment file)
    {
        lock (gate) return running == Key(file) || waiting.Exists(w => Key(w) == Key(file));
    }

    /// <summary>Its last read failed, and no new one runs.</summary>
    public bool Failed(MessageAttachment file)
    {
        lock (gate) return failed.Contains(Key(file));
    }

    /// <summary>Read again: the failure is forgotten, and its read goes to the end of the line.</summary>
    public void Again(MessageAttachment file)
    {
        lock (gate)
        {
            var key = Key(file);
            failed.Remove(key);
            done.Remove(key);
        }
        Of(file);
    }

    /// <summary>A file's tile with "Reading…" while its read waits or runs here, so the tile's model changes when the
    /// read ended, and its row draws again.</summary>
    public FileTile Mark(FileTile tile) => tile with { Reading = Reads(tile.File) };

    /// <summary>A request's options with their pictures marked as <see cref="Mark(FileTile)"/> marks one.</summary>
    public OptionsModel Mark(OptionsModel options) =>
        options.Pictures.Count == 0 ? options : options with { Pictures = ValueList.Of(options.Pictures.Select(p => Mark(p))) };

    /// <summary>Ends when no read runs or waits (for a test).</summary>
    internal async Task IdleAsync()
    {
        while (true)
        {
            Task now;
            lock (gate)
            {
                if (running is null && waiting.Count == 0) return;
                now = pump;
            }
            await now;
        }
    }

    private void Start()
    {
        if (running is not null || waiting.Count == 0) return;
        var file = waiting[0];
        waiting.RemoveAt(0);
        running = Key(file);
        pump = LoadAsync(file, epoch);
    }

    private async Task LoadAsync(MessageAttachment file, long started)
    {
        // The read starts after the ask that queued it, never inside it.
        await Task.Yield();
        T? picture = null;
        try
        {
            picture = await decode(await read(file));
        }
        catch (Exception)
        {
            // Any failure of the read or of the picture: "Not loaded" (the store keeps it for its tile), until Read
            // again. Nothing reads it again by itself.
        }
        lock (gate)
        {
            if (started != epoch) return;
            var key = Key(file);
            if (picture is null) failed.Add(key);
            else done[key] = picture;
            running = null;
            Start();
        }
        changed();
    }
}
