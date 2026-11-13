using System;
using System.Collections.Generic;
using System.Net.Http;
using Founderizer.Core;
#if PROOFS
using System.Globalization;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography;
using System.Threading;
#endif

namespace Founderizer.Windows.Update;

/// <summary>The channel that this build reads, the keys that it trusts and its clock (windows-app-release-design.md,
/// sections 2 and 6, and the Mac's AppUpdatePolicy). A release build reads our channel and trusts only the lines of
/// <c>release-key.pub</c>, and those of <c>early-key.pub</c> as well for a fleet that takes releases early (the PC
/// cannot know that yet: the hub gives the PC no such setting). A build with the proofs' switch takes a test channel,
/// the certificate of its HTTPS server, its key and a shorter clock from the proofs' variables; a release build holds
/// none of them, not even their names.</summary>
internal static class ReleaseChannel
{
    /// <summary>The lines of release-key.pub (the Mac's shipped keys, app/Sources/FleetCore/AppUpdate.swift).</summary>
    public const string ShippedKeys = "8Gc80zgZcWqA7nX3+lChW09v2cOSi0lfjf4OzFiY2Ao=\npQ2RwJ1nL5KXI7dv6Pt71GHMqk61hMA0NQmPUwlSFiY=\n";
    /// <summary>The line of early-key.pub.</summary>
    public const string EarlyKeys = "VxNkV9MNGrcPp62dGE9/mQjXsfgq7WAfWfnNzWSGZe4=\n";

    public static string Channel => TestChannel ?? WindowsUpdate.DefaultChannel;

    public static IReadOnlyList<byte[]> Keys(bool early) =>
        TestKey is { } test ? ReleaseKeys.Parse(test) : ReleaseKeys.Parse(early ? ShippedKeys + EarlyKeys : ShippedKeys);

    public static HttpMessageInvoker NewClient() => TestPin is { } pin ? PinnedClient(pin) : BuildDownload.NewClient();

    /// <summary>Between two reads (the Mac's every).</summary>
    public static TimeSpan Every => TestEvery ?? TimeSpan.FromSeconds(3600);

    /// <summary>After one, two and three reads in a row that failed (the Mac's retries).</summary>
    public static TimeSpan Retry(int failures) =>
        TestEvery ?? TimeSpan.FromSeconds(failures switch { 1 => 60, 2 => 300, 3 => 900, _ => 3600 });

    /// <summary>How long the owner is away from the app before it ends for a new build (the Mac's away).</summary>
    public static TimeSpan Away => TestAway ?? TimeSpan.FromSeconds(120);

#if PROOFS
    private static string? TestChannel => Proofs.Variable("FOUNDERIZER_UPDATE_CHANNEL");
    private static string? TestKey => Proofs.Variable("FOUNDERIZER_UPDATE_KEY");
    private static string? TestPin => Proofs.Variable("FOUNDERIZER_UPDATE_PIN");
    private static TimeSpan? TestEvery => Seconds("FOUNDERIZER_UPDATE_EVERY");
    private static TimeSpan? TestAway => Seconds("FOUNDERIZER_UPDATE_AWAY");

    /// <summary>The build that the proofs end before its first good start (the way back), or null.</summary>
    public static long? EndsBeforeGoodStart =>
        long.TryParse(Proofs.Variable("FOUNDERIZER_UPDATE_FAIL_BUILD"), NumberStyles.None, CultureInfo.InvariantCulture, out var build)
            ? build : null;

    private static TimeSpan? Seconds(string name) =>
        int.TryParse(Proofs.Variable(name), NumberStyles.None, CultureInfo.InvariantCulture, out var seconds) && seconds > 0
            ? TimeSpan.FromSeconds(seconds) : null;

    /// <summary>The library's client, which takes only the test channel's own certificate (its SHA-256).</summary>
    private static HttpMessageInvoker PinnedClient(string pin) => new HttpClient(new SocketsHttpHandler
    {
        UseCookies = false, Credentials = null, PreAuthenticate = false, AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.None, ConnectTimeout = TimeSpan.FromSeconds(20),
        SslOptions = new SslClientAuthenticationOptions
        {
            RemoteCertificateValidationCallback = (_, certificate, _, _) => certificate is not null &&
                Convert.ToHexStringLower(SHA256.HashData(certificate.GetRawCertData())) == pin.ToLowerInvariant(),
        },
    }, disposeHandler: true) { Timeout = Timeout.InfiniteTimeSpan };
#else
    private static string? TestChannel => null;
    private static string? TestKey => null;
    private static string? TestPin => null;
    private static TimeSpan? TestEvery => null;
    private static TimeSpan? TestAway => null;
    public static long? EndsBeforeGoodStart => null;
    private static HttpMessageInvoker PinnedClient(string pin) => BuildDownload.NewClient();
#endif
}
