// The library's own search for a hub on this PC's private network (app/windows/vm/README.md, "The owner's private
// network"): it reads `tailscale status --json` and runs Tailnet.FindAsync with HubClient.AnswersHealthAsync, as the
// window's store does when it has no hub (OwnerStore.FindHubAsync). It prints how many other devices this PC sees, each
// device that it asks by its number only (whether it answered GET /health on the hub's port, and in how many ms), and
// which number answered first, or that none answered. It prints no name and no address of the owner's network, so its
// lines can go into a report as they are. Copy it to C:\fz\src\windows\vm\tailnet\ in the VM, beside the copied
// Founderizer.Core, and run it there:
//
//   dotnet run find-hub.cs

// Native AOT needs Microsoft's C++ linker, which the build VM does not have (README.md, "Limits").
#:property PublishAot=false
// The library only, and no package of its own.
#:property TargetFramework=net10.0
#:property RestorePackagesWithLockFile=false
#:project ../../Founderizer.Core/Founderizer.Core.csproj

using System;
using System.Diagnostics;
using System.Linq;
using Founderizer.Core;

var start = new ProcessStartInfo(@"C:\Program Files\Tailscale\tailscale.exe", "status --json")
{
    RedirectStandardOutput = true,
    UseShellExecute = false,
};
using var tailscale = Process.Start(start) ?? throw new InvalidOperationException("Tailscale does not start");
string status = await tailscale.StandardOutput.ReadToEndAsync();
await tailscale.WaitForExitAsync();

var devices = Tailnet.Devices(status);
Console.WriteLine($"this PC is on the network: {Tailnet.OwnName(status) is not null}");
Console.WriteLine($"other devices: {devices.Count}, of them online: {devices.Count(d => d.Online)}");
using var client = new HubClient();
var numbers = new System.Collections.Concurrent.ConcurrentDictionary<string, int>();
var clock = Stopwatch.StartNew();
var hub = await Tailnet.FindAsync(status, async (address, cancel) =>
{
    var number = numbers.GetOrAdd(address.Host, _ => numbers.Count + 1);
    var asked = Stopwatch.StartNew();
    try
    {
        var answered = await client.AnswersHealthAsync(address, cancel);
        Console.WriteLine($"device {number}: {(answered ? "answers" : "does not answer")} GET /health ({asked.ElapsedMilliseconds} ms)");
        return answered;
    }
    catch (Exception e)
    {
        // The refusal's words, with no address in them: the device's own host and any IP address go.
        var words = System.Text.RegularExpressions.Regex.Replace(e.Message.Replace(address.Host, "the device"),
                                                                 @"\[?[0-9a-fA-F:.]*[0-9][.:][0-9a-fA-F:.]+\]?(:\d+)?", "the device");
        Console.WriteLine($"device {number}: {(cancel.IsCancellationRequested ? "not waited for, the hub answered first" : e.GetType().Name + ": " + words)} ({asked.ElapsedMilliseconds} ms)");
        throw;
    }
});
Console.WriteLine(hub is null
    ? $"no device answers GET /health on port {Tailnet.HubPort} (after {clock.ElapsedMilliseconds} ms, {numbers.Count} asked)"
    : $"the hub's machine is device {numbers[hub.Host]} of {numbers.Count} asked: found in {clock.ElapsedMilliseconds} ms");
return hub is null ? 1 : 0;
