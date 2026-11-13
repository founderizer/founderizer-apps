// The library's own search for a hub on this PC's private network (app/windows/vm/README.md, "The owner's private
// network"): it reads `tailscale status --json` and runs Tailnet.FindAsync with HubClient.AnswersHealthAsync, as the
// window's store does when it has no hub (OwnerStore.FindHubAsync). It prints this PC's name on the network, how many
// other devices it sees, and the address of the first device that answers GET /health on the hub's port, or that none
// answers. Copy it to C:\fz\src\windows\vm\tailnet\ in the VM, beside the copied Founderizer.Core, and run it there:
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
Console.WriteLine($"this PC on the network: {Tailnet.OwnName(status) ?? "(no name: is it signed in?)"}");
Console.WriteLine($"other devices: {devices.Count}, of them online: {devices.Count(d => d.Online)}");
using var client = new HubClient();
var clock = Stopwatch.StartNew();
var hub = await Tailnet.FindAsync(status, (address, cancel) => client.AnswersHealthAsync(address, cancel));
Console.WriteLine(hub is null
    ? $"no device answers GET /health on port {Tailnet.HubPort} (after {clock.ElapsedMilliseconds} ms)"
    : $"the hub: {hub} answers GET /health ({clock.ElapsedMilliseconds} ms)");
return hub is null ? 1 : 0;
