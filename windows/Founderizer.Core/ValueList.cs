using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace Founderizer.Core;

/// <summary>A read-only list that is equal to another with the same items in the same order, so that a record that holds
/// one compares by value: two builds of a screen model with the same rows are equal.</summary>
public sealed class ValueList<T> : IReadOnlyList<T>, IEquatable<ValueList<T>>
{
    private readonly T[] items;

    public ValueList(IEnumerable<T> items) => this.items = items.ToArray();

    public static readonly ValueList<T> Empty = new([]);

    public T this[int index] => items[index];
    public int Count => items.Length;
    public IEnumerator<T> GetEnumerator() => ((IEnumerable<T>)items).GetEnumerator();
    IEnumerator IEnumerable.GetEnumerator() => items.GetEnumerator();

    public bool Equals(ValueList<T>? other) =>
        other is not null && (ReferenceEquals(this, other) || items.SequenceEqual(other.items));

    public override bool Equals(object? obj) => obj is ValueList<T> other && Equals(other);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var item in items) hash.Add(item);
        return hash.ToHashCode();
    }

    public override string ToString() => $"[{string.Join(", ", items)}]";
}

public static class ValueList
{
    public static ValueList<T> Of<T>(IEnumerable<T> items) => new(items);
}

/// <summary>Value equality for the hub's rows, whose lists the decoder makes anew at each read: two rows are equal when
/// they write the same JSON.</summary>
internal static class RecordValues
{
    public static bool Equal(object a, object b) => (a, b) switch
    {
        (MobileAgent x, MobileAgent y) => Same(x, y, CoreJson.Default.MobileAgent),
        (OwnerNeed x, OwnerNeed y) => Same(x, y, CoreJson.Default.OwnerNeed),
        (MobileTaskHead x, MobileTaskHead y) => Same(x, y, CoreJson.Default.MobileTaskHead),
        (MobileChatItem x, MobileChatItem y) => x.Key == y.Key && Same(x, y, CoreJson.Default.MobileChatItem),
        _ => false,
    };

    private static bool Same<T>(T a, T b, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type) =>
        JsonSerializer.SerializeToUtf8Bytes(a, type).AsSpan().SequenceEqual(JsonSerializer.SerializeToUtf8Bytes(b, type));
}
