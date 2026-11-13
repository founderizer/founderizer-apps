// The self-check of Founderizer for Windows: the shared vectors of app/vectors, the JSON of the device routes and the
// outbox, and BouncyCastle's X25519 and ChaCha20-Poly1305, in a program that is published with Native AOT. A native
// build that passes proves that the logic library, its source-generated JSON and BouncyCastle work with no JIT and no
// reflection (windows-app-plan.md, section 10: "The managed crypto library with Native AOT. Slice 1.1 proves it.").
//
//     dotnet publish app/windows/Founderizer.SelfCheck -c Release -r osx-arm64
//     app/windows/Founderizer.SelfCheck/bin/Release/net10.0/osx-arm64/publish/Founderizer.SelfCheck [vectors folder]
//
// It prints one line for each check and ends with 0 when every check passed, 1 otherwise.

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Founderizer.Core;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Math.EC.Rfc7748;

var folder = args.Length > 0 ? args[0] : Path.Combine(AppContext.BaseDirectory, "vectors");
var failed = 0;
var passed = 0;

void Check(string name, Func<bool> check)
{
    try
    {
        if (check()) { passed++; Console.WriteLine($"ok      {name}"); return; }
        Console.WriteLine($"FAILED  {name}");
    }
    catch (Exception e)
    {
        Console.WriteLine($"FAILED  {name}: {e.GetType().Name}: {e.Message}");
    }
    failed++;
}

JsonElement Vector(string name)
{
    using var document = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(folder, name)));
    return document.RootElement.Clone();
}

bool Refuses<T>(Action call) where T : Exception
{
    try { call(); } catch (T) { return true; }
    return false;
}

Console.WriteLine($"Founderizer.SelfCheck: native code {!RuntimeFeature.IsDynamicCodeSupported}, " +
                  $"{System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier}, vectors {folder}");

// ---------------------------------------------------------------- the canonical text
var canonical = Vector("canonical-json.json");
foreach (var c in canonical.GetProperty("cases").EnumerateArray())
{
    Check("canonical: " + c.GetProperty("name").GetString(), () =>
    {
        var text = CanonicalJson.Write(CanonicalJson.Read(c.GetProperty("object").GetRawText()));
        return text == c.GetProperty("canonical").GetString() &&
               Convert.ToHexStringLower(Encoding.UTF8.GetBytes(text)) == c.GetProperty("utf8_hex").GetString();
    });
}
Check("canonical: texts that are not canonical are refused", () =>
{
    foreach (var t in canonical.GetProperty("not_canonical").EnumerateArray())
        if (CanonicalJson.IsCanonical(t.GetString()!)) return false;
    return true;
});

// ---------------------------------------------------------------- the owner's signature
var owner = Vector("owner-statement.json");
var statement = owner.GetProperty("statement").GetString()!;
var publicKey = owner.GetProperty("public_key").GetString()!;
Check("owner statement: the builder writes the vector's text", () =>
{
    var f = owner.GetProperty("fields");
    return OwnerStatement.OwnerDevice(f.GetProperty("fleet").GetString()!, f.GetProperty("device").GetString()!,
                                      f.GetProperty("key").GetString()!, f.GetProperty("at").GetInt64()) == statement;
});
Check("owner statement: the vector's signature verifies", () =>
    OwnerSignature.Verify(publicKey, statement, owner.GetProperty("signature").GetString()!));
Check("owner statement: the accepted forms verify and the refused ones do not", () =>
{
    foreach (var a in owner.GetProperty("accepted").EnumerateArray())
        if (!OwnerSignature.Verify(publicKey, statement, a.GetProperty("signature").GetString()!)) return false;
    foreach (var r in owner.GetProperty("refused").EnumerateArray())
        if (OwnerSignature.Verify(publicKey, statement, r.GetProperty("signature").GetString()!)) return false;
    return true;
});
Check("owner statement: a software key of the scalar signs what verifies, in strict DER", () =>
{
    using var key = SoftwareOwnerKey.Import(Convert.FromHexString(owner.GetProperty("private_scalar_hex").GetString()!),
                                            publicKey);
    var signature = key.Sign(statement);
    return key.PublicKey == publicKey && Base64Strict.TryDecode(signature, out var raw) && StrictDer.Read(raw) is not null &&
           OwnerSignature.Verify(publicKey, statement, signature);
});

// ---------------------------------------------------------------- the device binding
var binding = Vector("device-binding.json");
Check("device binding: the HMAC of the key and of the recovery key", () =>
    DeviceBinding.Binding(binding.GetProperty("bind").GetString()!, binding.GetProperty("key").GetString()!) ==
        binding.GetProperty("binding").GetString() &&
    DeviceBinding.Binding(binding.GetProperty("bind").GetString()!, binding.GetProperty("recovery_key").GetString()!) ==
        binding.GetProperty("recovery_binding").GetString());

// ---------------------------------------------------------------- the release manifests (Ed25519 of BouncyCastle)
var releases = Vector("release-manifests.json");
var keys = ReleaseKeys.Parse(releases.GetProperty("keys_text").GetString());
var app = releases.GetProperty("app");
var channel = app.GetProperty("channel").GetString()!;
Check("release: the key file reads as the hub reads it", () =>
    keys.Count == 1 && Convert.ToBase64String(keys[0]) == releases.GetProperty("public_key").GetString());
Check("release: the app's manifest verifies and its signed text is the hub's", () =>
{
    var manifest = AppManifest.Check(Encoding.UTF8.GetBytes(app.GetProperty("manifest").GetRawText()), keys, channel);
    return Encoding.UTF8.GetString(manifest.SignedText()) == app.GetProperty("signed_text").GetString();
});
foreach (var r in app.GetProperty("refused").EnumerateArray())
{
    Check("release: refused, " + r.GetProperty("name").GetString(), () => Refuses<ReleaseUntrusted>(() =>
        AppManifest.Check(Encoding.UTF8.GetBytes(r.GetProperty("manifest").GetRawText()), keys, channel)));
}
Check("release: the fleet release verifies and its refused ones do not", () =>
{
    var fleet = releases.GetProperty("fleet");
    FleetRelease.Check(Encoding.UTF8.GetBytes(fleet.GetProperty("manifest").GetRawText()), keys);
    foreach (var r in fleet.GetProperty("refused").EnumerateArray())
        if (!Refuses<ReleaseUntrusted>(() => FleetRelease.Check(Encoding.UTF8.GetBytes(r.GetProperty("manifest").GetRawText()), keys)))
            return false;
    return true;
});
Check("release: the identity as a key and S + L are refused", () =>
{
    var message = Convert.FromHexString(releases.GetProperty("message_hex").GetString()!);
    if (!Ed25519Check.Verify(keys[0], message, Convert.FromBase64String(releases.GetProperty("message_signature").GetString()!)))
        return false;
    foreach (var l in releases.GetProperty("loose").EnumerateArray())
        if (Ed25519Check.Verify(Convert.FromBase64String(l.GetProperty("public_key").GetString()!), message,
                                Convert.FromBase64String(l.GetProperty("signature").GetString()!)))
            return false;
    return true;
});

// ---------------------------------------------------------------- JSON by source generation, and the outbox
Check("json: a snapshot decodes by source generation", () =>
{
    var snapshot = HubDecode.Snapshot("""{"schema_version":1,"db":"g","time":1.5,"agents":[{"name":"manager","role":"manager","runtime":"claude","open_tasks":0,"usage":[]}],"needs":[],"tasks":[],"recent":[],"holds":[],"outcomes":[],"token":"b.1.2"}"""u8);
    return snapshot.Agents[0].Name == "manager" && snapshot.LiveToken!.State == 1;
});
Check("json: a null where a value must be is refused", () => Refuses<HubException>(() =>
    HubDecode.Snapshot("""{"schema_version":1,"db":null,"time":1.5,"agents":[],"needs":[],"tasks":[],"recent":[],"holds":[],"outcomes":[]}"""u8)));
Check("json: the outbox keeps a request and reads it back", () =>
{
    var temporary = Directory.CreateTempSubdirectory("founderizer-selfcheck-");
    try
    {
        var outbox = new Outbox(Path.Combine(temporary.FullName, "outbox.json"));
        var request = PendingRequest.New(new Uri("http://192.0.2.10:8765/"), "g", "self-check", "hello",
                                         command: OwnerCommand.Steer(3, 1));
        outbox.Save(request);
        return outbox.Load()!.Command == OwnerCommand.Steer(3, 1);
    }
    finally
    {
        temporary.Delete(recursive: true);
    }
});

// ---------------------------------------------------------------- BouncyCastle's X25519 and ChaCha20-Poly1305
Check("x25519: the vectors of RFC 7748, section 5.2 and 6.1", () =>
{
    var output = new byte[32];
    X25519.ScalarMult(Convert.FromHexString("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"), 0,
                      Convert.FromHexString("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"), 0, output, 0);
    if (Convert.ToHexStringLower(output) != "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552") return false;
    var alice = new X25519PrivateKeyParameters(Convert.FromHexString("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"));
    var bob = new X25519PrivateKeyParameters(Convert.FromHexString("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"));
    var shared = new byte[32];
    alice.GenerateSecret(bob.GeneratePublicKey(), shared, 0);
    return Convert.ToHexStringLower(alice.GeneratePublicKey().GetEncoded()) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" &&
           Convert.ToHexStringLower(shared) == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742";
});
Check("chacha20-poly1305: BouncyCastle seals what .NET opens, and the same bytes", () =>
{
    if (!System.Security.Cryptography.ChaCha20Poly1305.IsSupported) { Console.WriteLine("        (.NET has no ChaCha20-Poly1305 here: BouncyCastle alone)"); }
    var key = RandomNumberGenerator.GetBytes(32);
    var nonce = RandomNumberGenerator.GetBytes(12);
    var aad = RandomNumberGenerator.GetBytes(19);
    var plain = RandomNumberGenerator.GetBytes(1000);
    var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
    cipher.Init(true, new AeadParameters(new KeyParameter(key), 128, nonce, aad));
    var sealedBox = new byte[cipher.GetOutputSize(plain.Length)];
    var length = cipher.ProcessBytes(plain, 0, plain.Length, sealedBox, 0);
    length += cipher.DoFinal(sealedBox, length);
    if (length != plain.Length + 16) return false;
    var opener = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
    opener.Init(false, new AeadParameters(new KeyParameter(key), 128, nonce, aad));
    var opened = new byte[opener.GetOutputSize(sealedBox.Length)];
    var openedLength = opener.ProcessBytes(sealedBox, 0, sealedBox.Length, opened, 0);
    openedLength += opener.DoFinal(opened, openedLength);
    if (!opened.AsSpan(0, openedLength).SequenceEqual(plain)) return false;
    if (!System.Security.Cryptography.ChaCha20Poly1305.IsSupported) return true;
    using var boxed = new System.Security.Cryptography.ChaCha20Poly1305(key);
    var text = new byte[plain.Length];
    var tag = new byte[16];
    boxed.Encrypt(nonce, plain, text, tag, aad);
    var back = new byte[plain.Length];
    boxed.Decrypt(nonce, sealedBox.AsSpan(0, plain.Length), sealedBox.AsSpan(plain.Length, 16), back, aad);
    return back.AsSpan().SequenceEqual(plain) && sealedBox.AsSpan(0, plain.Length).SequenceEqual(text) &&
           sealedBox.AsSpan(plain.Length, 16).SequenceEqual(tag);
});

Console.WriteLine($"{passed} passed, {failed} failed");
return failed == 0 ? 0 : 1;
