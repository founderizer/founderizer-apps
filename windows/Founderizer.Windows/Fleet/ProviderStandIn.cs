#if PROOFS
using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Founderizer.Setup.Network;

namespace Founderizer.Windows.Fleet;

/// <summary>**For the proofs in the build VM only** (app/windows/vm/README.md, "The first run's servers against stand-ins"):
/// with FOUNDERIZER_PROVIDERS set to a stand-in's address on the Mac (<c>http://10.0.2.2:&lt;port&gt;</c>, which
/// <c>app/windows/vm/provider_standin.py</c> serves), every request to a provider's own API (Tailscale's, Hetzner's,
/// DigitalOcean's, Vultr's, Akamai's) goes to the stand-in, with its path and query, its method, headers and body, and the
/// host that it was written for in <c>X-Founderizer-Host</c>. Its answer comes back as the answer of the request that the
/// library made, so the library's own checks of the answer stand. A build without the proofs' switch has no such class
/// (<see cref="Proofs"/>): a release reaches the providers' own hosts only.</summary>
internal sealed class ProviderStandIn : DelegatingHandler
{
    private readonly Uri standIn;

    private ProviderStandIn(Uri standIn) : base(ProviderHandler.Create()) => this.standIn = standIn;

    /// <summary>The stand-in of FOUNDERIZER_PROVIDERS, or null with no such variable.</summary>
    public static HttpMessageHandler? Create() =>
        Proofs.Variable("FOUNDERIZER_PROVIDERS") is { Length: > 0 } address && Uri.TryCreate(address, UriKind.Absolute, out var uri) &&
        uri.Scheme == Uri.UriSchemeHttp
            ? new ProviderStandIn(uri)
            : null;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancel)
    {
        var asked = request.RequestUri!;
        using var forward = new HttpRequestMessage(request.Method, new Uri(standIn, asked.PathAndQuery));
        foreach (var header in request.Headers) forward.Headers.TryAddWithoutValidation(header.Key, header.Value);
        forward.Headers.TryAddWithoutValidation("X-Founderizer-Host", asked.Host);
        if (request.Content is { } content)
        {
            var body = await content.ReadAsByteArrayAsync(cancel).ConfigureAwait(false);
            forward.Content = new ByteArrayContent(body);
            foreach (var header in content.Headers) forward.Content.Headers.TryAddWithoutValidation(header.Key, header.Value);
        }
        var answer = await base.SendAsync(forward, cancel).ConfigureAwait(false);
        answer.RequestMessage = request;
        return answer;
    }
}
#endif
