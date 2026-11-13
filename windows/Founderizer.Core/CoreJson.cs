using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Founderizer.Core;

/// <summary>The one JSON context of the library: every read and write by source generation, none by reflection, so
/// that a trimmed or Native AOT build reads exactly what this build reads. Its options are the rules of a Swift
/// <c>Decodable</c> (see Models.cs).</summary>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
    RespectNullableAnnotations = true,
    RespectRequiredConstructorParameters = true,
    NumberHandling = JsonNumberHandling.Strict,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    GenerationMode = JsonSourceGenerationMode.Metadata)]
[JsonSerializable(typeof(MobileSnapshot))]
[JsonSerializable(typeof(MobileChatPage))]
[JsonSerializable(typeof(MobileTaskPage))]
[JsonSerializable(typeof(MobileEnrollment))]
[JsonSerializable(typeof(MobileDeviceList))]
[JsonSerializable(typeof(KnowledgeFile))]
[JsonSerializable(typeof(WaitAnswer))]
[JsonSerializable(typeof(SendReceipt))]
[JsonSerializable(typeof(ControlReceipt))]
[JsonSerializable(typeof(RefusalBody))]
[JsonSerializable(typeof(PendingRequestRecord))]
[JsonSerializable(typeof(MobileAgent))]
[JsonSerializable(typeof(OwnerNeed))]
[JsonSerializable(typeof(MobileTaskHead))]
[JsonSerializable(typeof(MobileChatItem))]
[JsonSerializable(typeof(MessageAttachment))]
[JsonSerializable(typeof(KeptSnapshot))]
[JsonSerializable(typeof(KeptChats))]
[JsonSerializable(typeof(KeptSeen))]
[JsonSerializable(typeof(KeptDrafts))]
[JsonSerializable(typeof(KeptHub))]
[JsonSerializable(typeof(KeptStaged))]
[JsonSerializable(typeof(KeptLedger))]
internal sealed partial class CoreJson : JsonSerializerContext;

/// <summary>The shapes that the hub and the Swift apps check, each anchored at both ends of the text (\A and \z): a
/// final newline never passes, which Swift's `^...$` and Python's `re.match` with `$` would let through.</summary>
internal static partial class Patterns
{
    [GeneratedRegex(@"\A[a-z][a-z0-9_-]{0,63}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex AgentName();

    [GeneratedRegex(@"\A[a-z][a-z0-9-]{1,30}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex DeviceName();

    [GeneratedRegex(@"\A[A-Z][A-Z0-9_]{0,59}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex Variable();

    [GeneratedRegex(@"\Abws://[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex SecretReference();

    [GeneratedRegex(@"\A[A-Za-z0-9][A-Za-z0-9 ._+-]{0,40}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex Version();

    [GeneratedRegex(@"\A[0-9a-f]{64}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex Sha256Hex();

    [GeneratedRegex(@"\A[0-9]{1,3}(\.[0-9]{1,3}){0,2}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex SystemVersion();

    [GeneratedRegex(@"\A[0-9a-f]{40}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex Revision();

    /// <summary>A Windows version as a build names its lowest: major.minor.build ("10.0.22621").</summary>
    [GeneratedRegex(@"\A[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,6}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex WindowsVersion();

    [GeneratedRegex(@"\Ahttps://[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]{1,400}\z", RegexOptions.CultureInvariant)]
    internal static partial Regex NotesAddress();
}
