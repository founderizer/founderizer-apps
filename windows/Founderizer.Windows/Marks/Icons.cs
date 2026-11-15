using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Founderizer.Windows.Marks;

/// <summary>An icon of the approved pictures: path data in a square of <see cref="Side"/> (20, or 12 for a chevron).</summary>
public sealed record Icon(double Side, string Data);

/// <summary>The icons of the approved pictures that Segoe Fluent Icons does not have, as the pictures draw them (their
/// source names each one). Back, Forward, Search and Settings come from Segoe Fluent Icons, which Windows has.
///
/// The paths are from Fluent System Icons, @fluentui/svg-icons 1.1.340, with each move after a "z" written as an
/// absolute "M": SVG starts a relative "m" after "z" from the figure's first point, XAML from the last point drawn.
/// Copyright (c) 2020 Microsoft Corporation. MIT License: permission is hereby granted, free of charge, to any person
/// obtaining a copy of this software, to deal in the software without restriction, provided that this copyright notice
/// and this permission notice are included in all copies or substantial portions of the software. THE SOFTWARE IS
/// PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
/// </summary>
public static class Icons
{
    /// <summary>chat_warning_20_regular, a square of 20.</summary>
    public static readonly Icon NeedsYou = new(20, "M10 2a8 8 0 1 1 -3.61 15.14l-0.12 -0.07l-3.65 0.92a0.5 0.5 0 0 1 -0.62 -0.45v-0.08l0.01 -0.08l0.92 -3.64l-0.07 -0.12a8 8 0 0 1 -0.83 -2.9l-0.02 -0.37L2 10a8 8 0 0 1 8 -8m0 1a7 7 0 0 0 -6.1 10.42a0.5 0.5 0 0 1 0.06 0.28l-0.02 0.1l-0.75 3.01l3.02 -0.75l0.19 -0.01l0.09 0.02l0.09 0.04A7 7 0 1 0 10 3m0 2.5c0.28 0 0.5 0.22 0.5 0.5v5.5a0.5 0.5 0 0 1 -1 0V6c0 -0.28 0.22 -0.5 0.5 -0.5m0 9a0.75 0.75 0 1 0 0 -1.5a0.75 0.75 0 0 0 0 1.5");
    /// <summary>board_20_regular, a square of 20.</summary>
    public static readonly Icon Tasks = new(20, "M3 6a3 3 0 0 1 3 -3h8a3 3 0 0 1 3 3v8a3 3 0 0 1 -3 3H6a3 3 0 0 1 -3 -3zM6 4a2 2 0 0 0 -2 2v1.06L9.5 7V4zM10.5 4v8H16V6a2 2 0 0 0 -2 -2zM16 13h-5.5v3H14a2 2 0 0 0 2 -2zM9.5 16V8L4 8.06V14c0 1.1 0.9 2 2 2z");
    /// <summary>add_20_regular, a square of 20.</summary>
    public static readonly Icon Add = new(20, "M10 2.5c0.28 0 0.5 0.22 0.5 0.5v6.5H17a0.5 0.5 0 0 1 0 1h-6.5V17a0.5 0.5 0 0 1 -1 0v-6.5H3a0.5 0.5 0 0 1 0 -1h6.5V3c0 -0.28 0.22 -0.5 0.5 -0.5");
    /// <summary>calendar_20_regular, a square of 20.</summary>
    public static readonly Icon Calendar = new(20, "M7 11a1 1 0 1 0 0 -2a1 1 0 0 0 0 2m1 2a1 1 0 1 1 -2 0a1 1 0 0 1 2 0m2 -2a1 1 0 1 0 0 -2a1 1 0 0 0 0 2m1 2a1 1 0 1 1 -2 0a1 1 0 0 1 2 0m2 -2a1 1 0 1 0 0 -2a1 1 0 0 0 0 2m4 -5.5A2.5 2.5 0 0 0 14.5 3h-9A2.5 2.5 0 0 0 3 5.5v9A2.5 2.5 0 0 0 5.5 17h9a2.5 2.5 0 0 0 2.5 -2.5zM4 7h12v7.5c0 0.83 -0.67 1.5 -1.5 1.5h-9A1.5 1.5 0 0 1 4 14.5zM5.5 4h9c0.83 0 1.5 0.67 1.5 1.5V6H4v-0.5C4 4.67 4.67 4 5.5 4");
    /// <summary>chevron_down_12_regular, a square of 12.</summary>
    public static readonly Icon ChevronDown = new(12, "M2.15 4.65c0.2 -0.2 0.5 -0.2 0.7 0L6 7.79l3.15 -3.14a0.5 0.5 0 1 1 0.7 0.7l-3.5 3.5a0.5 0.5 0 0 1 -0.7 0l-3.5 -3.5a0.5 0.5 0 0 1 0 -0.7");
    /// <summary>chevron_right_12_regular, a square of 12.</summary>
    public static readonly Icon ChevronRight = new(12, "M4.65 2.15a0.5 0.5 0 0 0 0 0.7L7.79 6L4.65 9.15a0.5 0.5 0 1 0 0.7 0.7l3.5 -3.5a0.5 0.5 0 0 0 0 -0.7l-3.5 -3.5a0.5 0.5 0 0 0 -0.7 0");
    /// <summary>desktop_20_regular, a square of 20.</summary>
    public static readonly Icon Desktop = new(20, "M4 2a2 2 0 0 0 -2 2v9c0 1.1 0.9 2 2 2h3v2H5.5a0.5 0.5 0 0 0 0 1h9a0.5 0.5 0 0 0 0 -1H13v-2h3a2 2 0 0 0 2 -2V4a2 2 0 0 0 -2 -2zM12 15v2H8v-2zM3 4a1 1 0 0 1 1 -1h12a1 1 0 0 1 1 1v9a1 1 0 0 1 -1 1H4a1 1 0 0 1 -1 -1z");
    /// <summary>hourglass_half_20_regular, a square of 20.</summary>
    public static readonly Icon Hourglass = new(20, "M13.69 14.6q0.3 0.67 0.31 1.4H6a3.4 3.4 0 0 1 1.22 -2.56l1.82 -1.52a2.5 2.5 0 0 0 0.9 -1.92h0.12q0.02 0.56 0.29 1.06q0.23 0.5 0.65 0.85l1.78 1.53q0.59 0.47 0.91 1.16m-8.5 3.24q0.35 0.16 0.73 0.16h8.16a1.9 1.9 0 0 0 1.76 -1.2q0.15 -0.34 0.16 -0.72a5 5 0 0 0 -0.5 -2.31a5 5 0 0 0 -1.44 -1.87l-1.82 -1.52a0.5 0.5 0 0 1 0 -0.77l1.82 -1.52A5.3 5.3 0 0 0 16 3.92a1.9 1.9 0 0 0 -1.2 -1.76Q14.46 2 14.08 2H5.92a1.9 1.9 0 0 0 -1.76 1.2Q4 3.54 4 3.92q0 1.24 0.5 2.3q0.49 1.08 1.44 1.87l1.82 1.53q0.09 0.06 0.13 0.17a0.5 0.5 0 0 1 -0.13 0.6l-1.82 1.5a6 6 0 0 0 -1.44 1.88a5 5 0 0 0 -0.5 2.3a1.9 1.9 0 0 0 1.2 1.77m9.22 -0.91a1 1 0 0 1 -0.37 0.07H5.96q-0.2 0 -0.37 -0.08t-0.3 -0.2a1 1 0 0 1 -0.22 -0.3a1 1 0 0 1 -0.07 -0.38a4.5 4.5 0 0 1 1.58 -3.37l1.82 -1.52A1.5 1.5 0 0 0 8.94 10a1.5 1.5 0 0 0 -0.54 -1.16L6.58 7.33A4 4 0 0 1 5.4 5.82A4 4 0 0 1 5 3.96q0 -0.2 0.08 -0.37q0.06 -0.17 0.2 -0.3q0.14 -0.15 0.3 -0.22A1 1 0 0 1 5.97 3h8.08q0.2 0.02 0.37 0.08t0.3 0.2a1 1 0 0 1 0.29 0.68a4.4 4.4 0 0 1 -1.58 3.37L11.6 8.84q-0.25 0.21 -0.4 0.52a1.5 1.5 0 0 0 0.4 1.79l1.82 1.52A4.4 4.4 0 0 1 15 16.04q-0.02 0.2 -0.08 0.37t-0.2 0.3q-0.15 0.15 -0.31 0.22");
    /// <summary>pause_20_regular, a square of 20.</summary>
    public static readonly Icon Pause = new(20, "M5 2a2 2 0 0 0 -2 2v12c0 1.1 0.9 2 2 2h2a2 2 0 0 0 2 -2V4a2 2 0 0 0 -2 -2zM4 4a1 1 0 0 1 1 -1h2a1 1 0 0 1 1 1v12a1 1 0 0 1 -1 1H5a1 1 0 0 1 -1 -1zM13 2a2 2 0 0 0 -2 2v12c0 1.1 0.9 2 2 2h2a2 2 0 0 0 2 -2V4a2 2 0 0 0 -2 -2zM12 4a1 1 0 0 1 1 -1h2a1 1 0 0 1 1 1v12a1 1 0 0 1 -1 1h-2a1 1 0 0 1 -1 -1z");
    /// <summary>people_20_regular, a square of 20.</summary>
    public static readonly Icon People = new(20, "M4.5 6.75a2.25 2.25 0 1 1 4.5 0a2.25 2.25 0 0 1 -4.5 0M6.75 3.5a3.25 3.25 0 1 0 0 6.5a3.25 3.25 0 0 0 0 -6.5m5.69 11.65q0.79 0.33 2.06 0.35c1.88 0 2.92 -0.67 3.47 -1.43a3 3 0 0 0 0.53 -1.5v-0.07c0 -0.83 -0.67 -1.5 -1.5 -1.5h-4.63q0.36 0.44 0.53 1H17c0.28 0 0.5 0.22 0.5 0.5v0.1l-0.04 0.22q-0.05 0.29 -0.3 0.66c-0.33 0.46 -1.04 1.02 -2.66 1.02q-1.08 -0.01 -1.69 -0.28q-0.12 0.43 -0.37 0.93M1.5 13c0 -1.1 0.9 -2 2 -2H10a2 2 0 0 1 2 2v0.08l-0.01 0.18q-0.01 0.17 -0.08 0.45c-0.08 0.37 -0.25 0.86 -0.6 1.36c-0.7 1.01 -2.05 1.93 -4.56 1.93s-3.87 -0.92 -4.57 -1.93a4 4 0 0 1 -0.68 -1.99V13m1 0.06v0.1l0.06 0.33c0.07 0.27 0.2 0.64 0.45 1C3.49 15.2 4.5 16 6.75 16s3.26 -0.8 3.74 -1.5a3 3 0 0 0 0.5 -1.42l0.01 -0.02V13a1 1 0 0 0 -1 -1H3.5a1 1 0 0 0 -1 1zM13 7.5a1.5 1.5 0 1 1 3 0a1.5 1.5 0 0 1 -3 0M14.5 5a2.5 2.5 0 1 0 0 5a2.5 2.5 0 0 0 0 -5");
    /// <summary>stop_20_regular, a square of 20.</summary>
    public static readonly Icon Stop = new(20, "M15.5 4c0.28 0 0.5 0.22 0.5 0.5v11a0.5 0.5 0 0 1 -0.5 0.5h-11a0.5 0.5 0 0 1 -0.5 -0.5v-11c0 -0.28 0.22 -0.5 0.5 -0.5zM4.5 3C3.67 3 3 3.67 3 4.5v11c0 0.83 0.67 1.5 1.5 1.5h11c0.83 0 1.5 -0.67 1.5 -1.5v-11c0 -0.83 -0.67 -1.5 -1.5 -1.5z");

    // The icons of the second set of pictures (windows-app-pictures-2.html).
    /// <summary>arrow_clockwise_12_regular, a square of 12.</summary>
    public static readonly Icon Refresh = new(12, "M8.97 6.45C9 6.2 9.2 6 9.45 6c0.3 0 0.55 0.25 0.51 0.54A4 4 0 1 1 9 3.35V2.5a0.5 0.5 0 0 1 1 0v2a0.5 0.5 0 0 1 -0.5 0.5h-2a0.5 0.5 0 0 1 0 -1h0.74A3 3 0 0 0 3 6a3 3 0 0 0 5.97 0.45");
    /// <summary>checkmark_12_regular, a square of 12.</summary>
    public static readonly Icon Check = new(12, "M9.85 3.15c0.2 0.2 0.2 0.5 0 0.7l-4.5 4.5a0.5 0.5 0 0 1 -0.7 0l-2 -2a0.5 0.5 0 1 1 0.7 -0.7L5 7.29l4.15 -4.14c0.2 -0.2 0.5 -0.2 0.7 0");
    /// <summary>checkmark_circle_48_regular, a square of 48.</summary>
    public static readonly Icon CheckCircle = new(48, "M24 4a20 20 0 1 1 0 40a20 20 0 0 1 0 -40m0 2.5a17.5 17.5 0 1 0 0 35a17.5 17.5 0 0 0 0 -35m8.63 11.12c0.5 0.48 0.5 1.28 0 1.76l-11 11c-0.48 0.5 -1.28 0.5 -1.76 0l-4.5 -4.5a1.25 1.25 0 0 1 1.76 -1.76l3.62 3.61l10.12 -10.11a1.25 1.25 0 0 1 1.76 0");
    /// <summary>chevron_right_16_regular, a square of 16.</summary>
    public static readonly Icon ChevronRight16 = new(16, "M5.65 3.15a0.5 0.5 0 0 0 0 0.7L9.79 8l-4.14 4.15a0.5 0.5 0 0 0 0.7 0.7l4.5 -4.5a0.5 0.5 0 0 0 0 -0.7l-4.5 -4.5a0.5 0.5 0 0 0 -0.7 0");
    /// <summary>circle_hint_20_regular, a square of 20.</summary>
    public static readonly Icon Hint = new(20, "M8.44 2.15a8 8 0 0 1 3.12 0a0.5 0.5 0 0 1 -0.2 0.98a7 7 0 0 0 -2.73 0a0.5 0.5 0 0 1 -0.2 -0.98m5.31 1.34a0.5 0.5 0 0 1 0.7 -0.14a8 8 0 0 1 2.2 2.2a0.5 0.5 0 1 1 -0.83 0.56a7 7 0 0 0 -1.93 -1.93a0.5 0.5 0 0 1 -0.14 -0.7m-7.5 0a0.5 0.5 0 0 1 -0.14 0.69A7 7 0 0 0 4.18 6.1a0.5 0.5 0 0 1 -0.83 -0.56a8 8 0 0 1 2.2 -2.2a0.5 0.5 0 0 1 0.7 0.14M2.74 8.05a0.5 0.5 0 0 1 0.4 0.58a7 7 0 0 0 0 2.74a0.5 0.5 0 0 1 -0.99 0.2a8 8 0 0 1 0 -3.13a0.5 0.5 0 0 1 0.59 -0.4m14.52 0a0.5 0.5 0 0 1 0.59 0.39a8 8 0 0 1 0 3.12a0.5 0.5 0 1 1 -0.98 -0.2a7 7 0 0 0 0 -2.73a0.5 0.5 0 0 1 0.39 -0.58m-13.78 5.7a0.5 0.5 0 0 1 0.7 0.14a7 7 0 0 0 1.93 1.93a0.5 0.5 0 0 1 -0.56 0.83a8 8 0 0 1 -2.2 -2.2a0.5 0.5 0 0 1 0.13 -0.7m13.03 0c0.23 0.16 0.3 0.47 0.14 0.7a8 8 0 0 1 -2.2 2.2a0.5 0.5 0 0 1 -0.56 -0.83a7 7 0 0 0 1.93 -1.93a0.5 0.5 0 0 1 0.7 -0.14m-8.46 3.51a0.5 0.5 0 0 1 0.58 -0.4c0.89 0.18 1.85 0.18 2.74 0a0.5 0.5 0 0 1 0.19 0.99a8 8 0 0 1 -3.12 0a0.5 0.5 0 0 1 -0.4 -0.59");
    /// <summary>dismiss_12_regular, a square of 12.</summary>
    public static readonly Icon Dismiss12 = new(12, "M2.09 2.22l0.06 -0.07a0.5 0.5 0 0 1 0.63 -0.06l0.07 0.06L6 5.29l3.15 -3.14a0.5 0.5 0 1 1 0.7 0.7L6.71 6l3.14 3.15c0.18 0.17 0.2 0.44 0.06 0.63l-0.06 0.07a0.5 0.5 0 0 1 -0.63 0.06l-0.07 -0.06L6 6.71L2.85 9.85a0.5 0.5 0 0 1 -0.7 -0.7L5.29 6L2.15 2.85a0.5 0.5 0 0 1 -0.06 -0.63l0.06 -0.07z");
    /// <summary>dismiss_16_regular, a square of 16.</summary>
    public static readonly Icon Dismiss16 = new(16, "M2.59 2.72l0.06 -0.07a0.5 0.5 0 0 1 0.63 -0.06l0.07 0.06L8 7.29l4.65 -4.64a0.5 0.5 0 0 1 0.7 0.7L8.71 8l4.64 4.65c0.18 0.17 0.2 0.44 0.06 0.63l-0.06 0.07a0.5 0.5 0 0 1 -0.63 0.06l-0.07 -0.06L8 8.71l-4.65 4.64a0.5 0.5 0 0 1 -0.7 -0.7L7.29 8L2.65 3.35a0.5 0.5 0 0 1 -0.06 -0.63l0.06 -0.07z");
    /// <summary>checkmark_circle_20_regular, a square of 20: the check of a task's result (picture 1 of the third set).</summary>
    public static readonly Icon CheckCircle20 = new(20, "M10 2a8 8 0 1 1 0 16a8 8 0 0 1 0 -16m0 1a7 7 0 1 0 0 14a7 7 0 0 0 0 -14m3.36 4.65c0.17 0.17 0.2 0.44 0.06 0.63l-0.06 0.07l-4 4a0.5 0.5 0 0 1 -0.64 0.07l-0.07 -0.06l-2 -2a0.5 0.5 0 0 1 0.63 -0.77l0.07 0.06L9 11.3l3.65 -3.65c0.2 -0.2 0.51 -0.2 0.7 0");
    /// <summary>document_text_20_regular, a square of 20: the checked outputs of a result (picture 1 of the third set).</summary>
    public static readonly Icon DocumentText = new(20, "M6.5 10a0.5 0.5 0 0 0 0 1h7a0.5 0.5 0 0 0 0 -1zM6.5 12a0.5 0.5 0 0 0 0 1h7a0.5 0.5 0 0 0 0 -1zM6.5 14a0.5 0.5 0 0 0 0 1h7a0.5 0.5 0 0 0 0 -1zM4 4c0 -1.1 0.9 -2 2 -2h4.59q0.62 0.01 1.06 0.44l3.91 3.91c0.28 0.28 0.44 0.67 0.44 1.06V16a2 2 0 0 1 -2 2H6a2 2 0 0 1 -2 -2zM6 3a1 1 0 0 0 -1 1v12a1 1 0 0 0 1 1h8a1 1 0 0 0 1 -1V8h-3.5A1.5 1.5 0 0 1 10 6.5V3zM11.5 7h3.3L11 3.2v3.3c0 0.28 0.22 0.5 0.5 0.5");
    /// <summary>document_20_regular, a square of 20.</summary>
    public static readonly Icon Document = new(20, "M6 2a2 2 0 0 0 -2 2v12c0 1.1 0.9 2 2 2h8a2 2 0 0 0 2 -2V7.41c0 -0.4 -0.16 -0.78 -0.44 -1.06l-3.91 -3.91A1.5 1.5 0 0 0 10.59 2zM5 4a1 1 0 0 1 1 -1h4v3.5c0 0.83 0.67 1.5 1.5 1.5H15v8a1 1 0 0 1 -1 1H6a1 1 0 0 1 -1 -1zM14.8 7h-3.3a0.5 0.5 0 0 1 -0.5 -0.5V3.2z");
    /// <summary>more_horizontal_16_regular, a square of 16.</summary>
    public static readonly Icon More = new(16, "M5 8a1 1 0 1 1 -2 0a1 1 0 0 1 2 0m4 0a1 1 0 1 1 -2 0a1 1 0 0 1 2 0m3 1a1 1 0 1 0 0 -2a1 1 0 0 0 0 2");
    /// <summary>pause_circle_20_regular, a square of 20.</summary>
    public static readonly Icon PauseCircle = new(20, "M10 2a8 8 0 1 1 0 16a8 8 0 0 1 0 -16m0 1a7 7 0 1 0 0 14a7 7 0 0 0 0 -14M8.5 6.5c0.28 0 0.5 0.22 0.5 0.5v6a0.5 0.5 0 0 1 -1 0V7c0 -0.28 0.22 -0.5 0.5 -0.5m3 0c0.28 0 0.5 0.22 0.5 0.5v6a0.5 0.5 0 0 1 -1 0V7c0 -0.28 0.22 -0.5 0.5 -0.5");
    /// <summary>play_20_regular, a square of 20.</summary>
    public static readonly Icon Play = new(20, "M17.22 8.69a1.5 1.5 0 0 1 0 2.62l-10 5.5A1.5 1.5 0 0 1 5 15.5v-11A1.5 1.5 0 0 1 7.22 3.2zM16.74 10.44a0.5 0.5 0 0 0 0 -0.88l-10 -5.5A0.5 0.5 0 0 0 6 4.5v11c0 0.38 0.4 0.62 0.74 0.44z");
    /// <summary>search_20_regular, a square of 20.</summary>
    public static readonly Icon Search = new(20, "M13.73 14.44a6.5 6.5 0 1 1 0.7 -0.7l3.42 3.4a0.5 0.5 0 0 1 -0.63 0.77l-0.07 -0.06zM13.02 13.73A5.5 5.5 0 0 0 15 9.5a5.5 5.5 0 1 0 -1.98 4.23");
    /// <summary>warning_20_filled, a square of 20.</summary>
    public static readonly Icon Warning = new(20, "M7.37 3.56a3 3 0 0 1 5.26 0l5.5 10A3 3 0 0 1 15.5 18h-11a3 3 0 0 1 -2.63 -4.44zM10 12.75a0.75 0.75 0 1 0 0 1.5a0.75 0.75 0 0 0 0 -1.5m0 -6.25a0.5 0.5 0 0 0 -0.5 0.5v4a0.5 0.5 0 0 0 1 0V7a0.5 0.5 0 0 0 -0.5 -0.5");
    /// <summary>arrow_up_16_filled, a square of 16.</summary>
    public static readonly Icon ArrowUp = new(16, "M8 14a0.75 0.75 0 0 1 -0.75 -0.75V4.46L4.31 7.75a0.75 0.75 0 0 1 -1.12 -1L7.44 2a0.75 0.75 0 0 1 1.12 0l4.25 4.75a0.75 0.75 0 1 1 -1.12 1L8.75 4.46v8.79c0 0.41 -0.34 0.75 -0.75 0.75");

    /// <summary>A run of a task's steps (RuntimeActivity's StepsRow, list.bullet.indent): Fluent's text_bullet_list_ltr_20_regular.</summary>
    public static readonly Icon Steps = new(20, "M3 5.5a1 1 0 1 0 0 -2a1 1 0 0 0 0 2m3 -1c0 -0.28 0.22 -0.5 0.5 -0.5h11a0.5 0.5 0 0 1 0 1h-11a0.5 0.5 0 0 1 -0.5 -0.5m0 5c0 -0.28 0.22 -0.5 0.5 -0.5h11a0.5 0.5 0 0 1 0 1h-11a0.5 0.5 0 0 1 -0.5 -0.5m0.5 4.5a0.5 0.5 0 0 0 0 1h11a0.5 0.5 0 0 0 0 -1zM4 14.5a1 1 0 1 1 -2 0a1 1 0 0 1 2 0m-1 -4a1 1 0 1 0 0 -2a1 1 0 0 0 0 2");

    /// <summary>A permission of a task (hand.raised): Fluent's hand_left_20_regular.</summary>
    public static readonly Icon Hand = new(20, "M16 12.02q0 1.6 -0.6 3.08l-0.6 1.42a2.6 2.6 0 0 1 -1.17 1.29q-0.4 0.21 -0.86 0.21h-2.55c-0.77 0 -1.49 -0.41 -1.87 -1.08c-0.5 -0.87 -1.02 -1.7 -1.72 -2.43l-1.32 -1.39c-0.44 -0.46 -0.97 -0.84 -1.49 -1.23l-0.59 -0.45a0.6 0.6 0 0 1 -0.23 -0.47c0 -0.75 0.54 -1.57 1.22 -1.79A3.3 3.3 0 0 1 7 9.47V4.5a1.5 1.5 0 0 1 2.05 -1.4a1.5 1.5 0 0 1 2.9 0A1.5 1.5 0 0 1 14 4.5v0.09A1.5 1.5 0 0 1 16 6zM12 4.5v4a0.5 0.5 0 0 1 -1 0v-5a0.5 0.5 0 0 0 -1 0v5a0.5 0.5 0 0 1 -1 0v-4a0.5 0.5 0 0 0 -1 0v6a0.5 0.5 0 0 1 -0.85 0.37h-0.01q-0.31 -0.35 -0.72 -0.58c-0.7 -0.35 -2.22 -0.57 -2.4 0.5l0.53 0.4c0.52 0.4 1.04 0.78 1.48 1.24l1.33 1.38c0.75 0.79 1.31 1.7 1.85 2.63c0.21 0.36 0.6 0.58 1.01 0.58h2.55q0.2 0 0.4 -0.1q0.49 -0.26 0.71 -0.78l0.59 -1.42q0.53 -1.3 0.53 -2.7V6a0.5 0.5 0 0 0 -1 0v3.5a0.5 0.5 0 0 1 -1 0v-5a0.5 0.5 0 0 0 -1 0");

    /// <summary>A step that fetched a page (globe): Fluent's globe_20_regular.</summary>
    public static readonly Icon Globe = new(20, "M10 18a8 8 0 1 0 0 -16a8 8 0 0 0 0 16m0 -15c0.66 0 1.4 0.59 2.02 1.9q0.33 0.71 0.56 1.6H7.42q0.23 -0.89 0.56 -1.6C8.59 3.6 9.34 3 10 3M7.07 4.49q-0.4 0.9 -0.68 2.01H3.94A7 7 0 0 1 7.7 3.38q-0.36 0.5 -0.64 1.1M6.2 7.5a16 16 0 0 0 0 5H3.46a7 7 0 0 1 0 -5zM6.4 13.5q0.26 1.12 0.68 2.01q0.28 0.61 0.64 1.1a7 7 0 0 1 -3.77 -3.11zM7.43 13.5h5.16a9 9 0 0 1 -0.56 1.6C11.41 16.4 10.66 17 10 17s-1.4 -0.59 -2.02 -1.9q-0.33 -0.71 -0.56 -1.6m5.37 -1H7.21a15 15 0 0 1 0 -5h5.58a15 15 0 0 1 0 5m0.82 1h2.45a7 7 0 0 1 -3.77 3.12q0.36 -0.5 0.64 -1.1q0.4 -0.9 0.68 -2.02m2.93 -1h-2.73a16 16 0 0 0 0 -5h2.73a7 7 0 0 1 0 5m-4.25 -9.12a7 7 0 0 1 3.77 3.12h-2.45a11 11 0 0 0 -0.68 -2.01q-0.28 -0.61 -0.64 -1.1");

    /// <summary>A step that ran a command (terminal): Fluent's window_console_20_regular.</summary>
    public static readonly Icon Console = new(20, "M5.65 9.15c0.2 -0.2 0.5 -0.2 0.7 0l2 2a0.5 0.5 0 0 1 0 0.7l-2 2a0.5 0.5 0 0 1 -0.7 -0.7l1.64 -1.65l-1.64 -1.65a0.5 0.5 0 0 1 0 -0.7M14.5 13h-5a0.5 0.5 0 0 0 0 1h5a0.5 0.5 0 0 0 0 -1M3 5.5A2.5 2.5 0 0 1 5.5 3h9A2.5 2.5 0 0 1 17 5.5v9a2.5 2.5 0 0 1 -2.5 2.5h-9A2.5 2.5 0 0 1 3 14.5zM16 6v-0.5c0 -0.83 -0.68 -1.5 -1.5 -1.5h-9C4.67 4 4 4.67 4 5.5V6zM4 7v7.5c0 0.83 0.67 1.5 1.5 1.5h9c0.82 0 1.5 -0.67 1.5 -1.5V7z");

    /// <summary>A step that changed a file (pencil): Fluent's edit_20_regular.</summary>
    public static readonly Icon Edit = new(20, "M17.18 2.93a2.97 2.97 0 0 0 -4.26 -0.06l-9.37 9.38q-0.5 0.5 -0.66 1.2l-0.88 3.94a0.5 0.5 0 0 0 0.6 0.6l3.93 -0.87c0.46 -0.1 0.9 -0.34 1.23 -0.68l9.36 -9.36a2.97 2.97 0 0 0 0.05 -4.15m-3.55 0.65a1.97 1.97 0 1 1 2.8 2.8l-0.68 0.66l-2.8 -2.79zM12.25 4.96l2.8 2.8l-7.99 7.97q-0.31 0.31 -0.74 0.41l-3.16 0.7l0.7 -3.18q0.1 -0.41 0.4 -0.7z");

    /// <summary>A picture among a result's checked outputs (photo): Fluent's image_20_regular.</summary>
    public static readonly Icon Image = new(20, "M14 7.5a1.5 1.5 0 1 1 -3 0a1.5 1.5 0 0 1 3 0m-1 0a0.5 0.5 0 1 0 -1 0a0.5 0.5 0 0 0 1 0M3 6a3 3 0 0 1 3 -3h8a3 3 0 0 1 3 3v8a3 3 0 0 1 -3 3H6a3 3 0 0 1 -3 -3zM6 4a2 2 0 0 0 -2 2v8q0 0.56 0.28 1.02l4.67 -4.59a1.5 1.5 0 0 1 2.1 0l4.67 4.59Q16 14.56 16 14V6a2 2 0 0 0 -2 -2zM6 16h8a2 2 0 0 0 1.01 -0.27l-4.66 -4.58a0.5 0.5 0 0 0 -0.7 0l-4.66 4.58A2 2 0 0 0 6 16");

    /// <summary>A verified download (checkmark.shield): Fluent's shield_checkmark_20_regular.</summary>
    public static readonly Icon ShieldCheck = new(20, "M9.72 2.08a0.5 0.5 0 0 1 0.56 0q2.9 1.94 6.3 2.43A0.5 0.5 0 0 1 17 5v4.6q-0.48 -0.25 -1 -0.4V5.44a16 16 0 0 1 -5.6 -2.08L10 3.1l-0.4 0.25A16 16 0 0 1 4 5.43V9.5c0 3.24 1.8 5.64 5.48 7.25q0.3 0.65 0.74 1.2l-0.04 0.02a0.5 0.5 0 0 1 -0.36 0C5.31 16.23 3 13.39 3 9.5V5a0.5 0.5 0 0 1 0.43 -0.5a15 15 0 0 0 6.3 -2.42M19 14.5a4.5 4.5 0 1 1 -9 0a4.5 4.5 0 0 1 9 0m-2.15 -1.85a0.5 0.5 0 0 0 -0.7 0l-2.65 2.64l-0.65 -0.64a0.5 0.5 0 0 0 -0.7 0.7l1 1c0.2 0.2 0.5 0.2 0.7 0l3 -3a0.5 0.5 0 0 0 0 -0.7");

    /// <summary>The agent's thinking, a step of its run (the Mac's sparkle): Fluent's sparkle_20_regular.</summary>
    public static readonly Icon Sparkle = new(20, "M7.4 12.8a1.04 1.04 0 0 0 1.59 -0.51l0.45 -1.37a2.3 2.3 0 0 1 1.47 -1.48l1.4 -0.45A1.04 1.04 0 0 0 12.25 7l-1.37 -0.45A2.3 2.3 0 0 1 9.4 5.08L8.95 3.7a1 1 0 0 0 -0.82 -0.68a1.04 1.04 0 0 0 -1.15 0.7l-0.46 1.4a2.3 2.3 0 0 1 -1.44 1.45L3.7 7a1.04 1.04 0 0 0 0.02 1.97l1.37 0.45a2.3 2.3 0 0 1 1.48 1.48l0.46 1.4q0.1 0.3 0.38 0.5m0.08 -7.4l0.53 -1.38l0.44 1.37a3.3 3.3 0 0 0 2.12 2.12l1.4 0.53l-1.38 0.45a3.3 3.3 0 0 0 -2.11 2.11l-0.53 1.38l-0.45 -1.38a3.3 3.3 0 0 0 -2.1 -2.12L4 7.96L5.4 7.5a3.4 3.4 0 0 0 2.08 -2.12m6.06 11.45a0.8 0.8 0 0 0 1.22 -0.4l0.25 -0.76a1.1 1.1 0 0 1 0.68 -0.68l0.77 -0.25a0.8 0.8 0 0 0 -0.02 -1.52l-0.77 -0.25a1.1 1.1 0 0 1 -0.68 -0.68l-0.25 -0.77a0.8 0.8 0 0 0 -1.52 0.01l-0.24 0.76a1.1 1.1 0 0 1 -0.67 0.68l-0.77 0.25a0.8 0.8 0 0 0 0 1.52l0.77 0.25a1.1 1.1 0 0 1 0.68 0.68l0.25 0.77q0.09 0.25 0.3 0.4m-0.92 -2.8l-0.18 -0.05l0.19 -0.06a2.1 2.1 0 0 0 1.3 -1.32l0.06 -0.18l0.05 0.18a2 2 0 0 0 1.32 1.32l0.2 0.06l-0.18 0.06a2 2 0 0 0 -1.32 1.32l-0.06 0.18l-0.06 -0.18a2 2 0 0 0 -1.32 -1.32");

    /// <summary>A child agent's call (the Mac's person.crop.square): Fluent's person_square_20_regular.</summary>
    public static readonly Icon Child = new(20, "M10 5a2 2 0 1 0 0 4a2 2 0 0 0 0 -4m2.5 5h-5c-0.83 0 -1.5 0.67 -1.5 1.5c0 1.12 0.46 2.01 1.21 2.61c0.74 0.6 1.74 0.89 2.79 0.89s2.05 -0.29 2.79 -0.89S14 12.61 14 11.5c0 -0.83 -0.67 -1.5 -1.5 -1.5M6 3a3 3 0 0 0 -3 3v8a3 3 0 0 0 3 3h8a3 3 0 0 0 3 -3V6a3 3 0 0 0 -3 -3zM4 6c0 -1.1 0.9 -2 2 -2h8a2 2 0 0 1 2 2v8a2 2 0 0 1 -2 2H6a2 2 0 0 1 -2 -2z");

    /// <summary>A step of a plan to come (the Mac's circle): Fluent's circle_20_regular.</summary>
    public static readonly Icon Circle = new(20, "M10 3a7 7 0 1 0 0 14a7 7 0 0 0 0 -14m-8 7a8 8 0 1 1 16 0a8 8 0 0 1 -16 0");

    /// <summary>An error of a task's record (the Mac's exclamationmark.circle): Fluent's error_circle_20_regular.</summary>
    public static readonly Icon ErrorCircle = new(20, "M10 2a8 8 0 1 1 0 16a8 8 0 0 1 0 -16m0 1a7 7 0 1 0 0 14a7 7 0 0 0 0 -14m0 9.5a0.75 0.75 0 1 1 0 1.5a0.75 0.75 0 0 1 0 -1.5M10 6a0.5 0.5 0 0 1 0.5 0.41V11a0.5 0.5 0 0 1 -1 0.09V6.5c0 -0.28 0.22 -0.5 0.5 -0.5");

    /// <summary>Open agent thread, and a child agent in the panel (the Mac's arrow.up.right): Fluent's arrow_up_right_16_regular.</summary>
    public static readonly Icon OpenThread = new(16, "M7.5 3a0.5 0.5 0 0 1 0 -1h6c0.28 0 0.5 0.22 0.5 0.5v6a0.5 0.5 0 0 1 -1 0V3.7L2.85 13.86a0.5 0.5 0 0 1 -0.7 -0.7L12.29 3z");

    /// <summary>Earlier activity (the Mac's arrow.up): Fluent's arrow_up_16_regular.</summary>
    public static readonly Icon Earlier = new(16, "M7.5 13.5a0.5 0.5 0 0 0 1 0V3.8l3.63 4.03a0.5 0.5 0 0 0 0.74 -0.66l-4.5 -5a0.5 0.5 0 0 0 -0.74 0l-4.5 5a0.5 0.5 0 0 0 0.74 0.66L7.5 3.8z");

    /// <summary>Latest over a task's thread (the Mac's arrow.down): Fluent's arrow_down_16_regular.</summary>
    public static readonly Icon ArrowDown = new(16, "M8.5 2.5a0.5 0.5 0 1 0 -1 0v9.7L3.87 8.17a0.5 0.5 0 1 0 -0.74 0.66l4.5 5a0.5 0.5 0 0 0 0.74 0l4.5 -5a0.5 0.5 0 0 0 -0.74 -0.66L8.5 12.2z");

    /// <summary>copy_16_regular, a square of 16: the copy icon of a code block on a request (the Mac's CodeBlock).</summary>
    public static readonly Icon Copy16 = new(16, "M5 6H4a1 1 0 0 0 -1 1v5a1 1 0 0 0 1 1h4a1 1 0 0 0 1 -1h1a2 2 0 0 1 -2 2H4a2 2 0 0 1 -2 -2V7c0 -1.1 0.9 -2 2 -2h1zM12 2a2 2 0 0 1 2 2v5a2 2 0 0 1 -2 2H8a2 2 0 0 1 -2 -2V4c0 -1.1 0.9 -2 2 -2zM8 3a1 1 0 0 0 -1 1v5a1 1 0 0 0 1 1h4a1 1 0 0 0 1 -1V4a1 1 0 0 0 -1 -1z");
    /// <summary>Back out of a child agent's thread (the Mac's arrow.left): Fluent's arrow_left_20_regular.</summary>
    public static readonly Icon BackArrow = new(20, "M9.16 16.87a0.5 0.5 0 1 0 0.67 -0.74L3.67 10.5H17.5a0.5 0.5 0 0 0 0 -1H3.67l6.16 -5.63a0.5 0.5 0 0 0 -0.67 -0.74L2.24 9.44a0.75 0.75 0 0 0 0 1.11z");

    /// <summary>An icon at <paramref name="size"/> pixels (16 for a 20-square icon, 12 for a chevron) in a brush.</summary>
    public static FrameworkElement Of(Icon icon, Brush brush, double size = 16)
    {
        var path = new Path
        {
            // The nonzero fill of SVG ("F1"): XAML's default even-odd fill cuts holes in these icons.
            Data = (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), "F1 " + icon.Data),
            Fill = brush,
            Width = icon.Side,
            Height = icon.Side,
        };
        return new Viewbox
        {
            Width = size,
            Height = size,
            IsHitTestVisible = false,
            Child = new Canvas { Width = icon.Side, Height = icon.Side, Children = { path } },
        };
    }

    /// <summary>An icon in the text colour.</summary>
    public static FrameworkElement Of(Icon icon, double size = 16) =>
        Of(icon, (Brush)Application.Current.Resources["TextBrush"], size);
}
