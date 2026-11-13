using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace Founderizer.Core.Tests;

/// <summary>The shared vectors of app/vectors, which make_vectors.py made with the hub's own code. The Swift tests read
/// the same files (Tests/FleetCoreTests/SharedVectorsTests.swift).</summary>
[TestClass]
public sealed class VectorTests
{
    // ---------------------------------------------------------------- the canonical text

    [TestMethod]
    public void EachCanonicalCaseIsPythonsTextByteForByte()
    {
        var cases = Vectors.Read("canonical-json.json").GetProperty("cases");
        Assert.IsTrue(cases.GetArrayLength() >= 15);
        foreach (var c in cases.EnumerateArray())
        {
            var name = c.GetProperty("name").GetString();
            var value = CanonicalJson.Read(c.GetProperty("object").GetRawText());
            var text = CanonicalJson.Write(value);
            Assert.AreEqual(c.GetProperty("canonical").GetString(), text, name);
            Assert.AreEqual(c.GetProperty("utf8_hex").GetString(), Convert.ToHexStringLower(Encoding.UTF8.GetBytes(text)), name);
            Assert.IsTrue(CanonicalJson.IsCanonical(text), name);
        }
    }

    [TestMethod]
    public void TheFlatCasesAreWrittenFromValuesThatTheAppBuilds()
    {
        // The values as the app's own code holds them (string and long), not as the JSON reader gives them.
        foreach (var c in Vectors.Read("canonical-json.json").GetProperty("cases").EnumerateArray())
        {
            if (!c.GetProperty("flat").GetBoolean()) continue;
            var fields = new Dictionary<string, object?>();
            foreach (var p in c.GetProperty("object").EnumerateObject())
                fields[p.Name] = p.Value.ValueKind == JsonValueKind.String ? p.Value.GetString() : p.Value.GetInt64();
            Assert.AreEqual(c.GetProperty("canonical").GetString(), CanonicalJson.Write(fields),
                            c.GetProperty("name").GetString());
        }
    }

    [TestMethod]
    public void TextsThatAreNotCanonicalAreRefusedAndTheCanonicalOnesTaken()
    {
        var vector = Vectors.Read("canonical-json.json");
        foreach (var text in vector.GetProperty("not_canonical").EnumerateArray())
            Assert.IsFalse(CanonicalJson.IsCanonical(text.GetString()!), text.GetString());
        foreach (var text in vector.GetProperty("canonical_objects").EnumerateArray())
            Assert.IsTrue(CanonicalJson.IsCanonical(text.GetString()!), text.GetString());
    }

    // ---------------------------------------------------------------- the owner's signature

    [TestMethod]
    public void TheOwnerStatementIsTheBuildersTextAndItsSignatureVerifies()
    {
        var v = Vectors.Read("owner-statement.json");
        var fields = v.GetProperty("fields");
        var statement = v.GetProperty("statement").GetString()!;
        Assert.AreEqual(statement, OwnerStatement.OwnerDevice(fields.GetProperty("fleet").GetString()!,
                                                              fields.GetProperty("device").GetString()!,
                                                              fields.GetProperty("key").GetString()!,
                                                              fields.GetProperty("at").GetInt64()));
        Assert.IsTrue(CanonicalJson.IsCanonical(statement));
        Assert.AreEqual(v.GetProperty("statement_sha256_hex").GetString(),
                        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(statement))));
        var publicKey = v.GetProperty("public_key").GetString()!;
        Assert.IsTrue(OwnerSignature.Verify(publicKey, statement, v.GetProperty("signature").GetString()!));
        foreach (var c in v.GetProperty("accepted").EnumerateArray())
            Assert.IsTrue(OwnerSignature.Verify(publicKey, statement, c.GetProperty("signature").GetString()!),
                          c.GetProperty("name").GetString());
        foreach (var c in v.GetProperty("refused").EnumerateArray())
            Assert.IsFalse(OwnerSignature.Verify(publicKey, statement, c.GetProperty("signature").GetString()!),
                           c.GetProperty("name").GetString());
        // Another key, or another statement, verifies nothing.
        using var other = SoftwareOwnerKey.Create();
        Assert.IsFalse(OwnerSignature.Verify(other.PublicKey, statement, v.GetProperty("signature").GetString()!));
        Assert.IsFalse(OwnerSignature.Verify(publicKey, statement + " ", v.GetProperty("signature").GetString()!));
    }

    [TestMethod]
    public void ASoftwareKeyOfTheVectorsScalarHasItsPublicKeyAndSignsWhatTheVaultReads()
    {
        var v = Vectors.Read("owner-statement.json");
        var scalar = Convert.FromHexString(v.GetProperty("private_scalar_hex").GetString()!);
        var publicKey = v.GetProperty("public_key").GetString()!;
        var statement = v.GetProperty("statement").GetString()!;
        using var key = SoftwareOwnerKey.Import(scalar, publicKey);
        Assert.AreEqual(publicKey, key.PublicKey);
        for (var i = 0; i < 20; i++)
        {
            // .NET picks a random nonce, so each signature differs; each must be the strict DER that the vault reads.
            var signature = key.Sign(statement);
            Assert.IsTrue(Base64Strict.TryDecode(signature, out var raw));
            Assert.IsNotNull(StrictDer.Read(raw), signature);
            Assert.IsTrue(OwnerSignature.Verify(publicKey, statement, signature));
        }
    }

    // ---------------------------------------------------------------- the device binding

    [TestMethod]
    public void TheDeviceBindingIsTheHmacOfTheKeyUnderTheQRsValue()
    {
        var v = Vectors.Read("device-binding.json");
        var bind = v.GetProperty("bind").GetString()!;
        Assert.AreEqual(v.GetProperty("binding").GetString(), DeviceBinding.Binding(bind, v.GetProperty("key").GetString()!));
        Assert.AreEqual(v.GetProperty("recovery_binding").GetString(),
                        DeviceBinding.Binding(bind, v.GetProperty("recovery_key").GetString()!));
        Assert.IsTrue(DeviceBinding.Matches(bind, v.GetProperty("key").GetString()!, v.GetProperty("binding").GetString()!));
        Assert.IsFalse(DeviceBinding.Matches(bind, v.GetProperty("recovery_key").GetString()!,
                                             v.GetProperty("binding").GetString()!));
        // A value that is not 32 bytes, and a key that is not an uncompressed point, bind nothing.
        Assert.IsNull(DeviceBinding.Binding(bind[..^2], v.GetProperty("key").GetString()!));
        Assert.IsNull(DeviceBinding.Binding(bind, Convert.ToBase64String(new byte[64])));
        Assert.IsNull(DeviceBinding.Binding(bind, Convert.ToBase64String([2, .. new byte[64]])));
        Assert.AreEqual(43, DeviceBinding.NewBind().Length);
    }

    // ---------------------------------------------------------------- the release manifests

    [TestMethod]
    public void TheKeyFileIsReadAsTheHubReadsIt()
    {
        var v = Vectors.Read("release-manifests.json");
        var keys = ReleaseKeys.Parse(v.GetProperty("keys_text").GetString());
        Assert.AreEqual(1, keys.Count);
        Assert.AreEqual(v.GetProperty("public_key").GetString(), Convert.ToBase64String(keys[0]));
        foreach (var text in v.GetProperty("keys_text_refused").EnumerateArray())
            Assert.AreEqual(0, ReleaseKeys.Parse(text.GetString()).Count, text.GetString());
    }

    [TestMethod]
    public void TheAppsManifestVerifiesAndEachRefusedOneIsRefused()
    {
        var v = Vectors.Read("release-manifests.json");
        var app = v.GetProperty("app");
        var channel = app.GetProperty("channel").GetString()!;
        var keys = new[] { Convert.FromBase64String(v.GetProperty("public_key").GetString()!) };
        var data = Encoding.UTF8.GetBytes(app.GetProperty("manifest").GetRawText());
        var manifest = AppManifest.Check(data, keys, channel);
        Assert.AreEqual(app.GetProperty("signed_text").GetString(), Encoding.UTF8.GetString(manifest.SignedText()));
        Assert.AreEqual(201, manifest.Build);
        Assert.IsFalse(manifest.Hold);
        // Another key, no key, and another channel take nothing.
        var other = new[] { Convert.FromBase64String(v.GetProperty("other_public_key").GetString()!) };
        Assert.ThrowsExactly<ReleaseUntrusted>(() => AppManifest.Check(data, other, channel));
        Assert.ThrowsExactly<ReleaseUntrusted>(() => AppManifest.Check(data, [], channel));
        Assert.ThrowsExactly<ReleaseUntrusted>(() => AppManifest.Check(data, keys, "https://example.net"));
        foreach (var c in app.GetProperty("refused").EnumerateArray())
        {
            var refused = Encoding.UTF8.GetBytes(c.GetProperty("manifest").GetRawText());
            Assert.ThrowsExactly<ReleaseUntrusted>(() => AppManifest.Check(refused, keys, channel),
                                                   c.GetProperty("name").GetString());
        }
    }

    [TestMethod]
    public void TheFleetReleaseVerifiesAndEachRefusedOneIsRefused()
    {
        var v = Vectors.Read("release-manifests.json");
        var fleet = v.GetProperty("fleet");
        var keys = new[] { Convert.FromBase64String(v.GetProperty("public_key").GetString()!) };
        var release = FleetRelease.Check(Encoding.UTF8.GetBytes(fleet.GetProperty("manifest").GetRawText()), keys);
        Assert.AreEqual(fleet.GetProperty("signed_text").GetString(), Encoding.UTF8.GetString(release.SignedText()));
        foreach (var c in fleet.GetProperty("refused").EnumerateArray())
        {
            var refused = Encoding.UTF8.GetBytes(c.GetProperty("manifest").GetRawText());
            Assert.ThrowsExactly<ReleaseUntrusted>(() => FleetRelease.Check(refused, keys), c.GetProperty("name").GetString());
        }
        // A build's manifest is no fleet release, and a fleet release's signature is no build's.
        Assert.ThrowsExactly<ReleaseUntrusted>(() =>
            FleetRelease.Check(Encoding.UTF8.GetBytes(v.GetProperty("app").GetProperty("manifest").GetRawText()), keys));
    }

    [TestMethod]
    public void TheShapesThatVerifyOnlyWhereACheckIsLooseAreRefused()
    {
        var v = Vectors.Read("release-manifests.json");
        var message = Convert.FromHexString(v.GetProperty("message_hex").GetString()!);
        var good = Convert.FromBase64String(v.GetProperty("message_signature").GetString()!);
        var key = Convert.FromBase64String(v.GetProperty("public_key").GetString()!);
        Assert.IsTrue(Ed25519Check.Verify(key, message, good));
        foreach (var c in v.GetProperty("loose").EnumerateArray())
        {
            Assert.IsFalse(Ed25519Check.Verify(Convert.FromBase64String(c.GetProperty("public_key").GetString()!), message,
                                               Convert.FromBase64String(c.GetProperty("signature").GetString()!)),
                           c.GetProperty("name").GetString());
        }
    }
}

/// <summary>The canonical writer's own rules, beyond the vectors.</summary>
[TestClass]
public sealed class CanonicalJsonTests
{
    [TestMethod]
    public void KeysAreInCodePointOrderNotInUtf16Order()
    {
        var astral = char.ConvertFromUtf32(0x10000);
        var fields = new Dictionary<string, object?> { [astral] = 1L, ["\uffff"] = 2L, ["\ue000"] = 3L };
        Assert.AreEqual("{\"\ue000\":3,\"\uffff\":2,\"" + astral + "\":1}", CanonicalJson.Write(fields));
        Assert.IsTrue(string.CompareOrdinal(astral, "\uffff") < 0);     // UTF-16 order would put it first
    }

    [TestMethod]
    public void ALoneSurrogateAndAnUnknownTypeAreRefused()
    {
        Assert.ThrowsExactly<ArgumentException>(() => CanonicalJson.Write("a\ud800b"));
        Assert.ThrowsExactly<ArgumentException>(() => CanonicalJson.Write("\udc00"));
        Assert.ThrowsExactly<ArgumentException>(() => CanonicalJson.Write(1.5m));
        Assert.IsFalse(CanonicalJson.IsCanonical("{\"a\":\"\\ud800\"}"));
    }

    [TestMethod]
    public void NumbersAreWrittenAsPythonWritesThem()
    {
        Assert.AreEqual("NaN", CanonicalJson.PythonRepr(double.NaN));
        Assert.AreEqual("Infinity", CanonicalJson.PythonRepr(double.PositiveInfinity));
        Assert.AreEqual("-Infinity", CanonicalJson.PythonRepr(double.NegativeInfinity));
        Assert.AreEqual("-0.0", CanonicalJson.PythonRepr(-0.0));
        Assert.AreEqual("100.0", CanonicalJson.PythonRepr(100));
        Assert.AreEqual("1e+22", CanonicalJson.PythonRepr(1e22));
        Assert.AreEqual("123456789012345.67", CanonicalJson.PythonRepr(123456789012345.67));
        Assert.AreEqual("0.001", CanonicalJson.PythonRepr(0.001));
        Assert.AreEqual(BigInteger.Parse("123456789012345678901234567890"),
                        CanonicalJson.Read("123456789012345678901234567890"));
    }

    [TestMethod]
    public void TheEscapesArePythonsAndNothingElseIsEscaped()
    {
        Assert.AreEqual("\"\\\"\\\\\\n\\r\\t\\b\\f\\u0000\\u001f\u007f\u2028/<&'+\u00e9\"",
                        CanonicalJson.Quote("\"\\\n\r\t\b\f\u0000\u001f\u007f\u2028/<&'+\u00e9"));
    }

    [TestMethod]
    public void TheStatementBuildersWriteTheVaultsKinds()
    {
        Assert.AreEqual("{\"at\":5,\"fleet\":\"f\",\"kind\":\"pin\",\"machine\":\"app-1\",\"recipient\":\"r\",\"v\":1}",
                        OwnerStatement.Pin("f", "app-1", "r", 5));
        Assert.AreEqual("{\"at\":5,\"call\":\"c\",\"fleet\":\"f\",\"kind\":\"door-call\",\"need\":7,\"v\":1}",
                        OwnerStatement.DoorCall("f", 7, "c", 5));
        Assert.AreEqual("{\"agent\":\"dev\",\"at\":5,\"fleet\":\"f\",\"kind\":\"grant\",\"login\":\"bws://ab\",\"machine\":\"m\",\"v\":1}",
                        OwnerStatement.Grant("f", "BWS://AB", "dev", "m", 5));
    }
}
