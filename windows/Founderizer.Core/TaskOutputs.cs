using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Core;

// The checked outputs of an accepted result (the Mac's ArtifactSection and FleetCore's Artifact.swift; the owner's "Yes,
// as shown" of 14 November 2026 to the fourth set): GET /ui/tasks/<id>/artifacts and /artifact, under the device prefix.

/// <summary>One checked file of a result (FleetCore's TaskArtifact): its path under outputs/, the commit of the fleet's
/// repository that it is read from, its SHA-256, its size and its type.</summary>
public sealed record ArtifactFile(string Path, string Commit, string Sha256, long Bytes, string Mime)
{
    public const long TextLimit = 256 * 1024;
    public const long PictureLimit = 8 * 1024 * 1024;

    public bool IsImage => Mime is "image/png" or "image/jpeg";

    /// <summary>The file's reference holds (TaskArtifact.validate): a path of at least two parts under outputs/, with no
    /// empty, "." or ".." part, no control character and none of \ % : ? #, a type that its extension gives, a commit of
    /// 40 hex characters, a SHA-256 of 64, and a size within the type's limit.</summary>
    public bool IsValid
    {
        get
        {
            if (!Path.StartsWith("outputs/", StringComparison.Ordinal) || Encoding.UTF8.GetByteCount(Path) > 1024) return false;
            var parts = Path.Split('/');
            if (parts.Length < 2 || parts.Any(p => p is "" or "." or "..")) return false;
            if (Path.Any(c => char.IsControl(c) || c is '\\' or '%' or ':' or '?' or '#')) return false;
            var extension = System.IO.Path.GetExtension(Path).TrimStart('.').ToLowerInvariant();
            var mime = extension switch
            {
                "png" => "image/png",
                "jpg" or "jpeg" => "image/jpeg",
                "txt" or "md" or "json" or "csv" => "text/plain",
                _ => null,
            };
            return mime == Mime && Hex(Commit, 40) && Hex(Sha256, 64) &&
                   Bytes >= 0 && Bytes <= (IsImage ? PictureLimit : TextLimit);
        }
    }

    private static bool Hex(string value, int length) => value.Length == length && value.All(Uri.IsHexDigit);
}

/// <summary>The answer of GET /ui/tasks/&lt;id&gt;/artifacts.</summary>
public sealed record ArtifactList(string Db, long Task, IReadOnlyList<ArtifactFile> Artifacts);

/// <summary>What went wrong with a checked output, in the Mac's words (TaskArtifactError).</summary>
public sealed class OutputException(OutputException.Problem problem, string? words = null)
    : Exception(words ?? Words(problem))
{
    public enum Problem { Identity, Metadata, Size, Mime, Checksum, Utf8, Image, Stale, RefusedText, Refused }

    public Problem Kind { get; } = problem;

    public static string Words(Problem problem) => problem switch
    {
        Problem.Identity => "The output response belongs to a different hub, generation, task or revision. Reload checked outputs.",
        Problem.Metadata => "The hub returned an unsupported or invalid output reference.",
        Problem.Size => "The output size does not match its checked reference or exceeds the display limit.",
        Problem.Mime => "The output file type does not match its checked reference.",
        Problem.Checksum => "The output checksum does not match its checked reference. Reload checked outputs.",
        Problem.Utf8 => "The output is not valid UTF-8 text.",
        Problem.Image => "The image cannot be displayed safely. Supported images are PNG or JPEG, up to 40 million pixels.",
        Problem.Stale => "The checked output list changed. Reload checked outputs.",
        Problem.RefusedText => "The hub blocked text that contains a registered login. Nothing was displayed or saved.",
        _ => "Unexpected HTTP response.",
    };

    /// <summary>Another refusal of the hub, with its status and its own words (HubError.refused).</summary>
    public static OutputException Refusal(int status, string? hubWords) =>
        new(Problem.Refused, $"Hub refused the request ({status}): {(string.IsNullOrWhiteSpace(hubWords) ? "Unexpected HTTP response." : hubWords.Trim())}");
}

/// <summary>A picture's size, read from the header of its bytes, as the Mac's ImageIO check asks it: PNG or JPEG of the
/// type that its reference names, each side 1 to 16,384, and at most 40 million pixels. The screens draw it.</summary>
public static class PictureCheck
{
    public const int MostSide = 16_384;
    public const long MostPixels = 40_000_000;

    public static (int Width, int Height)? Size(ReadOnlySpan<byte> bytes, string mime)
    {
        if (mime == "image/png" && bytes.Length >= 24 && bytes[..8].SequenceEqual(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }) &&
            bytes[12..16].SequenceEqual("IHDR"u8))
            return Held((long)BinaryPrimitives.ReadUInt32BigEndian(bytes[16..20]), (long)BinaryPrimitives.ReadUInt32BigEndian(bytes[20..24]));
        if (mime == "image/jpeg" && bytes.Length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8)
        {
            var i = 2;
            while (i + 9 < bytes.Length)
            {
                if (bytes[i] != 0xFF) return null;
                var marker = bytes[i + 1];
                if (marker == 0xFF) { i++; continue; }
                var length = BinaryPrimitives.ReadUInt16BigEndian(bytes[(i + 2)..(i + 4)]);
                if (marker is >= 0xC0 and <= 0xCF and not 0xC4 and not 0xC8 and not 0xCC)
                    return Held(BinaryPrimitives.ReadUInt16BigEndian(bytes[(i + 7)..(i + 9)]), BinaryPrimitives.ReadUInt16BigEndian(bytes[(i + 5)..(i + 7)]));
                if (length < 2) return null;
                i += 2 + length;
            }
        }
        return null;
    }

    private static (int, int)? Held(long width, long height) =>
        width is > 0 and <= MostSide && height is > 0 and <= MostSide && width * height <= MostPixels ? ((int)width, (int)height) : null;
}

/// <summary>A size as Foundation's ByteCountFormatter with the file style writes it (the Mac's "Verified download · …"), in
/// units of 1,000, rounded half away from zero in decimal, with no trailing zero: "Zero KB", "1 byte", "149 bytes",
/// "219 KB", "1 MB", "1.2 MB", "1.23 GB". A size that rounds to 1,000 of a unit is one of the next (999,500 bytes is
/// "1 MB"). Read from Foundation on macOS 27, 14 November 2026.</summary>
public static class FileSize
{
    public static string Words(long bytes, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        if (bytes == 0) return "Zero KB";
        if (bytes == 1) return "1 byte";
        if (bytes < 1000) return bytes.ToString(culture) + " bytes";
        var kb = Math.Round(bytes / 1000m, 0, MidpointRounding.AwayFromZero);
        if (kb < 1000) return kb.ToString("0", culture) + " KB";
        var mb = Math.Round(bytes / 1_000_000m, 1, MidpointRounding.AwayFromZero);
        if (mb < 1000) return mb.ToString("#,0.#", culture) + " MB";
        return Math.Round(bytes / 1_000_000_000m, 2, MidpointRounding.AwayFromZero).ToString("#,0.##", culture) + " GB";
    }
}

/// <summary>A checked file read and verified: its text, or its picture's bytes and size.</summary>
public sealed record ArtifactContent(ArtifactFile File, string? Text, byte[]? Picture, int Width = 0, int Height = 0);

public sealed partial class HubClient
{
    public const int ArtifactListLimit = 256 * 1024;

    /// <summary>GET /ui/tasks/&lt;id&gt;/artifacts?db= (TaskArtifact.list): the checked files of an accepted result, each
    /// held to its reference's rules, of one commit, with no path twice.</summary>
    public async Task<ArtifactList> TaskArtifactsAsync(Uri hub, string? key, string database, long task, CancellationToken cancel = default)
    {
        if (task <= 0 || database.Length == 0) throw new OutputException(OutputException.Problem.Identity);
        using var request = Request(HttpMethod.Get, hub, $"ui/tasks/{task}/artifacts", key, [("db", database)]);
        var (status, body, response) = await OutputReadAsync(request, ArtifactListLimit, cancel);
        response.Dispose();
        if (status != 200) throw Refused(status, body);
        if (body is null) throw new OutputException(OutputException.Problem.Size);
        ArtifactList list;
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            var files = new List<ArtifactFile>();
            foreach (var a in root.GetProperty("artifacts").EnumerateArray())
                files.Add(new ArtifactFile(a.GetProperty("path").GetString()!, a.GetProperty("commit").GetString()!,
                                           a.GetProperty("sha256").GetString()!, a.GetProperty("bytes").GetInt64(),
                                           a.GetProperty("mime").GetString()!));
            list = new ArtifactList(root.GetProperty("db").GetString()!, root.GetProperty("task").GetInt64(), files);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or KeyNotFoundException or FormatException)
        {
            throw new OutputException(OutputException.Problem.Metadata);
        }
        if (list.Db != database || list.Task != task) throw new OutputException(OutputException.Problem.Identity);
        if (list.Artifacts.Select(f => f.Path).Distinct().Count() != list.Artifacts.Count ||
            list.Artifacts.Select(f => f.Commit.ToLowerInvariant()).Distinct().Count() > 1 || list.Artifacts.Any(f => !f.IsValid))
            throw new OutputException(OutputException.Problem.Metadata);
        return list;
    }

    /// <summary>GET /ui/tasks/&lt;id&gt;/artifact?db=&amp;path=&amp;commit= (TaskArtifact.read): the file's bytes, which must
    /// be the hub's, this task's and this commit's, of the named type and size, with its SHA-256; a text must be UTF-8, a
    /// picture a PNG or JPEG of the allowed size.</summary>
    public async Task<ArtifactContent> TaskArtifactAsync(Uri hub, string? key, string database, long task, ArtifactFile file,
                                                         CancellationToken cancel = default)
    {
        if (task <= 0 || database.Length == 0) throw new OutputException(OutputException.Problem.Identity);
        if (!file.IsValid) throw new OutputException(OutputException.Problem.Metadata);
        using var request = Request(HttpMethod.Get, hub, $"ui/tasks/{task}/artifact", key,
                                    [("db", database), ("path", file.Path), ("commit", file.Commit)]);
        request.Headers.Accept.Clear();
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue(file.Mime));
        request.Headers.AcceptEncoding.Add(new StringWithQualityHeaderValue("identity"));
        var (status, body, response) = await OutputReadAsync(request, (int)file.Bytes, cancel);
        using (response)
        {
            if (status != 200) throw Refused(status, body);
            var headers = response;
            string? One(string name) => headers.Headers.TryGetValues(name, out var values) ? values.FirstOrDefault() :
                headers.Content.Headers.TryGetValues(name, out var content) ? content.FirstOrDefault() : null;
            if (One("X-Fleet-DB") != database || One("X-Fleet-Task") != task.ToString(CultureInfo.InvariantCulture) ||
                One("X-Fleet-Commit")?.ToLowerInvariant() != file.Commit.ToLowerInvariant())
                throw new OutputException(OutputException.Problem.Identity);
            var type = headers.Content.Headers.ContentType;
            if (type?.MediaType != file.Mime || type.Parameters.Any(p => !(p.Name.Equals("charset", StringComparison.OrdinalIgnoreCase) &&
                                                                          p.Value?.Trim('"').Equals("utf-8", StringComparison.OrdinalIgnoreCase) == true)) ||
                headers.Content.Headers.ContentEncoding.Any(e => e != "identity"))
                throw new OutputException(OutputException.Problem.Mime);
            if (headers.Content.Headers.ContentLength != file.Bytes || body is null || body.Length != file.Bytes)
                throw new OutputException(OutputException.Problem.Size);
        }
        if (!string.Equals(Convert.ToHexStringLower(SHA256.HashData(body)), file.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new OutputException(OutputException.Problem.Checksum);
        if (!file.IsImage)
        {
            try { return new ArtifactContent(file, new UTF8Encoding(false, true).GetString(body), null); }
            catch (DecoderFallbackException) { throw new OutputException(OutputException.Problem.Utf8); }
        }
        return PictureCheck.Size(body, file.Mime) is { } size
            ? new ArtifactContent(file, null, body, size.Width, size.Height)
            : throw new OutputException(OutputException.Problem.Image);
    }

    /// <summary>One read of an output route: at headers, then at most <paramref name="limit"/> bytes (null for more).
    /// No redirect is followed (the handler's own rule).</summary>
    private async Task<(int Status, byte[]? Body, HttpResponseMessage Response)> OutputReadAsync(HttpRequestMessage request, int limit,
                                                                                                CancellationToken cancel)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        deadline.CancelAfter(options.KnowledgeTimeout);
        try
        {
            var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            try
            {
                var status = (int)response.StatusCode;
                var body = await ReadAsync(response.Content, status == 200 ? limit : 8192, deadline.Token);
                return (status, body, response);
            }
            catch
            {
                response.Dispose();
                throw;
            }
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw HubException.NoAnswer(); }
        catch (HttpRequestException e) { throw HubException.NoAnswer(e); }
        catch (IOException e) { throw HubException.NoAnswer(e); }
    }

    private static OutputException Refused(int status, byte[]? body) => status switch
    {
        409 => new OutputException(OutputException.Problem.Stale),
        422 => new OutputException(OutputException.Problem.RefusedText),
        _ => OutputException.Refusal(status, HubDecode.Refusal(body ?? []).Error is { } words && words.Length > 500 ? words[..500] : HubDecode.Refusal(body ?? []).Error),
    };
}

/// <summary>The words of the checked outputs (the Mac's ArtifactSection), one whole sentence each, kept in one place.</summary>
public static class OutputWords
{
    public const string Heading = "Checked outputs";
    public const string View = "View outputs";
    public const string Reload = "Reload outputs";
    public const string Connection = "Connection required. Reload outputs after the hub reconnects.";
    public const string LoadingList = "Loading checked outputs…";
    public const string LoadingFile = "Loading and verifying output…";
    public const string Cancel = "Cancel";
    public const string NoFiles = "No supported output files are listed for this checked task.";
    public const string ViewFile = "View";
    public const string Close = "Close";
    public const string EmptyText = "Empty text file";
    public const string Commit = "Snapshot commit";
    public const string Sha256 = "SHA-256";
    public const string Type = "Type";
    public const string Discarded = "Output discarded because the hub state is stale.";

    /// <summary>A row's View for an assistive app: "View outputs/T-4/certificate.txt".</summary>
    public static string ViewNamed(string path) => $"View {path}";
    /// <summary>The opened picture for an assistive app.</summary>
    public static string VerifiedImage(string path) => $"Verified image: {path}";
    /// <summary>The fold under an opened file: "Verified download · 149 bytes".</summary>
    public static string VerifiedDownload(long bytes) => $"Verified download · {FileSize.Words(bytes)}";
}
