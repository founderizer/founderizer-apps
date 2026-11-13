// Reading of slice 1.0 (app/windows/vm/README.md): start time and memory at rest.
//
// It starts a program several times and, for each run, measures from just
// before the start:
//   - when the program's first top-level window is visible;
//   - when that window is no longer cloaked by the compositor (painted);
//   - when the program is first idle for input (WaitForInputIdle);
// and then, after a pause, the program's working set and private bytes.
// It closes the program after each run. It must run in the signed-in user's
// desktop session (vm.sh desktop), not in an SSH session:
//
//   dotnet run start-time.cs -- <program.exe> <runs> [seconds at rest]
//
// The first run after a fresh start of Windows is the cold start.

// Native AOT needs Microsoft's C++ linker, which the build VM does not have (README.md, "Limits").
#:property PublishAot=false
// The Windows target framework, so that its Windows-only calls raise no warning (app/windows/Directory.Build.props
// makes every warning an error).
#:property TargetFramework=net10.0-windows
// No package, so no lock file beside this program (the shared settings ask for one).
#:property RestorePackagesWithLockFile=false

using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

if (args.Length < 2)
{
    Console.Error.WriteLine("usage: start-time <program.exe> <runs> [seconds at rest]");
    return 2;
}
string program = Path.GetFullPath(args[0]);
int runs = int.Parse(args[1]);
int rest = args.Length > 2 ? int.Parse(args[2]) : 10;
Native.timeBeginPeriod(1);
Console.WriteLine($"program: {program}");
Console.WriteLine($"os: {RuntimeInformation.OSDescription}, {Environment.ProcessorCount} processors, uptime {TimeSpan.FromMilliseconds(Environment.TickCount64):hh\\:mm\\:ss}");

for (int run = 1; run <= runs; run++)
{
    var clock = Stopwatch.StartNew();
    using var process = Process.Start(new ProcessStartInfo(program)
    {
        UseShellExecute = false,
        WorkingDirectory = Path.GetDirectoryName(program)!,
    })!;
    double visible = -1, painted = -1;
    while (clock.Elapsed < TimeSpan.FromSeconds(60) && !process.HasExited)
    {
        IntPtr window = Native.FirstVisibleWindow(process.Id);
        if (window != IntPtr.Zero)
        {
            if (visible < 0) visible = clock.Elapsed.TotalMilliseconds;
            if (!Native.Cloaked(window))
            {
                painted = clock.Elapsed.TotalMilliseconds;
                break;
            }
        }
        Thread.Sleep(1);
    }
    double idle = -1;
    try
    {
        if (process.WaitForInputIdle(30000)) idle = clock.Elapsed.TotalMilliseconds;
    }
    catch (InvalidOperationException)
    {
    }
    Thread.Sleep(TimeSpan.FromSeconds(rest));
    process.Refresh();
    double workingSet = process.WorkingSet64 / 1048576.0;
    double privateBytes = process.PrivateMemorySize64 / 1048576.0;
    Console.WriteLine($"run {run}: window visible {visible:F0} ms, painted {painted:F0} ms, input idle {idle:F0} ms; " +
                      $"after {rest} s at rest: working set {workingSet:F1} MB, private bytes {privateBytes:F1} MB");
    process.CloseMainWindow();
    if (!process.WaitForExit(5000)) process.Kill();
    Thread.Sleep(2000);
}
return 0;

static class Native
{
    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint milliseconds);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out int processId);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
    delegate bool EnumProc(IntPtr window, IntPtr state);

    public static IntPtr FirstVisibleWindow(int processId)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out int owner);
            // A top-level window with no owner window (GW_OWNER is 4).
            if (owner == processId && IsWindowVisible(window) && GetWindow(window, 4) == IntPtr.Zero)
            {
                found = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Cloaked(IntPtr window)
    {
        // DWMWA_CLOAKED is 14.
        return DwmGetWindowAttribute(window, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0;
    }
}
