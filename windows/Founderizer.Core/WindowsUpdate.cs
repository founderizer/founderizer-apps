using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Founderizer.Core;

/// <summary>The build of Founderizer for Windows that runs (the Mac's AppVersion): the name that the owner reads, and the
/// build number that decides which build is newer.</summary>
public sealed record InstalledBuild(string Name, long Build)
{
    public string Line => $"{Name} (build {Build})";
}

/// <summary>What one read of the channel came to (the Mac's AppUpdateReading): the line in the owner's words, and the
/// build to offer when there is one.</summary>
public sealed record UpdateReading
{
    /// <summary>The HTTP status, or 0 when the channel was not reached.</summary>
    public int Status { get; init; }
    public required string Says { get; init; }
    /// <summary>The build that the channel offers, when its signature verified; present also when it is not offered (a
    /// held build, an older one, one for a newer Windows).</summary>
    public WindowsManifest? Manifest { get; init; }
    /// <summary>Its download may go: it is newer than this build, not held, and this Windows runs it.</summary>
    public bool Offered { get; init; }
    /// <summary>This PC runs the newest build.</summary>
    public bool Current { get; init; }
    /// <summary>The channel did not answer, or answered with a server error: the read says nothing new.</summary>
    public bool Unreachable { get; init; }
}

/// <summary>The read of the channel for the newest Windows build and what it means for this PC: the Mac's
/// AppUpdateChannel with "PC" for "Mac". The download is <see cref="BuildDownload"/>. Nothing here installs.</summary>
public static class WindowsUpdate
{
    public const string DefaultChannel = "https://founderizer.com";
    public const string Path = "releases/windows";
    public const string FleetHeader = "Founderizer-Fleet";

    /// <summary>The address of one read: the arch of this PC, and the early track while its fleet takes releases early.</summary>
    public static Uri Address(string channel, string arch, bool early) =>
        new(channel.TrimEnd('/') + "/" + Path + "?arch=" + Uri.EscapeDataString(arch) + (early ? "&track=early" : ""));

    /// <summary>Asks the channel what the newest build for this arch is, checks it with <paramref name="keys"/> (the
    /// shipped keys, and the early ones too for a fleet that takes releases early), and says what it means here.</summary>
    public static async Task<UpdateReading> ReadAsync(HttpMessageInvoker http, string channel, string arch, bool early,
                                                      IReadOnlyList<byte[]> keys, InstalledBuild? installed,
                                                      Version system, string? fleet = null, CancellationToken cancel = default)
    {
        if (!Uri.TryCreate(channel, UriKind.Absolute, out var site) || site.Scheme != "https" || site.Host.Length == 0)
            return new UpdateReading { Says = "This build of Founderizer names a release channel that is not an https address." };
        if (keys.Count == 0)
            return new UpdateReading
            {
                Says = "This build of Founderizer carries no release key, so it refuses every update. That is the safe " +
                       "state: an app that cannot check an update takes none.",
            };
        using var request = new HttpRequestMessage(HttpMethod.Get, Address(channel, arch, early));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (fleet is not null) request.Headers.TryAddWithoutValidation(FleetHeader, fleet);
        int status;
        byte[] body;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            using var answer = await http.SendAsync(request, timeout.Token);
            status = (int)answer.StatusCode;
            if (answer.Content.Headers.ContentLength > AppManifest.AnswerLimit)
                return new UpdateReading { Status = status, Says = "The channel did not answer with a build this app could read." };
            body = await answer.Content.ReadAsByteArrayAsync(timeout.Token);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or OperationCanceledException && !cancel.IsCancellationRequested)
        {
            return new UpdateReading
            {
                Says = "Founderizer could not reach our channel. Nothing changed on this PC, and it asks again by itself.",
                Unreachable = true,
            };
        }
        if (status != 200) return Refusal(status, fleet is not null);
        WindowsManifest manifest;
        try
        {
            manifest = WindowsManifest.Check(body, keys, channel, arch);
        }
        catch (ReleaseUntrusted refused)
        {
            return new UpdateReading { Status = status, Says = refused.Message };
        }
        return Reading(manifest, status, installed, system);
    }

    /// <summary>What a checked manifest means for the PC that runs (AppUpdateChannel.reading).</summary>
    public static UpdateReading Reading(WindowsManifest manifest, int status, InstalledBuild? installed, Version system)
    {
        if (manifest.Hold)
            return new UpdateReading
            {
                Status = status, Manifest = manifest,
                Says = $"Founderizer {manifest.Version} is held by us. No PC takes a held build.",
            };
        if (installed is null)
            return new UpdateReading
            {
                Status = status, Manifest = manifest,
                Says = "Founderizer cannot tell which build it is, so it offers none. Download the app again from our download page.",
            };
        if (manifest.Build <= installed.Build)
            return new UpdateReading
            {
                Status = status, Manifest = manifest, Current = true,
                Says = $"Founderizer {installed.Name} is the newest build. Nothing to install.",
            };
        if (manifest.MinimumSystem is { } needed && !Meets(needed, system))
            return new UpdateReading
            {
                Status = status, Manifest = manifest,
                Says = $"Founderizer {manifest.Version} needs Windows {needed}, and this PC runs {system.Major}.{system.Minor}.{system.Build}. Update Windows first.",
            };
        return new UpdateReading
        {
            Status = status, Manifest = manifest, Offered = true,
            Says = $"Founderizer {manifest.Version} is ready to install. This PC runs {installed.Name}.",
        };
    }

    /// <summary>This Windows is at least <paramref name="needed"/> ("10.0.22621"): major, then minor, then build.</summary>
    public static bool Meets(string needed, Version system)
    {
        var wanted = needed.Split('.');
        long[] here = [system.Major, system.Minor, Math.Max(0, system.Build)];
        for (var i = 0; i < wanted.Length && i < here.Length; i++)
        {
            if (!long.TryParse(wanted[i], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var want))
                return false;
            if (here[i] != want) return here[i] > want;
        }
        return true;
    }

    /// <summary>What our side refusing means, in the Mac's words with "PC": a refusal of our channel is not a broken app.</summary>
    private static UpdateReading Refusal(int status, bool knowsFleet) => status switch
    {
        401 or 402 when !knowsFleet => new UpdateReading
        {
            Status = status,
            Says = "Founderizer does not know which fleet this PC drives yet, so our channel has nothing to answer about. " +
                   "Link your fleet, or take the newest build from our download page.",
        },
        401 or 402 => new UpdateReading { Status = status, Says = $"Our channel refused this fleet ({status}). Nothing changed on this PC." },
        404 => new UpdateReading { Status = status, Says = "No build of Founderizer is published yet." },
        503 => new UpdateReading
        {
            Status = status, Unreachable = true,
            Says = "Our channel could not answer with a build it had checked itself, so it sent none. Nothing was downloaded.",
        },
        >= 500 and <= 599 => new UpdateReading
        {
            Status = status, Unreachable = true,
            Says = $"Our channel had an error ({status}). Nothing changed on this PC, and it asks again by itself.",
        },
        _ => new UpdateReading { Status = status, Says = $"Our channel refused this PC ({status}). Nothing changed here." },
    };
}

/// <summary>A download that did not end in a checked file, in the owner's words (the Mac's AppUpdateFailure). Its
/// folder is gone, and nothing on the PC changed.</summary>
public sealed class UpdateFailure(string says) : Exception(says);

/// <summary>The download of one checked build (the Mac's AppUpdateInstaller.fetch and checkBytes): into a new folder of
/// its own under <c>root</c>, the user's only; stopped when it is larger than the signed size while it arrives; then
/// its size and its SHA-256 against the signed manifest. Any failure removes the folder. It unpacks and installs
/// nothing.</summary>
public static class BuildDownload
{
    public const string FileName = "Founderizer.zip";

    /// <summary>The path of the downloaded file, whose size and SHA-256 are the manifest's; else
    /// <see cref="UpdateFailure"/>.</summary>
    public static async Task<string> FetchAsync(HttpMessageInvoker http, WindowsManifest manifest, string root,
                                                IProgress<double>? progress = null, CancellationToken cancel = default)
    {
        if (!Uri.TryCreate(manifest.Url, UriKind.Absolute, out var url) || url.Scheme != "https")
            throw new UpdateFailure("The channel's answer did not name a download this app could fetch.");
        Directory.CreateDirectory(root);
        var folder = System.IO.Path.Combine(root, $"{manifest.Build}-{Guid.NewGuid():N}");
        if (OperatingSystem.IsWindows()) Directory.CreateDirectory(folder);
        else Directory.CreateDirectory(folder, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var file = System.IO.Path.Combine(folder, FileName);
        try
        {
            await FetchIntoAsync(http, url, manifest, file, progress, cancel);
            return file;
        }
        catch
        {
            try { Directory.Delete(folder, recursive: true); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            throw;
        }
    }

    private static async Task FetchIntoAsync(HttpMessageInvoker http, Uri url, WindowsManifest manifest, string file,
                                             IProgress<double>? progress, CancellationToken cancel)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/zip"));
        HttpResponseMessage answer;
        using var start = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        start.CancelAfter(TimeSpan.FromSeconds(120));
        try
        {
            answer = await http.SendAsync(request, start.Token);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or OperationCanceledException && !cancel.IsCancellationRequested)
        {
            throw new UpdateFailure("The download did not start (0). Nothing on this PC changed.");
        }
        using (answer)
        {
            if (answer.StatusCode != HttpStatusCode.OK)
                throw new UpdateFailure($"The download did not start ({(int)answer.StatusCode}). Nothing on this PC changed.");
            if (answer.Content.Headers.ContentLength is { } promised && promised != manifest.Size)
                throw new UpdateFailure(SizeWords);
            using var whole = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            whole.CancelAfter(TimeSpan.FromHours(1));
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long count = 0;
            try
            {
                await using var source = await answer.Content.ReadAsStreamAsync(whole.Token);
                var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
                if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
                await using var target = new FileStream(file, options);
                var buffer = new byte[1 << 16];
                int read;
                while ((read = await source.ReadAsync(buffer, whole.Token)) > 0)
                {
                    count += read;
                    // A body larger than the signed size is stopped while it arrives.
                    if (count > manifest.Size) throw new UpdateFailure(SizeWords);
                    hash.AppendData(buffer, 0, read);
                    await target.WriteAsync(buffer.AsMemory(0, read), whole.Token);
                    progress?.Report((double)count / manifest.Size);
                }
                await target.FlushAsync(whole.Token);
            }
            catch (Exception e) when (e is HttpRequestException or IOException or OperationCanceledException && !cancel.IsCancellationRequested)
            {
                throw new UpdateFailure(count < manifest.Size ? SizeWords : $"The download stopped: {e.Message}");
            }
            if (count != manifest.Size) throw new UpdateFailure(SizeWords);
            if (Convert.ToHexStringLower(hash.GetHashAndReset()) != manifest.Sha256)
                throw new UpdateFailure("The download does not match the checksum our channel signed. It was thrown away and " +
                                        "nothing on this PC changed.");
        }
    }

    private const string SizeWords = "The download is not the size the signed manifest promised. Nothing was unpacked.";

    /// <summary>The client of the channel and of the download: no cookie, no credential, no proxy credential.</summary>
    public static HttpMessageInvoker NewClient() => new HttpClient(new SocketsHttpHandler
    {
        UseCookies = false, Credentials = null, PreAuthenticate = false, AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.None, ConnectTimeout = TimeSpan.FromSeconds(20),
    }, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
}
