using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace Founderizer.Setup.Cloud;

/// <summary>**The words of the list in which the owner chooses a server he has at a provider, or a new one** (the Mac's
/// <c>CloudChoice.swift</c>, the parts that need nothing but the provider's own data). The rules that need the install's
/// systems, the hub's list of servers or this PC's records of its builds (<c>unfit</c>, <c>reuse</c>, <c>hubAgain</c>,
/// <c>FleetKnown</c>, <c>MadeServers</c>, <c>InstallEnds</c>, <c>EarlierServerLines</c>) come with pieces L3 and L4,
/// which hold those.</summary>
public sealed partial record CloudExisting
{
    /// <summary>Its row's detail: the type at Hetzner, the memory, the system, and the project at DigitalOcean
    /// ("CX23 · 4 GB · Ubuntu 24.04").</summary>
    public string Summary
    {
        get
        {
            var parts = new List<string>();
            if (Type.Length > 0 && !Type.Contains('-')) parts.Add(Type.ToUpperInvariant());
            if (MemoryMb is { } memory) parts.Add(Size(memory));
            if (System is { } system && Version is { } version) parts.Add(SystemName(system) + " " + version);
            if (Project is { } project) parts.Add(project);
            return string.Join(" · ", parts);
        }
    }

    /// <summary>A system's name as the installs say it: the Mac's table names Ubuntu and Debian as their ids written with
    /// a capital, and any other id is written so too.</summary>
    internal static string SystemName(string id) =>
        string.Join(" ", id.Split(' ').Select(w => w.Length == 0 ? w : char.ToUpperInvariant(w[0]) + w[1..].ToLowerInvariant()));

    /// <summary>"4 GB", "1.5 GB", "512 MB".</summary>
    public static string Size(int megabytes)
    {
        if (megabytes < 1024) return megabytes.ToString(CultureInfo.InvariantCulture) + " MB";
        if (megabytes % 1024 == 0) return (megabytes / 1024).ToString(CultureInfo.InvariantCulture) + " GB";
        // One decimal, rounded as printf rounds an exact binary value: half to even.
        var tenths = Math.DivRem((long)megabytes * 10, 1024L, out var rest);
        if (rest * 2 > 1024 || (rest * 2 == 1024 && tenths % 2 == 1)) tenths += 1;
        return (tenths / 10).ToString(CultureInfo.InvariantCulture) + "." + (tenths % 10).ToString(CultureInfo.InvariantCulture) + " GB";
    }
}

public sealed partial record CloudOffer
{
    /// <summary>"CX23 · 2 vCPU · 4 GB · 40 GB": the type at Hetzner, then what it is made of.</summary>
    public string Size
    {
        get
        {
            var parts = new List<string>();
            if (Provider == CloudProvider.Hetzner) parts.Add(Type.ToUpperInvariant());
            if (Cores is { } cores) parts.Add(cores.ToString(CultureInfo.InvariantCulture) + " vCPU");
            if (MemoryGb is { } memory) parts.Add(CloudExisting.Size(CloudServers.Megabytes(memory)));
            if (DiskGb is { } disk) parts.Add(disk.ToString(CultureInfo.InvariantCulture) + " GB");
            return string.Join(" · ", parts);
        }
    }

    /// <summary>**One row of the list of a provider's types**: "CX23 · 2 cores · 4 GB · Nuremberg", and the price beside it
    /// (<see cref="Amount"/>). Another provider's row has no type.</summary>
    public string Choice
    {
        get
        {
            var parts = new List<string>();
            if (Provider == CloudProvider.Hetzner) parts.Add(Type.ToUpperInvariant());
            if (Cores is { } cores) parts.Add(CoresWords(cores, Dedicated));
            if (MemoryGb is { } memory) parts.Add(CloudExisting.Size(CloudServers.Megabytes(memory)));
            parts.Add(City);
            return string.Join(" · ", parts);
        }
    }

    /// <summary>"€5.49 a month", in this PC's own way of writing an amount.</summary>
    public string Monthly(CultureInfo? culture = null) => Amount(culture) + " a month";

    /// <summary>"€5.49": a month's price alone, with two decimals, in the currency that the provider gave.</summary>
    public string Amount(CultureInfo? culture = null)
    {
        var format = (NumberFormatInfo)(culture ?? CultureInfo.CurrentCulture).NumberFormat.Clone();
        format.CurrencySymbol = Currency switch { "EUR" => "€", "USD" => "$", "GBP" => "£", _ => Currency };
        format.CurrencyDecimalDigits = 2;
        return MonthlyPrice.ToString("C", format);
    }

    /// <summary>The new server's row in the list: "CX23 · 4 GB · Nuremberg · €5.49 a month".</summary>
    public string Row(CultureInfo? culture = null)
    {
        var parts = new List<string>();
        if (Provider == CloudProvider.Hetzner) parts.Add(Type.ToUpperInvariant());
        if (MemoryGb is { } memory) parts.Add(CloudExisting.Size(CloudServers.Megabytes(memory)));
        parts.Add(City);
        parts.Add(Monthly(culture));
        return string.Join(" · ", parts);
    }

    /// <summary>The line under a server on the first run's page "Your fleet": "CX23 · €5.49 a month"; another provider's
    /// gives the server's memory in place of the type.</summary>
    public string Brief(CultureInfo? culture = null)
    {
        var parts = new List<string>();
        if (Provider == CloudProvider.Hetzner) parts.Add(Type.ToUpperInvariant());
        else if (MemoryGb is { } memory) parts.Add(CloudExisting.Size(CloudServers.Megabytes(memory)));
        parts.Add(Monthly(culture));
        return string.Join(" · ", parts);
    }

    /// <summary>The capsule under a server on "Your fleet": "Hetzner · CX23 · €5.49 a month".</summary>
    public string Pick(CultureInfo? culture = null) => Provider.Name() + " · " + Brief(culture);

    /// <summary>The city of its location, without its country.</summary>
    private string City => Place.Split(',')[0];

    /// <summary>"2 cores", or "2 own cores" for a type whose cores no other server shares.</summary>
    internal static string CoresWords(int count, bool dedicated) => (count, dedicated) switch
    {
        (1, false) => "1 core",
        (1, true) => "1 own core",
        (_, false) => count.ToString(CultureInfo.InvariantCulture) + " cores",
        _ => count.ToString(CultureInfo.InvariantCulture) + " own cores",
    };
}
