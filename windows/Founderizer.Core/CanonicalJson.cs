using System;
using System.Buffers;
using System.Collections.Generic;
using System.Globalization;
using System.Numerics;
using System.Text;
using System.Text.Json;

namespace Founderizer.Core;

/// <summary>The canonical text of a JSON value: equal, byte for byte, to Python's
/// <c>json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)</c>, which is how vault.py and hub.py
/// check what the owner signs (vault.canonical). Written by hand: the .NET JSON writer escapes characters that Python
/// leaves as they are (windows-app-probes/dotnet-crypto-probe.txt).
///
/// The values: <see cref="string"/>, the whole numbers (<see cref="int"/>, <see cref="long"/>, <see cref="BigInteger"/>),
/// <see cref="double"/> (written as Python's repr), <see cref="bool"/>, null, an object as
/// <see cref="IEnumerable{T}"/> of <c>KeyValuePair&lt;string, object?&gt;</c>, and a list as
/// <see cref="IEnumerable{T}"/> of <c>object?</c>.</summary>
public static class CanonicalJson
{
    /// <summary>The canonical text of <paramref name="value"/>. Throws <see cref="ArgumentException"/> for a value of
    /// another type and for a string with a lone surrogate, whose text no UTF-8 encoder can write (Python's encode of
    /// such a statement fails, and vault.owner_signed refuses it).</summary>
    public static string Write(object? value)
    {
        var text = new StringBuilder();
        Append(text, value, 0);
        return text.ToString();
    }

    /// <summary>The value of a JSON text as Python's <c>json.loads</c> reads it: an object is a dictionary whose last
    /// value of a key wins, a number without a fraction or an exponent is a whole number of any size, and every other
    /// number is a double. Throws <see cref="JsonException"/> for a text that is not JSON.</summary>
    public static object? Read(string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        var reader = new Utf8JsonReader(bytes, new JsonReaderOptions { CommentHandling = JsonCommentHandling.Disallow });
        if (!reader.Read()) throw new JsonException("no value");
        var value = ReadValue(ref reader, 0);
        if (reader.Read()) throw new JsonException("more after the value");
        return value;
    }

    /// <summary>The text is the canonical form of what it holds: <c>canonical(json.loads(text)) == text</c>, which is
    /// the check of vault.owner_statement and hub.certify_device.</summary>
    public static bool IsCanonical(string text)
    {
        try
        {
            return Write(Read(text)) == text;
        }
        catch (Exception e) when (e is JsonException or ArgumentException or InvalidOperationException or FormatException)
        {
            return false;
        }
    }

    /// <summary>One string as Python's encoder writes it with ensure_ascii=False: `"` and `\` escaped, the five control
    /// characters that have a short escape with it, every other one below U+0020 as \u and four lower-case hex digits,
    /// and everything else as it is, U+007F and the line separators too.</summary>
    public static string Quote(string text)
    {
        var output = new StringBuilder(text.Length + 2);
        AppendString(output, text);
        return output.ToString();
    }

    /// <summary>Python's order of keys: by code point. UTF-16 order differs from it for a character above U+FFFF against
    /// one from U+E000 to U+FFFF.</summary>
    public static readonly IComparer<string> CodePointOrder = Comparer<string>.Create(CompareCodePoints);

    private static int CompareCodePoints(string? a, string? b)
    {
        if (ReferenceEquals(a, b)) return 0;
        if (a is null) return -1;
        if (b is null) return 1;
        var n = Math.Min(a.Length, b.Length);
        for (var i = 0; i < n; i++)
        {
            int x = a[i], y = b[i];
            if (x == y) continue;
            // ICU's code point order fix-up: surrogates move above U+FFFF, U+E000..U+FFFF move down below them.
            if (x >= 0xD800) x += x >= 0xE000 ? -0x800 : 0x2000;
            if (y >= 0xD800) y += y >= 0xE000 ? -0x800 : 0x2000;
            return x.CompareTo(y);
        }
        return a.Length.CompareTo(b.Length);
    }

    private const int Deepest = 64;

    private static void Append(StringBuilder output, object? value, int depth)
    {
        if (depth > Deepest) throw new ArgumentException("the value is nested too deep");
        switch (value)
        {
            case null: output.Append("null"); break;
            case string text: AppendString(output, text); break;
            case bool flag: output.Append(flag ? "true" : "false"); break;
            case int number: output.Append(number.ToString(CultureInfo.InvariantCulture)); break;
            case long number: output.Append(number.ToString(CultureInfo.InvariantCulture)); break;
            case BigInteger number: output.Append(number.ToString(CultureInfo.InvariantCulture)); break;
            case double number: output.Append(PythonRepr(number)); break;
            case IEnumerable<KeyValuePair<string, object?>> fields:
                var pairs = new List<KeyValuePair<string, object?>>(fields);
                pairs.Sort((x, y) => CompareCodePoints(x.Key, y.Key));
                output.Append('{');
                for (var i = 0; i < pairs.Count; i++)
                {
                    if (i > 0)
                    {
                        if (pairs[i].Key == pairs[i - 1].Key) throw new ArgumentException("one key twice");
                        output.Append(',');
                    }
                    AppendString(output, pairs[i].Key);
                    output.Append(':');
                    Append(output, pairs[i].Value, depth + 1);
                }
                output.Append('}');
                break;
            case IEnumerable<object?> items:
                output.Append('[');
                var first = true;
                foreach (var item in items)
                {
                    if (!first) output.Append(',');
                    first = false;
                    Append(output, item, depth + 1);
                }
                output.Append(']');
                break;
            default:
                throw new ArgumentException($"a canonical text holds no {value.GetType().Name}");
        }
    }

    private static void AppendString(StringBuilder output, string text)
    {
        output.Append('"');
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            switch (c)
            {
                case '"': output.Append("\\\""); break;
                case '\\': output.Append("\\\\"); break;
                case '\n': output.Append("\\n"); break;
                case '\r': output.Append("\\r"); break;
                case '\t': output.Append("\\t"); break;
                case '\b': output.Append("\\b"); break;
                case '\f': output.Append("\\f"); break;
                default:
                    if (c < 0x20)
                    {
                        output.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else if (char.IsHighSurrogate(c))
                    {
                        if (i + 1 >= text.Length || !char.IsLowSurrogate(text[i + 1]))
                            throw new ArgumentException("a lone surrogate");
                        output.Append(c).Append(text[++i]);
                    }
                    else if (char.IsLowSurrogate(c))
                    {
                        throw new ArgumentException("a lone surrogate");
                    }
                    else
                    {
                        output.Append(c);
                    }
                    break;
            }
        }
        output.Append('"');
    }

    /// <summary>A double as Python's float.__repr__ writes it: the shortest digits that read back as the same double
    /// (.NET's "R" gives the same digits since .NET Core 3.0), fixed notation with ".0" while the decimal exponent is from
    /// -4 to 16, and the exponent form with "e", a sign and at least two digits otherwise; NaN and Infinity as
    /// json.dumps writes them.</summary>
    public static string PythonRepr(double value)
    {
        if (double.IsNaN(value)) return "NaN";
        if (double.IsPositiveInfinity(value)) return "Infinity";
        if (double.IsNegativeInfinity(value)) return "-Infinity";
        var negative = double.IsNegative(value);
        var shortest = Math.Abs(value).ToString("R", CultureInfo.InvariantCulture);
        var exponent = 0;
        var e = shortest.IndexOfAny(['E', 'e']);
        if (e >= 0)
        {
            exponent = int.Parse(shortest.AsSpan(e + 1), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
            shortest = shortest[..e];
        }
        var point = shortest.IndexOf('.');
        var whole = point >= 0 ? shortest[..point] : shortest;
        var fraction = point >= 0 ? shortest[(point + 1)..] : "";
        var digits = whole + fraction;
        var decimalPoint = whole.Length + exponent;         // the value is 0.<digits> * 10^decimalPoint
        var lead = 0;
        while (lead < digits.Length && digits[lead] == '0') lead++;
        digits = digits[lead..];
        decimalPoint -= lead;
        digits = digits.TrimEnd('0');
        var sign = negative ? "-" : "";
        if (digits.Length == 0) return sign + "0.0";
        if (decimalPoint > -4 && decimalPoint <= 16)
        {
            if (decimalPoint <= 0) return sign + "0." + new string('0', -decimalPoint) + digits;
            if (decimalPoint >= digits.Length) return sign + digits + new string('0', decimalPoint - digits.Length) + ".0";
            return sign + digits[..decimalPoint] + "." + digits[decimalPoint..];
        }
        var power = decimalPoint - 1;
        var mantissa = digits.Length > 1 ? digits[..1] + "." + digits[1..] : digits;
        return sign + mantissa + "e" + (power < 0 ? "-" : "+") +
               Math.Abs(power).ToString("00", CultureInfo.InvariantCulture);
    }

    private static object? ReadValue(ref Utf8JsonReader reader, int depth)
    {
        if (depth > Deepest) throw new JsonException("nested too deep");
        switch (reader.TokenType)
        {
            case JsonTokenType.Null: return null;
            case JsonTokenType.True: return true;
            case JsonTokenType.False: return false;
            case JsonTokenType.String: return reader.GetString();
            case JsonTokenType.Number:
                var raw = Encoding.UTF8.GetString(reader.HasValueSequence ? reader.ValueSequence.ToArray() : reader.ValueSpan);
                if (raw.AsSpan().IndexOfAny('.', 'e', 'E') < 0)
                    return BigInteger.Parse(raw, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
                return double.Parse(raw, NumberStyles.Float, CultureInfo.InvariantCulture);
            case JsonTokenType.StartArray:
                var items = new List<object?>();
                while (reader.Read() && reader.TokenType != JsonTokenType.EndArray) items.Add(ReadValue(ref reader, depth + 1));
                return items;
            case JsonTokenType.StartObject:
                var fields = new Dictionary<string, object?>(StringComparer.Ordinal);
                while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
                {
                    var key = reader.GetString()!;
                    reader.Read();
                    fields[key] = ReadValue(ref reader, depth + 1);
                }
                return fields;
            default:
                throw new JsonException("not a JSON value");
        }
    }
}

/// <summary>What the owner signs, in the one spelling that the central vault and the door check (FleetCore's
/// OwnerStatement): a flat object of text and whole numbers in its canonical text, with `v` 1, its `kind`, the fleet and
/// the time in whole Unix seconds.</summary>
public static class OwnerStatement
{
    private static string Make(string kind, string fleet, long at, params (string Key, object Value)[] fields)
    {
        var all = new Dictionary<string, object?> { ["v"] = 1L, ["kind"] = kind, ["fleet"] = fleet, ["at"] = at };
        foreach (var (key, value) in fields) all[key] = value;
        return CanonicalJson.Write(all);
    }

    public static string Pin(string fleet, string machine, string recipient, long at) =>
        Make("pin", fleet, at, ("machine", machine), ("recipient", recipient));

    public static string Unpin(string fleet, string machine, long at) => Make("unpin", fleet, at, ("machine", machine));

    public static string Recovery(string fleet, string recipient, long at) =>
        Make("recovery", fleet, at, ("recipient", recipient));

    public static string Grant(string fleet, string login, string agent, string machine, long at) =>
        Make("grant", fleet, at, ("login", login.ToLowerInvariant()), ("agent", agent), ("machine", machine));

    public static string Ungrant(string fleet, string login, string agent, long at) =>
        Make("ungrant", fleet, at, ("login", login.ToLowerInvariant()), ("agent", agent));

    public static string Pool(string fleet, string login, long at) =>
        Make("pool", fleet, at, ("login", login.ToLowerInvariant()));

    public static string Unpool(string fleet, string login, long at) =>
        Make("unpool", fleet, at, ("login", login.ToLowerInvariant()));

    /// <summary>The owner's yes to one door call, for the Needs-you item <paramref name="need"/>.</summary>
    public static string DoorCall(string fleet, long need, string call, long at) =>
        Make("door-call", fleet, at, ("need", need), ("call", call));

    /// <summary>The owner's mode of one server (`door_modes`).</summary>
    public static string DoorMode(string fleet, string host, string mode, long at) =>
        Make("door-mode", fleet, at, ("host", host), ("mode", mode));

    /// <summary>The owner key's certificate of one device's own signing key (hub.certify_device).</summary>
    public static string OwnerDevice(string fleet, string device, string key, long at) =>
        Make("owner-device", fleet, at, ("device", device), ("key", key));

    /// <summary>Whole Unix seconds now.</summary>
    public static long Now() => DateTimeOffset.UtcNow.ToUnixTimeSeconds();
}
