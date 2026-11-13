using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Founderizer.Windows.Pages;

/// <summary>One row's place in a list: the list keeps the holder, and a new model of the same row changes the holder's
/// item, which its view draws again in place; so the row keeps its view, and a field in it keeps the caret.</summary>
internal sealed class Holder<T> where T : class
{
    public Holder(T item) => Item = item;

    public T Item { get; private set; }

    public event Action? Changed;

    public void Set(T item)
    {
        if (Item.Equals(item)) return;
        Item = item;
        Changed?.Invoke();
    }
}

/// <summary>The rows of a virtualized list (an ItemsRepeater's source), kept in step with each new model: each row that
/// went is removed, each new one inserted and each moved one moved; a changed row is drawn again in its own view, and a
/// row that is equal stays as it is drawn. A row whose <paramref name="slot"/> changes gets a new view.</summary>
internal sealed class KeyedItems<T> where T : class
{
    private readonly Func<T, string> key;
    private readonly Func<T, int> slot;

    public KeyedItems(Func<T, string> key, Func<T, int>? slot = null)
    {
        this.key = key;
        this.slot = slot ?? (_ => 0);
    }

    public ObservableCollection<Holder<T>> Items { get; } = new();

    public void Show(IReadOnlyList<T> next)
    {
        var items = Items;
        var slots = new Dictionary<string, int>();
        foreach (var item in next) slots[key(item)] = slot(item);
        for (int i = items.Count - 1; i >= 0; i--)
            if (!slots.TryGetValue(key(items[i].Item), out var s) || s != slot(items[i].Item)) items.RemoveAt(i);
        for (int i = 0; i < next.Count; i++)
        {
            var item = next[i];
            var k = key(item);
            if (i < items.Count && key(items[i].Item) == k)
            {
                items[i].Set(item);
                continue;
            }
            int at = -1;
            for (int j = i + 1; j < items.Count; j++) if (key(items[j].Item) == k) { at = j; break; }
            if (at >= 0)
            {
                items.Move(at, i);
                items[i].Set(item);
            }
            else items.Insert(i, new Holder<T>(item));
        }
        while (items.Count > next.Count) items.RemoveAt(items.Count - 1);
    }
}

/// <summary>A view that draws one held row, and lets go of it when the list takes the view back.</summary>
internal abstract class HeldView<T> : Grid where T : class
{
    private Holder<T>? holder;

    public void Hold(Holder<T>? next)
    {
        if (holder is not null) holder.Changed -= Redraw;
        holder = next;
        if (holder is null) return;
        holder.Changed += Redraw;
        Redraw();
    }

    private void Redraw() => Draw(holder!.Item);

    protected abstract void Draw(T item);
}

/// <summary>Makes and reuses the views of a list whose rows are of one kind.</summary>
internal sealed class ViewFactory<T, TView> : IElementFactory where T : class where TView : HeldView<T>
{
    private readonly Func<TView> make;
    private readonly Stack<TView> free = new();

    public ViewFactory(Func<TView> make) => this.make = make;

    public UIElement GetElement(ElementFactoryGetArgs args)
    {
        var view = free.Count > 0 ? free.Pop() : make();
        view.Hold((Holder<T>)args.Data);
        return view;
    }

    public void RecycleElement(ElementFactoryRecycleArgs args)
    {
        if (args.Element is not TView view) return;
        view.Hold(null);
        free.Push(view);
    }
}
