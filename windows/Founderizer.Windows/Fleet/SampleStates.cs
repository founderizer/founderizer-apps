using System;
using System.Linq;
using System.Text.Json.Nodes;
using Founderizer.Core;

namespace Founderizer.Windows.Fleet;

/// <summary>The states of the second set of pictures (windows-app-pictures-2.md), for the pictures only:
/// FOUNDERIZER_SAMPLE_STATE names one, and the sample changes its reads or its state as that picture's table "Not from
/// the sample" says. Each state is the store's own form of that moment (a refusal of the key, a read with no answer, a
/// write that waits), so that the window draws it from the library's models as it draws a real one.</summary>
public sealed partial class SampleSource
{
    private readonly string? pictureState = Proofs.Variable("FOUNDERIZER_SAMPLE_STATE");
    private string? addressError;

    /// <summary>Four minutes: the age of the last reading in pictures 9a and 9b.</summary>
    private const double Stale = 240;

    /// <summary>The state of the picture over the sample's own state.</summary>
    private StoreState Picture(StoreState s, DateTimeOffset at)
    {
        s = s with { AddressError = addressError };
        switch (pictureState)
        {
            case "code-refused":
                // Picture 8: a PC with no hub yet, on Add this PC.
                return s with { Hub = null, Fleet = null, Key = KeyState.None, Device = null, Chats = s.Chats.Clear(), TaskPages = s.TaskPages.Clear() };
            case "not-enrolled":
                // Picture 9a: the hub no longer knows this PC; the page shows the last reading.
                return s with { AuthProblem = "device_not_enrolled", ReadWasRefused = true, LastRead = at.AddSeconds(-Stale), SnapshotAt = at.AddSeconds(-Stale) };
            case "no-answer":
                // Picture 9b: the hub does not answer; Settings says how old the last reading is.
                return s with
                {
                    ReadError = HubException.NoAnswer(),
                    LastRead = at.AddSeconds(-Stale),
                    SnapshotAt = at.AddSeconds(-Stale),
                    // Its age is on the hub's clock (the sample's time, plus the time since the last reading): the
                    // sample's own clock is four minutes before the hub's now.
                    Device = s.Device! with { LastSeen = now },
                };
            case "reading":
                // Picture 13: the first read of the hub runs: an address and a key, and no reading yet.
                return s with { Fleet = null, LastRead = null, SnapshotAt = null, Chats = s.Chats.Clear(), TaskPages = s.TaskPages.Clear() };
            case "files":
                // Picture 4: the file that he added to Marketing's composer, on the hub, and his next words.
                return s with
                {
                    Staged = s.Staged.SetItem("agent:orla", ValueList.Of(new[]
                    {
                        new StagedFile
                        {
                            RequestId = new Guid("00000000-0000-0000-0000-0000000000d1"), Name = "logo.png", Mime = "image/png", Size = 48 * 1024,
                            File = new MessageAttachment(703, "logo.png", "image/png", 48 * 1024, new string('0', 64), now - 30),
                        },
                    })),
                    Drafts = s.Drafts.SetItem("orla", "And our logo, for the footer."),
                };
            case "not-sent":
                // Picture 14: his message to Customer Support, which the hub did not confirm, and nothing on its way.
                return s with
                {
                    Pending = PendingRequest.New(s.Hub!, s.Fleet!.Db, "PC", "Which order is it?", recipient: "wren") with
                    {
                        CreatedAt = DateTimeOffset.FromUnixTimeMilliseconds((long)((now - 60) * 1000)),
                    },
                    Sending = false,
                };
            default:
                return s;
        }
    }

    /// <summary>Picture 10: the notification of the request about the email, three seconds after the start, once.</summary>
    private void NotifyLater()
    {
        if (pictureState != "notify") return;
        _ = System.Threading.Tasks.Task.Delay(TimeSpan.FromSeconds(3)).ContinueWith(_ =>
        {
            var s = State;
            if (s.Hub is not { } hub || s.Fleet is not { } fleet) return;
            var need = fleet.Needs.First(n => n.Id == 2);
            Notified?.Invoke(this, [new Notice(Notifications.Context(hub, fleet.Db), need.Id, s.Names.Label(need.By), need.Title)]);
        }, System.Threading.Tasks.TaskScheduler.Default);
    }

    /// <summary>The words of the enrollment in picture 8: the hub's refusal of the code (403).</summary>
    private string? EnrollWords() => pictureState == "code-refused"
        ? HubException.EnrollWords(HubException.Refusal(403, null, "the code is not valid"))
        : null;

    /// <summary>Connect as the store does it (picture 9c): an address that cannot be a hub's is refused with the library's
    /// words, and the store keeps them; any other is taken.</summary>
    private string? Connect(string address)
    {
        try
        {
            HubClient.Address(address);
            addressError = null;
        }
        catch (HubException e)
        {
            addressError = e.Message;
        }
        return addressError;
    }

    /// <summary>The reads of the picture: the hub's answer to GET /ui/mobile.</summary>
    private void PictureMobile(JsonObject mobile)
    {
        var agents = mobile["agents"]!.AsArray();
        JsonObject Agent(string name)
        {
            foreach (var a in agents) if ((string?)a!["name"] == name) return a.AsObject();
            throw new InvalidOperationException("no agent " + name);
        }
        switch (pictureState)
        {
            case "answered":
            {
                // Picture 16: his answer "Offer a 20% voucher" to the refund at 15:12; the hub writes it as his message.
                var needs = mobile["needs"]!.AsArray();
                JsonObject? refund = null;
                foreach (var n in needs) if ((long?)n!["id"] == 1) refund = n.AsObject();
                needs.Remove(refund);
                refund!["answer"] = "Offer a 20% voucher";
                refund["answered"] = now;
                refund["answered_by"] = "owner";
                refund["chose"] = new JsonArray(1);
                mobile["answered_needs"]!.AsArray().Add(refund);
                Agent("manager")["last"] = new JsonObject { ["preview"] = "Offer a 20% voucher", ["side"] = "owner", ["ts"] = now };
                break;
            }
            case "all-answered":
            {
                // Picture 12: both requests answered.
                var needs = mobile["needs"]!.AsArray();
                var answers = new[] { "Offer a 20% voucher", "Send it on Monday" };
                foreach (var n in needs.ToArray())
                {
                    var need = n!.AsObject();
                    needs.Remove(need);
                    var id = (long)need["id"]!;
                    need["answer"] = answers[id == 1 ? 0 : 1];
                    need["answered"] = now - 120 + id * 30;
                    need["answered_by"] = "owner";
                    need["chose"] = new JsonArray(id == 1 ? 1 : 0);
                    mobile["answered_needs"]!.AsArray().Add(need);
                }
                // The task that waited on the email's yes goes on.
                foreach (var t in mobile["tasks"]!.AsArray()) if ((long?)t!["id"] == 3) t["waiting_on"] = null;
                break;
            }
            case "usage":
            {
                // Picture 7: Customer Support's reading: 5 h at 42 % to 17:00, 7 d at 18 % to Friday 09:00.
                var today = DateTimeOffset.FromUnixTimeMilliseconds((long)(now * 1000)).ToLocalTime();
                var five = new DateTimeOffset(today.Date + new TimeSpan(17, 0, 0), today.Offset);
                int days = ((int)DayOfWeek.Friday - (int)today.DayOfWeek + 7) % 7;
                var friday = new DateTimeOffset(today.Date.AddDays(days == 0 ? 7 : days) + new TimeSpan(9, 0, 0), today.Offset);
                Agent("wren")["usage"] = new JsonArray
                {
                    new JsonObject { ["label"] = "5 hours", ["used_percent"] = 42, ["resets_at"] = five.ToUnixTimeSeconds() },
                    new JsonObject { ["label"] = "7 days", ["used_percent"] = 18, ["resets_at"] = friday.ToUnixTimeSeconds() },
                };
                break;
            }
            case "failed":
                // Picture 5: "Post the new arrivals" failed (the sample has it completed).
                foreach (var t in mobile["recent"]!.AsArray())
                    if ((string?)t!["title"] == "Post the new arrivals") { t["state"] = "failed"; t["accepted"] = null; }
                break;
            case "paused" or "stopping":
                // Pictures 6a and 6b: a pause on the Developer's task, then a stop.
                mobile["holds"]!.AsArray().Add(Hold());
                break;
            case "files":
                Agent("orla")["last"] = new JsonObject
                {
                    ["preview"] = "Put this picture at the top of the email. The prices are in the file.", ["side"] = "owner", ["ts"] = now - 120,
                };
                break;
            case "marks":
                // Picture 15: Marketing at its usage limit, DevOps not answering.
                Agent("orla")["limit"] = new JsonObject { ["since"] = now - 600, ["until"] = now + 3600, ["reset_known"] = true };
                Agent("pax")["last_seen"] = now - 3600;
                break;
        }
    }

    /// <summary>The reads of the picture: one chat.</summary>
    private void PictureChat(string agent, JsonObject chat)
    {
        if (pictureState == "files" && agent == "orla")
        {
            // Picture 4: his message with a picture and a file, at 15:10.
            var message = Message("00000000-0000-0000-0000-0000000000c1", "Put this picture at the top of the email. The prices are in the file.", now - 120);
            message["attachments"] = new JsonArray { Attachment(701, "spring-sale.png", "image/png", 11690), Attachment(702, "spring-prices.csv", "text/csv", 12 * 1024) };
            message["read_at"] = now - 110;
            chat["items"]!.AsArray().Add(message);
        }
        if (pictureState == "answered" && agent == "manager")
        {
            var answer = Message("00000000-0000-0000-0000-0000000000b1", "Offer a 20% voucher", now);
            answer["answer_to"] = 1;
            chat["items"]!.AsArray().Add(answer);
        }
    }

    /// <summary>The reads of the picture: one task's page.</summary>
    private void PictureTask(long id, JsonObject page)
    {
        if (pictureState is "paused" or "stopping" && id == 2) page["holds"]!.AsArray().Add(Hold());
    }

    /// <summary>The owner's hold on the Developer's task (task 2): a pause that holds, or a stop that the hub was asked for.</summary>
    private JsonObject Hold() => new()
    {
        ["id"] = 1,
        ["task"] = 2,
        ["kind"] = pictureState == "stopping" ? "stop" : "pause",
        ["state"] = pictureState == "stopping" ? "requested" : "held",
        ["attempt"] = 1,
        ["by"] = "owner",
    };

    /// <summary>The bytes of a file of a message in a picture: the picture and the logo of picture 4, and the prices.</summary>
    private static byte[] SampleFile(MessageAttachment file)
    {
        using var stream = System.Reflection.Assembly.GetExecutingAssembly().GetManifestResourceStream("Founderizer.Windows.Sample." + file.Name);
        if (stream is null) return System.Text.Encoding.UTF8.GetBytes("item,price\nT-shirt,16\nCap,12\n");
        var memory = new System.IO.MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    }

    private static JsonObject Attachment(long id, string name, string mime, long size) => new()
    {
        ["id"] = id,
        ["name"] = name,
        ["mime"] = mime,
        ["size"] = size,
        ["sha256"] = new string('0', 64),
        ["created"] = 0,
    };
}
