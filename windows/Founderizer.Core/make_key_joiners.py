"""Writes KeyJoiners.cs from the `tables` of app/vectors/key-in-text.json, which FleetCore's KeyInTextVectorsTests measures
on a Mac: the joiners that the key rule holds as written lists, not from .NET's own Unicode data. KeyHoldTests holds the
two equal. Run from app/windows: python3 Founderizer.Core/make_key_joiners.py"""
import json
import os

here = os.path.dirname(os.path.abspath(__file__))
tables = json.load(open(os.path.join(here, '..', '..', 'vectors', 'key-in-text.json'), encoding='utf-8'))['tables']


def table(name, ranges, width):
    pairs = [f'({first:#06x}, {last:#06x})' if last <= 0xFFFF else f'({first:#07x}, {last:#07x})' for first, last in ranges]
    lines = []
    line = '        '
    for pair in pairs:
        item = pair + ', '
        if len(line) + len(item) > width:
            lines.append(line.rstrip())
            line = '        '
        line += item
    lines.append(line.rstrip())
    count = sum(last - first + 1 for first, last in ranges)
    return name, count, len(ranges), '\n'.join(lines)


marks = table('AddressMarks', tables['address_marks'], 120)
skips = table('BoundarySkips', tables['boundary_skips'], 120)
source = f'''// Written by make_key_joiners.py from app/vectors/key-in-text.json's `tables`: change that file, then run the script.
namespace Founderizer.Core;

public static partial class KeyInText
{{
    /// <summary>**The units of the first plane after which a word's <c>://</c>, <c>?</c> or <c>#</c> does not count**
    /// ({marks[1]:,} units in {marks[2]} ranges <c>[first, last]</c>): <c>tables.address_marks</c> of the shared vectors,
    /// measured with Foundation's search on the Mac that wrote them (<see cref="Words.ExtendsFind"/>).</summary>
    internal static readonly (int First, int Last)[] AddressMarks =
    [
{marks[3]}
    ];

    /// <summary>**The scalars that a shape's <c>\\b</c> looks past**, at the place itself and going back ({skips[1]:,}
    /// scalars in {skips[2]} ranges): <c>tables.boundary_skips</c> of the shared vectors, measured with ICU's word boundary
    /// on the Mac that wrote them (<see cref="Boundary"/>).</summary>
    internal static readonly (int First, int Last)[] BoundarySkips =
    [
{skips[3]}
    ];
}}
'''
open(os.path.join(here, 'KeyJoiners.cs'), 'w', encoding='utf-8', newline='\n').write(source)
print('KeyJoiners.cs:', marks[1], 'address marks in', marks[2], 'ranges;', skips[1], 'boundary skips in', skips[2], 'ranges')
