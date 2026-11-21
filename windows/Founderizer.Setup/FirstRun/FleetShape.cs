using System;
using System.Collections.Generic;
using System.Linq;
using Founderizer.Owner.Reads;
using Founderizer.Setup.Agents;
using Founderizer.Setup.Install;

// The fleet that the first run proposes, before any of it exists (the Mac's FleetCore/FleetShape.swift): the manager's
// name, the servers that the team runs on, the steps on Back's line, and what the first run gives the manager's setup.
// The owner approved the pages on 14 November 2026 ("Yes, as shown"). The words are the Mac's, with "PC" for "Mac".

namespace Founderizer.Setup.Install
{
    public static partial class ManagerName
    {
        /// <summary>The name as each page shows it: the typed words, with no space around them.</summary>
        public static string Shown(string typed) => typed.Trim();
    }
}

namespace Founderizer.Setup.FirstRun
{
    /// <summary>The owner's answer to "Is this fleet for personal use or for a business?".</summary>
    public enum FleetUse { Personal, Business }

    /// <summary>**The steps of the slider of "Your fleet's servers"** in words, from the lower cost to the more secure.</summary>
    public static class ServersSteps
    {
        public static readonly IReadOnlyList<ServersStep> All = [ServersStep.One, ServersStep.Two, ServersStep.Each];

        /// <summary>The step that the page opens on: the middle one for personal use, the last one for a business.</summary>
        public static ServersStep Opens(FleetUse use) => use == FleetUse.Personal ? ServersStep.Two : ServersStep.Each;

        /// <summary>The step's name as the hub and this PC's settings keep it ("one", "two", "each").</summary>
        public static string Raw(this ServersStep step) => step switch
        {
            ServersStep.One => "one",
            ServersStep.Two => "two",
            _ => "each",
        };

        public static ServersStep? FromRaw(string? raw) => raw switch
        {
            "one" => ServersStep.One,
            "two" => ServersStep.Two,
            "each" => ServersStep.Each,
            _ => null,
        };

        /// <summary>The first sentence of the step: what runs where.</summary>
        public static string Fact(this ServersStep step) => step switch
        {
            ServersStep.One => "Everything runs on one server.",
            ServersStep.Two => "The hub and its keys have a server of their own.",
            _ => "The hub and each agent have a server of their own.",
        };

        /// <summary>The second sentence of the step: what an agent that breaks out of its account reaches.</summary>
        public static string Risk(this ServersStep step) => step switch
        {
            ServersStep.One => "An agent that breaks out of its account can reach every key of your fleet.",
            ServersStep.Two => "An agent that breaks out of its account can reach the other agents, but not those keys.",
            _ => "An agent that breaks out of its account finds nothing else there.",
        };

        public static string Means(this ServersStep step) => step.Fact() + " " + step.Risk();

        /// <summary>**What the first run's one press makes**: the hub's server, and with 2 servers or 1 per agent the
        /// manager's own server too. On 1 server the manager runs on the hub's server.</summary>
        public static bool ManagersOwnServer(this ServersStep step) => step != ServersStep.One;

        /// <summary>That press, in the picture's words.</summary>
        public static string FirstPress(this ServersStep step) => step.ManagersOwnServer() ? "Make 2 servers" : "Make the server";
    }

    /// <summary>**The page "Your fleet's servers" before a team exists** (the Mac's ServersSketch): the hub and the
    /// manager, and two agents to come, so that the three steps differ in the drawing.</summary>
    public static class ServersSketch
    {
        public enum Part { Hub, Manager, Next }

        /// <summary>How many agents to come the drawing shows.</summary>
        public const int Next = 2;

        /// <summary>The servers of a step, the hub's first, each with what runs on it.</summary>
        public static IReadOnlyList<IReadOnlyList<Part>> Servers(ServersStep step)
        {
            var agents = Enumerable.Repeat(Part.Next, Next).ToList();
            return step switch
            {
                ServersStep.One => [[Part.Hub, Part.Manager, .. agents]],
                ServersStep.Two => [[Part.Hub], [Part.Manager, .. agents]],
                _ => [[Part.Hub], [Part.Manager], .. agents.Select(a => (IReadOnlyList<Part>)[a])],
            };
        }

        /// <summary>The words under a step of the slider.</summary>
        public static string Words(ServersStep step) => step switch
        {
            ServersStep.One => new FleetCount(1, 0).ServerWords,
            ServersStep.Two => new FleetCount(2, 0).ServerWords,
            _ => "1 per agent",
        };
    }

    /// <summary>How many machines a step needs: the words under the slider's steps and in the card's foot.</summary>
    public sealed record FleetCount(int Servers, int Macs)
    {
        public string ServerWords => Servers == 1 ? "1 server" : $"{Servers} servers";

        public string Words => Macs switch
        {
            0 => ServerWords,
            1 => $"{ServerWords} and 1 Mac",
            _ => $"{ServerWords} and {Macs} Macs",
        };
    }

    /// <summary>**The steps of the first run** on Back's line of each of its pages after the welcome page (the Mac's
    /// FirstRunSteps): the manager's name, its AI provider, the fleet's servers, this PC on the private network, the VPS
    /// of the fleet's server, and the build.</summary>
    public enum FirstRunStep { Manager, AiProvider, Servers, Network, Vps, Build }

    public static class FirstRunSteps
    {
        public static readonly IReadOnlyList<FirstRunStep> InFlow =
            [FirstRunStep.Manager, FirstRunStep.AiProvider, FirstRunStep.Servers, FirstRunStep.Network, FirstRunStep.Vps, FirstRunStep.Build];

        public static string Name(this FirstRunStep step) => step switch
        {
            FirstRunStep.Manager => "Manager",
            FirstRunStep.AiProvider => "AI provider",
            FirstRunStep.Servers => "Servers",
            FirstRunStep.Network => "Network",
            FirstRunStep.Vps => "VPS",
            _ => "Build",
        };

        public static IReadOnlyList<string> Names => InFlow.Select(Name).ToList();

        /// <summary>**The step of a page**, by the page's name, or null for a page that shows no steps: the welcome page,
        /// "Help improve Founderizer", a build and an install (which show their own steps), and the pages after them. The
        /// pages after "Name your manager" show the steps only when the owner came through that page.</summary>
        public static FirstRunStep? Of(string page, bool named) => page switch
        {
            "name" => FirstRunStep.Manager,
            "aiProvider" => named ? FirstRunStep.AiProvider : null,
            "servers" => named ? FirstRunStep.Servers : null,
            "network" or "key" => named ? FirstRunStep.Network : null,
            "cloud" or "token" or "vps" or "machine" => named ? FirstRunStep.Vps : null,
            _ => null,
        };
    }

    /// <summary>The steps on Back's line: their names and the place of the page's own step.</summary>
    public sealed record SetupProgress(IReadOnlyList<string> Names, int Current);

    /// <summary>**What the first run does with the manager's AI provider when it hands the window over** (the Mac's
    /// FirstRunHandover): the owner chose it on the first run's page, so the manager's setup does not ask again.</summary>
    public abstract record FirstRunHandover
    {
        /// <summary>The manager has no server yet: its setup gets the provider with its server.</summary>
        public sealed record Keep(string Provider) : FirstRunHandover;
        /// <summary>This first run's installer put the manager on the hub's own server with that program: the first run
        /// asks for its sign-in, and hands the window over when that request has its answer.</summary>
        public sealed record SignIn(string Provider) : FirstRunHandover;
        /// <summary>Nothing to give: the window goes on at once.</summary>
        public sealed record None : FirstRunHandover;

        /// <summary><paramref name="chosen"/>: the provider of this first run, or null. <paramref name="placed"/> and
        /// <paramref name="runtime"/>: the hub's manager, or null with no manager there. <paramref name="writes"/>: the hub
        /// takes a write now. <paramref name="asked"/>: the sign-in is on its way already.</summary>
        public static FirstRunHandover Of(string? chosen, bool? placed, string? runtime, bool installedOneServer, bool writes, bool asked)
        {
            if (chosen is null || placed is not { } isPlaced) return new None();
            if (!isPlaced) return new Keep(chosen);
            if (!installedOneServer || runtime != chosen || !writes || asked) return new None();
            return new SignIn(chosen);
        }
    }

    /// <summary>**The hub's three feature words for the fleet's shape** (owner API 1.175).</summary>
    public static class FleetShapeHub
    {
        public const string Kept = "fleet_shape";
        public const string Later = "hub_shared_later";
        public const string Rename = "manager_rename";
    }

    /// <summary>**The steps of the manager's own setup**, on Back's line of each of its pages while it gets its first
    /// server (the Mac's ManagerSetupSteps): its name, its AI provider, the servers, its sign-in.</summary>
    public enum ManagerSetupStep { Manager, Provider, Servers, SignIn }

    public static class ManagerSetupSteps
    {
        public static readonly IReadOnlyList<ManagerSetupStep> All =
            [ManagerSetupStep.Manager, ManagerSetupStep.Provider, ManagerSetupStep.Servers, ManagerSetupStep.SignIn];

        public static string Name(this ManagerSetupStep step) => step switch
        {
            ManagerSetupStep.Manager => "Manager",
            ManagerSetupStep.Provider => "AI provider",
            ManagerSetupStep.Servers => "Servers",
            _ => "Sign in",
        };

        public static IReadOnlyList<string> Names => All.Select(Name).ToList();

        /// <summary>**The step of a page of an agent's setup**, as its place in the line: the wait for the provider's
        /// install on its server and a switch of provider are the step Servers, and after the sign-in each step is done.</summary>
        public static int Current(AgentSetupPage page) => page switch
        {
            AgentSetupPage.Name => (int)ManagerSetupStep.Manager,
            AgentSetupPage.Provider => (int)ManagerSetupStep.Provider,
            AgentSetupPage.Servers or AgentSetupPage.Server or AgentSetupPage.Installing or AgentSetupPage.Switching => (int)ManagerSetupStep.Servers,
            AgentSetupPage.SignIn => (int)ManagerSetupStep.SignIn,
            _ => All.Count,
        };
    }

    /// <summary>**What the manager's first setup shows before its server's page** (the Mac's ManagerSetupStart), in a
    /// fleet whose first run did not ask: its name, then the fleet's servers. The hub's kept step says that the two pages
    /// are done.</summary>
    public abstract record ManagerSetupStart
    {
        public sealed record Name : ManagerSetupStart;
        public sealed record Servers : ManagerSetupStart;
        /// <summary>"1 server" is kept, and the hub's own server is not ready for the manager: the owner's computer's root
        /// step when the server has no server service (<paramref name="RootStep"/>), then the hub's reading of it.</summary>
        public sealed record Sharing(bool RootStep) : ManagerSetupStart;
        /// <summary>"1 server" is kept, and the hub's own server takes the manager.</summary>
        public sealed record OnHub(string Machine) : ManagerSetupStart;
        /// <summary>Nothing comes before its server's page.</summary>
        public sealed record Server : ManagerSetupStart;
        /// <summary>The hub has the parts and no read of its servers answered yet.</summary>
        public sealed record Unread : ManagerSetupStart;

        /// <summary>**For the agent of a setup**: only a manager with no server gets these pages, on a visit that read the
        /// hub's features (null before that read), and not once a server joined for it on this PC.</summary>
        public static ManagerSetupStart Page(string? role, bool? placed, bool joined, IReadOnlyList<string>? features, bool named,
                                             ServerList? list)
        {
            if (role != "manager" || placed != false || joined || features is null) return new Server();
            return Page(features, named, list);
        }

        /// <summary><paramref name="named"/>: the owner went on from the name's page on this run of the app.
        /// <paramref name="list"/>: the hub's list of servers, or null while no read answered.</summary>
        public static ManagerSetupStart Page(IReadOnlyList<string> features, bool named, ServerList? list)
        {
            if (!features.Contains(FleetShapeHub.Kept) || !features.Contains(FleetShapeHub.Later)) return new Server();
            if (list is null) return new Unread();
            switch (list.KeptStep)
            {
                case null: return features.Contains(FleetShapeHub.Rename) && !named ? new Name() : new Servers();
                case "two" or "each": return new Server();
                default:
                    if (list.HubShared != true || list.HubRow is not { } hub) return new Sharing(false);
                    if (hub.Joined && hub.Available) return new OnHub(hub.Name);
                    return new Sharing(!hub.Joined);
            }
        }

        /// <summary>**The page of the manager's own setup while it has no server**, in the owner's order: its name, its AI
        /// provider, the fleet's servers, its server. <paramref name="provider"/>: the AI that the owner chose on this PC,
        /// or null. <paramref name="placeOn"/>: the server that it goes on now, or null. Once both are there, the setup
        /// gives it that server and that provider by itself, and the page is the install. A command that the hub refused
        /// shows the provider's page again.</summary>
        public AgentPage PageOf(bool renaming, string? provider, string? placeOn, bool refused)
        {
            if (renaming) return AgentPage.Of(AgentSetupPage.Name);
            switch (this)
            {
                case Name: return AgentPage.Of(AgentSetupPage.Name);
                case Unread: return AgentPage.Of(AgentSetupPage.Servers);
            }
            if (provider is null || refused) return AgentPage.Of(AgentSetupPage.Provider);
            return this switch
            {
                Servers or Sharing => AgentPage.Of(AgentSetupPage.Servers),
                _ => placeOn is null ? AgentPage.Of(AgentSetupPage.Server) : AgentPage.Installing(provider),
            };
        }
    }
}
