# The window watcher of proof A (watch.sh starts it): in the signed-in user's desktop session, it writes one line for each
# top-level window that becomes visible, with its class and its program, until the stop file exists. Proof A fails when a
# console shows ("no console showed", windows-app-plan-v2.md, section 11).
#
#   powershell -File watch.ps1 -Log C:\fz\proof-a\windows.log -Stop C:\fz\proof-a\watch.stop
#
# Two ways, so that a window that shows for a moment is not missed: Windows' own events of a window that shows
# (SetWinEventHook, EVENT_OBJECT_SHOW, out of context), and a sweep of all top-level windows every 100 ms. The lines are
# tab-separated: the time (UTC), what (at-start, new, stopped), the window's handle, its class, the process id, the
# program's path, the first 60 letters of its title, its place and size, and "console" or "-". A window whose class or
# program can no longer be read is "unknown": the summary counts it as a fault, not as a pass. A title is a window's own
# words (no field's contents); nothing that the owner types is in this log.
param([Parameter(Mandatory = $true)][string]$Log, [Parameter(Mandatory = $true)][string]$Stop)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class FzWatch {
    private delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    private delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; public uint priv; }
    [DllImport("user32.dll")] private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int size);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr data);
    [DllImport("user32.dll")] private static extern bool PeekMessage(out MSG msg, IntPtr hwnd, uint min, uint max, uint remove);
    [DllImport("user32.dll")] private static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] private static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")] private static extern uint MsgWaitForMultipleObjects(uint count, IntPtr[] handles, bool all, uint ms, uint mask);
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
    [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder text, ref int size);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    private const uint ShowEvent = 0x8002, OutOfContext = 0x0000, SkipOwnProcess = 0x0002, Root = 2, QueryLimited = 0x1000;
    private static readonly string[] ConsoleClasses = { "ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS", "PseudoConsoleWindow" };
    private static readonly string[] ConsolePrograms = { "conhost.exe", "openconsole.exe", "windowsterminal.exe", "cmd.exe", "powershell.exe", "pwsh.exe" };
    private static readonly HashSet<IntPtr> visible = new HashSet<IntPtr>();
    private static WinEventProc keep;
    private static StreamWriter log;
    public static int News, Consoles, Unknown;

    public static void Run(string logPath, string stopPath) {
        SetProcessDPIAware();
        log = new StreamWriter(logPath, true, new UTF8Encoding(false));
        log.AutoFlush = true;
        foreach (var hwnd in TopLevel()) if (IsWindowVisible(hwnd)) { visible.Add(hwnd); Write("at-start", hwnd); }
        keep = OnEvent;
        IntPtr hook = SetWinEventHook(ShowEvent, ShowEvent, IntPtr.Zero, keep, 0, 0, OutOfContext | SkipOwnProcess);
        Line(string.Format("watching\thook {0}\t{1} windows at the start", hook == IntPtr.Zero ? "none" : "on", visible.Count));
        try {
            while (!File.Exists(stopPath)) {
                MSG msg;
                while (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
                Sweep();
                MsgWaitForMultipleObjects(0, null, false, 100, 0x04FF);
            }
        } finally {
            if (hook != IntPtr.Zero) UnhookWinEvent(hook);
            Line(string.Format("stopped\tnew {0}\tconsoles {1}\tunknown {2}", News, Consoles, Unknown));
            log.Dispose();
        }
    }

    private static void OnEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
        if (idObject != 0 || idChild != 0 || hwnd == IntPtr.Zero) return;
        if (GetAncestor(hwnd, Root) != hwnd) return;
        if (!visible.Contains(hwnd)) { visible.Add(hwnd); Write("new", hwnd); }
    }

    private static void Sweep() {
        var now = new HashSet<IntPtr>();
        foreach (var hwnd in TopLevel()) if (IsWindowVisible(hwnd)) now.Add(hwnd);
        foreach (var hwnd in now) if (!visible.Contains(hwnd)) Write("new", hwnd);
        visible.Clear();
        foreach (var hwnd in now) visible.Add(hwnd);
    }

    private static List<IntPtr> TopLevel() {
        var all = new List<IntPtr>();
        EnumWindows((h, d) => { all.Add(h); return true; }, IntPtr.Zero);
        return all;
    }

    private static void Write(string what, IntPtr hwnd) {
        var cls = new StringBuilder(256);
        string kind = GetClassName(hwnd, cls, cls.Capacity) > 0 ? cls.ToString() : "";
        var title = new StringBuilder(256);
        GetWindowText(hwnd, title, title.Capacity);
        string words = title.ToString().Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
        if (words.Length > 60) words = words.Substring(0, 60);
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        string program = "";
        IntPtr process = OpenProcess(QueryLimited, false, pid);
        if (process != IntPtr.Zero) {
            var path = new StringBuilder(1024);
            int size = path.Capacity;
            if (QueryFullProcessImageName(process, 0, path, ref size)) program = path.ToString();
            CloseHandle(process);
        }
        RECT r;
        string place = GetWindowRect(hwnd, out r) ? string.Format("{0}x{1}@{2},{3}", r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top) : "-";
        string name = Path.GetFileName(program).ToLowerInvariant();
        bool console = Array.IndexOf(ConsoleClasses, kind) >= 0 || Array.IndexOf(ConsolePrograms, name) >= 0;
        bool unknown = kind.Length == 0 || program.Length == 0;
        if (what == "new") { News++; if (console) Consoles++; else if (unknown) Unknown++; }
        Line(string.Join("\t", new[] { what, "0x" + hwnd.ToInt64().ToString("x"), kind.Length > 0 ? kind : "(unknown)", pid.ToString(),
            program.Length > 0 ? program : "(unknown)", words, place, console ? "console" : (unknown ? "unknown" : "-") }));
    }

    private static void Line(string text) {
        log.WriteLine(DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + "\t" + text);
    }
}
'@
[FzWatch]::Run($Log, $Stop)
