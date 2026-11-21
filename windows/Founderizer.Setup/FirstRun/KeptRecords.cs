using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Founderizer.Setup.Install;

namespace Founderizer.Setup.FirstRun;

/// <summary>This start of the app, in each record that it writes (the Mac's AppLaunch).</summary>
public static class AppLaunch
{
    public static readonly string Id = Guid.NewGuid().ToString("D");
}

/// <summary>**A record of work that this PC did, which must outlive the page that did it** (the Mac's KeptRecord): an
/// install (<see cref="InstallRecord"/>), a server made at a provider (<see cref="BuildRecord"/>). The start of the app
/// that wrote it is in it, so that a later start reads work that was cut off as that, and never as work that runs.</summary>
public interface IKeptRecord<out T>
{
    Guid Id { get; }
    string Launch { get; }
    DateTimeOffset Began { get; }
    /// <summary>The record says that its work runs.</summary>
    bool Runs { get; }
    /// <summary>The same record as a later start reads it when it says that its work runs: cut off.</summary>
    T CutOff();
}

/// <summary>**The records of one kind, in a folder of the app** (the Mac's KeptRecords): one small file for each record,
/// written whole at each change (a new file, then moved over the old one), for this user alone where the system has
/// file modes. The folder is read one time; after that every read is from memory. Past <c>keeps</c> the oldest files
/// go, but never one whose work this start of the app still runs. **Work that was cut off never reads as work that
/// runs**: a record that says it runs and that another start wrote reads as its <c>CutOff()</c>. A file that is no
/// record of this kind, that is larger than a record can be, that is no regular file, or whose name is not its record's
/// id, is passed over and stays. Safe from any thread.</summary>
public sealed class KeptRecords<T> where T : class, IKeptRecord<T>
{
    /// <summary>The largest file that is read as a record: a record is about 2 KiB.</summary>
    public const int LargestFile = 64 * 1024;

    private readonly string folder;
    private readonly string launch;
    private readonly int keeps;
    private readonly JsonTypeInfo<T> type;
    private readonly object gate = new();
    private Dictionary<Guid, T>? records;
    private readonly HashSet<Guid> unsaved = [];
    private int counted;

    /// <summary>Called after a write that changed a record, outside the store's lock.</summary>
    public event EventHandler? Changed;

    public KeptRecords(string folder, JsonTypeInfo<T> type, string? launch = null, int keeps = 40)
    {
        this.folder = Path.GetFullPath(folder);
        this.type = type;
        this.launch = launch ?? AppLaunch.Id;
        this.keeps = Math.Max(1, keeps);
    }

    /// <summary>The start of the app that this store writes for.</summary>
    public string Launch => launch;

    /// <summary>How many writes changed a record since this object was made.</summary>
    public int Changes { get { lock (gate) return counted; } }

    /// <summary>Every record, newest first, each as this start of the app reads it.</summary>
    public IReadOnlyList<T> All()
    {
        lock (gate) return Sorted(Loaded().Values).Select(Read).ToList();
    }

    /// <summary>Keeps the record as it is now. A record that did not change writes nothing; every record whose last
    /// write did not reach the disk is written again at each call.</summary>
    public void Write(T record)
    {
        bool changed;
        lock (gate)
        {
            var all = Loaded();
            changed = !all.TryGetValue(record.Id, out var before) || !Equals(before, record);
            if (!changed && unsaved.Count == 0) return;
            all[record.Id] = record;
            foreach (var old in Sorted(all.Values).Skip(keeps).Where(r => !(r.Runs && r.Launch == launch)).ToList())
            {
                if (old.Id == record.Id) continue;
                all.Remove(old.Id);
                unsaved.Remove(old.Id);
                TryDelete(FileOf(old.Id));
            }
            if (changed) { counted++; unsaved.Add(record.Id); }
            foreach (var id in unsaved.ToList())
                if (!all.TryGetValue(id, out var waits) || Save(waits)) unsaved.Remove(id);
        }
        if (changed) Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>The record of this id changed by <paramref name="change"/>, as this start reads it, and kept; nothing
    /// for an id that has no record.</summary>
    public T? Update(Guid id, Func<T, T> change)
    {
        T? now;
        lock (gate)
        {
            if (!Loaded().TryGetValue(id, out var record)) return null;
            now = change(Read(record));
        }
        Write(now);
        return now;
    }

    /// <summary>**Takes records away, with their files**: the ones for which <paramref name="matches"/> is true, as this
    /// start reads them ("Start again").</summary>
    public void Remove(Func<T, bool> matches)
    {
        bool gone;
        lock (gate)
        {
            var all = Loaded();
            var away = all.Values.Where(r => matches(Read(r))).ToList();
            foreach (var record in away)
            {
                all.Remove(record.Id);
                unsaved.Remove(record.Id);
                TryDelete(FileOf(record.Id));
            }
            gone = away.Count > 0;
            if (gone) counted++;
        }
        if (gone) Changed?.Invoke(this, EventArgs.Empty);
    }

    private T Read(T record) => record.Runs && record.Launch != launch ? record.CutOff() : record;

    private static IEnumerable<T> Sorted(IEnumerable<T> all) =>
        all.OrderByDescending(r => r.Began).ThenBy(r => r.Id.ToString("D"), StringComparer.Ordinal);

    private string FileOf(Guid id) => Path.Combine(folder, id.ToString("D") + ".json");

    /// <summary>With the lock held: the records of the folder, read at the first call.</summary>
    private Dictionary<Guid, T> Loaded()
    {
        if (records is not null) return records;
        var found = new Dictionary<Guid, T>();
        if (Directory.Exists(folder))
            foreach (var path in Directory.EnumerateFiles(folder, "*.json"))
            {
                if (Bytes(path) is not { } data) continue;
                T? record;
                try { record = JsonSerializer.Deserialize(data, type); }
                catch (JsonException) { continue; }
                if (record is null || Path.GetFileName(path) != record.Id.ToString("D") + ".json") continue;
                found[record.Id] = record;
            }
        records = found;
        return found;
    }

    /// <summary>**A file's bytes, only when it is a regular file of at most <see cref="LargestFile"/> bytes**, read with no
    /// step through a link; else null.</summary>
    internal static byte[]? Bytes(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null || (info.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory | FileAttributes.Device)) != 0)
                return null;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            var buffer = new byte[LargestFile + 1];
            var read = 0;
            while (read < buffer.Length)
            {
                var n = stream.Read(buffer, read, buffer.Length - read);
                if (n == 0) break;
                read += n;
            }
            return read > LargestFile ? null : buffer[..read];
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    /// <summary>With the lock held: the record's file, whole, for this user alone. False when it did not reach the disk.</summary>
    private bool Save(T record)
    {
        try
        {
            if (OperatingSystem.IsWindows()) Directory.CreateDirectory(folder);
            else Directory.CreateDirectory(folder, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var path = FileOf(record.Id);
            var temporary = Path.Combine(folder, "." + Path.GetFileName(path) + ".new");
            var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            using (var stream = new FileStream(temporary, options))
            {
                JsonSerializer.Serialize(stream, record, type);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

/// <summary>A time as whole milliseconds since 1970 in a record's file, as the Mac's records keep theirs.</summary>
public sealed class MillisecondsConverter : JsonConverter<DateTimeOffset>
{
    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64());

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(value.ToUnixTimeMilliseconds());
}

/// <summary>The file form of the records: their members in small letters with underscores, an enum by its name, and a
/// time as whole milliseconds.</summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
    UseStringEnumConverter = true,
    Converters = [typeof(MillisecondsConverter)],
    GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(BuildRecord))]
[JsonSerializable(typeof(InstallRecord))]
public sealed partial class RecordsJson : JsonSerializerContext;

/// <summary>**The two kinds of records of the first run**, in their folders under the app's own folder: the servers that
/// this PC asked a provider to make (<c>builds</c>), and the installs that it ran (<c>installs</c>).</summary>
public sealed class SetupRecords(string appFolder, string? launch = null)
{
    public KeptRecords<BuildRecord> Builds { get; } = new(Path.Combine(appFolder, "records", "builds"), RecordsJson.Default.BuildRecord, launch);
    public KeptRecords<InstallRecord> Installs { get; } = new(Path.Combine(appFolder, "records", "installs"), RecordsJson.Default.InstallRecord, launch);
}
