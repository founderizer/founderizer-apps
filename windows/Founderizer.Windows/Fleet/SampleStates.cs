using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
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
            case "first-read":
                // Picture 5b of the third set: Marketing's chat was not read yet (the sample answers no read of it).
                return s with { Chats = s.Chats.Remove("orla") };
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

    /// <summary>The certificate that the DevOps task's result names (fourth set, 1b and 1d): 149 bytes.</summary>
    private const string Certificate = "subject=CN = shop.example.com\nissuer=C = US, O = Example CA, CN = Example CA R3\n" +
                                       "notBefore=Nov 13 10:58:04 2026 GMT\nnotAfter=Feb 11 10:58:03 2027 GMT\n";

    /// <summary>The commit of the outputs' snapshot (fourth set, 1d).</summary>
    private const string OutputsCommit = "2660dc5328ab45838faa253c9a6503124c423ec0";

    /// <summary>The checked outputs of the sample's accepted task (4) in the fourth set's state "outputs": a text file and
    /// a picture; in "no-outputs" none, as the sample itself has.</summary>
    private IReadOnlyList<ArtifactFile> SampleOutputs(long task)
    {
        if (pictureState != "outputs" || task != 4) return Array.Empty<ArtifactFile>();
        return new[] { "outputs/T-4/certificate.txt", "outputs/T-4/shop-page.png" }.Select(path =>
        {
            var bytes = SampleOutput(path);
            return new ArtifactFile(path, OutputsCommit, Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes)),
                                    bytes.Length, path.EndsWith(".png", StringComparison.Ordinal) ? "image/png" : "text/plain");
        }).ToArray();
    }

    /// <summary>An output's bytes: the certificate, or the picture of the shop's page. The picture comes from the file
    /// that FOUNDERIZER_SAMPLE_PICTURE names (the pictures' run puts the approved picture's own there), else it is a plain
    /// one: a grey bar over a light green field.</summary>
    private static byte[] SampleOutput(string path)
    {
        if (!path.EndsWith(".png", StringComparison.Ordinal)) return Encoding.UTF8.GetBytes(Certificate);
        if (Proofs.Variable("FOUNDERIZER_SAMPLE_PICTURE") is { } file && System.IO.File.Exists(file)) return System.IO.File.ReadAllBytes(file);
        return PlainPng(1208, 680);
    }

    /// <summary>A PNG with no library: rows of a grey bar (68) and then a light green field.</summary>
    private static byte[] PlainPng(int width, int height)
    {
        var raw = new byte[height * (width * 3 + 1)];
        for (int y = 0; y < height; y++)
        {
            byte[] colour = y < 68 ? [0xEF, 0xEF, 0xEF] : [0xDC, 0xEB, 0xD3];
            for (int x = 0; x < width; x++) colour.CopyTo(raw, y * (width * 3 + 1) + 1 + x * 3);
        }
        using var packed = new System.IO.MemoryStream();
        using (var z = new System.IO.Compression.ZLibStream(packed, System.IO.Compression.CompressionLevel.Optimal)) z.Write(raw);
        using var png = new System.IO.MemoryStream();
        png.Write([0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        void Chunk(string kind, byte[] data)
        {
            var name = Encoding.ASCII.GetBytes(kind);
            png.Write(BigEndian((uint)data.Length));
            png.Write(name);
            png.Write(data);
            png.Write(BigEndian(Crc32([.. name, .. data])));
        }
        Chunk("IHDR", [.. BigEndian((uint)width), .. BigEndian((uint)height), 8, 2, 0, 0, 0]);
        Chunk("IDAT", packed.ToArray());
        Chunk("IEND", []);
        return png.ToArray();
    }

    /// <summary>PNG's CRC-32 (ISO 3309), bit by bit: the plain picture is one small file.</summary>
    private static uint Crc32(byte[] bytes)
    {
        uint crc = 0xFFFFFFFF;
        foreach (var b in bytes)
        {
            crc ^= b;
            for (int k = 0; k < 8; k++) crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
        }
        return ~crc;
    }

    private static byte[] BigEndian(uint value) => [(byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value];

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
        if (pictureState == "waiting-request")
        {
            // Picture 9 of the fifth set: the request about the email raised at 15:05, after the manager's reply of 15:04.
            foreach (var n in mobile["needs"]!.AsArray()) if ((long?)n!["id"] == 2) n["raised"] = now - 420;
        }
        switch (pictureState)
        {
            case "card":
            {
                // The Mac's request card of Founderizer 0.1.239: a task of numbered steps with a page, bold and a command
                // in a fenced block (no details, a short reason with inline code); a long reason with a link and bold and
                // details of a list; a long reason with no details, whose start folds.
                var needs = mobile["needs"]!.AsArray();
                needs.Add(new JsonObject
                {
                    ["id"] = 4, ["by"] = "manager", ["title"] = "Turn on the backups of the example shop?",
                    ["why"] = "The backups of web-1 stopped 3 days ago, when the `example-backup` timer was turned off.",
                    ["todo"] = "1. Open https://dash.example.com/backups.\n2. Press **Turn on** for web-1.\n3. Run this on web-1:\n\n```\nsudo systemctl enable --now example-backup.timer\n```",
                    ["raised"] = now - 240, ["options"] = new JsonArray("Done", "Not now"), ["multi"] = false, ["talk"] = new JsonArray(),
                });
                needs.Add(new JsonObject
                {
                    ["id"] = 5, ["by"] = "manager", ["title"] = "Move the example shop's images to the new storage?",
                    ["why"] = "The images of the example shop take **38 GB** on web-1, and its disk is 92% full. The new storage at https://storage.example.com costs 4 euros a month for 100 GB. I can move them tonight, when the shop has the fewest visitors, and keep the old folder for 7 days.",
                    ["todo"] = "Press **Move tonight**, or **Not now** to keep them on web-1.",
                    ["details"] = "**What moves:**\n\n- `/srv/example-shop/images`, 38 GB\n- the thumbnails, 2 GB\n\nThe shop reads its images from the new address after the move.",
                    ["raised"] = now - 150, ["options"] = new JsonArray("Move tonight", "Not now"), ["multi"] = false, ["talk"] = new JsonArray(),
                });
                needs.Add(new JsonObject
                {
                    ["id"] = 6, ["by"] = "manager", ["title"] = "Answer the example supplier's offer?",
                    ["why"] = "The example supplier offers the spring stock at **12% off** if we order 400 units before Friday. Last spring we sold 310 units, and the `stock-check` report at https://reports.example.com/spring says 120 are left. The offer ends on Friday at 17:00, and the supplier asks for one answer for all three sizes.",
                    ["todo"] = "Write your answer, or press one.",
                    ["raised"] = now - 60, ["options"] = new JsonArray("Accept the offer", "Ask for a lower price"), ["multi"] = false, ["talk"] = new JsonArray(),
                });
                break;
            }
            case "pictures":
            {
                // Pictures as the options of a request (owner feature need_pictures; w4-windows-chat.png and
                // w4-windows-needs.png): Marketing asks which banner of the spring sale goes live, with a picture for
                // each option, on a hub that names the feature.
                mobile["ui_features"]!.AsArray().Add((JsonNode)NeedPictures.Feature);
                var pictures = new JsonArray();
                for (int i = 0; i < Banners.Length; i++)
                {
                    var bytes = SampleBanner(Banners[i]);
                    pictures.Add(new JsonObject
                    {
                        ["id"] = 801 + i, ["name"] = Banners[i], ["mime"] = "image/png", ["size"] = bytes.Length,
                        ["sha256"] = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(bytes)), ["created"] = now - 300,
                    });
                }
                mobile["needs"]!.AsArray().Add(new JsonObject
                {
                    ["id"] = 7, ["by"] = "orla", ["title"] = "Pick the banner for the spring sale",
                    ["why"] = "Three versions of the sale banner for the shop’s home page. The one you pick goes live on Monday.",
                    ["todo"] = "", ["details"] = "Each banner is 1200 by 1200 pixels, for the home page and the email.",
                    ["raised"] = now - 240, ["options"] = new JsonArray("Green, the flowers", "Yellow, big words", "Blue, the sky"),
                    ["multi"] = false, ["talk"] = new JsonArray(), ["pictures"] = pictures,
                });
                break;
            }
            case "clarify":
            {
                // Needs clarification on every card (owner feature need_clarify; w4-windows-chat.png and
                // w4-windows-needs.png): the manager's cards take his message, and the card about the email has his
                // question and the manager's reply over its answers.
                mobile["ui_features"]!.AsArray().Add((JsonNode)NeedClarify.Feature);
                foreach (var n in mobile["needs"]!.AsArray())
                {
                    n!["clarify"] = true;
                    if ((long?)n["id"] != 2) continue;
                    n["talk"] = new JsonArray
                    {
                        new JsonObject { ["who"] = "owner", ["text"] = "Does it go to the people who left the list in March?", ["ts"] = now - 600 },
                        new JsonObject { ["who"] = "manager", ["text"] = "No. The list leaves them out, so 4,800 people get it.", ["ts"] = now - 540 },
                    };
                }
                break;
            }
            case "door":
            {
                // A door card that carries its script (raise_needs_you door_script): the hub's title with the server, its
                // fixed answers, and the script as the details, one fenced block (hub.py door_script_details).
                const string script = "#!/bin/sh\nset -eu\nfind /srv/example-shop/releases -mindepth 1 -maxdepth 1 -type d -mtime +14 -print -exec rm -rf {} +\ndf -h /srv/example-shop | tail -n 1\n";
                mobile["needs"]!.AsArray().Add(new JsonObject
                {
                    ["id"] = 3, ["by"] = "manager", ["title"] = "Run one root script on web-1?",
                    ["why"] = "The disk of web-1 is 92% full. The script removes the shop's release folders older than 14 days.",
                    ["todo"] = "Read the script. Run it once lets the door run it one time.",
                    ["raised"] = now - 180, ["options"] = new JsonArray("Run it once", "Full access on web-1", "No"),
                    ["door_call"] = new string('a', 64), ["door_host"] = "web-1", ["door_script"] = script,
                    ["details"] = "```\n" + script + "```", ["multi"] = false, ["talk"] = new JsonArray(),
                });
                break;
            }
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
            case "all-answered" or "work-mark":
            {
                // Picture 12: both requests answered. "work-mark": from a hub that names need_marks, whose yes to the
                // email lets Marketing's task go on, so its card wears the work mark and its hover (the owner's "Yes,
                // badge as drawn" of 21 November 2026).
                if (pictureState == "work-mark") mobile["ui_features"]!.AsArray().Add((JsonNode)AnswerMark.Feature);
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
                    if (pictureState == "work-mark" && id == 2) need["task"] = 3;
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
            case "markdown":
                // Picture 4 of the third set: DevOps's reply in Markdown at 12:12 is its last message.
                Agent("pax")["last"] = new JsonObject { ["preview"] = MarkdownReply, ["side"] = "agent", ["ts"] = now - 10800 };
                // Its turn ended with that reply: no "Thinking" after it.
                Agent("pax")["turn_ended_after"] = now - 10800;
                break;
            case "no-messages":
                // Picture 5a of the third set: no message with the Developer.
                Agent("theo")["last"] = null;
                break;
            case "marks":
                // Picture 15: Marketing at its usage limit, DevOps not answering.
                Agent("orla")["limit"] = new JsonObject { ["since"] = now - 600, ["until"] = now + 3600, ["reset_known"] = true };
                Agent("pax")["last_seen"] = now - 3600;
                break;
        }
    }

    /// <summary>DevOps's reply of picture 4 of the third set, in Markdown, as agents write it.</summary>
    private const string MarkdownReply =
        "### Last night's backups\n\n" +
        "All three backups ran at 03:00, and I tested one restore. The shop server uses 41% of its disk.\n\n" +
        "- **Database:** complete, 1.2 GB. I restored it to a test folder, and it opened.\n" +
        "- **Files:** complete, 8.4 GB.\n" +
        "- **Settings:** complete. The newest copy is `settings-2026-11-13.tar`.\n\n" +
        "To see them on the server yourself:\n\n" +
        "```\nls -lh /backups/2026-11-13\n```\n\n" +
        "| Backup | Time | Size |\n| --- | --- | --- |\n| Database | 03:00 | 1.2 GB |\n| Files | 03:04 | 8.4 GB |\n| Settings | 03:09 | 4 MB |\n\n" +
        "The restore log is in [the backup report](https://example.com/backups/2026-11-13).";

    /// <summary>The reads of the picture: one chat.</summary>
    private void PictureChat(string agent, JsonObject chat)
    {
        if (pictureState == "markdown" && agent == "pax")
        {
            // Picture 4 of the third set: his question at 12:10, and the reply in Markdown at 12:12 in place of the
            // sample's one line.
            var items = chat["items"]!.AsArray();
            items.Clear();
            items.Add(Message("00000000-0000-0000-0000-0000000000e1", "How did last night's backups go?", now - 10920));
            items.Add(new JsonObject
            {
                ["about"] = "", ["id"] = 2, ["in_reply_to"] = null, ["kind"] = "report", ["pushed"] = true,
                ["text"] = MarkdownReply, ["ts"] = now - 10800,
            });
        }
        if (pictureState == "no-messages" && agent == "theo") chat["items"]!.AsArray().Clear();
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
        var task = page["task"]!.AsObject();
        if (pictureState is "steps-opened" or "error" or "thinking" or "plan" or "guidance" or "child" or "earlier" && id == 1)
            task["last_activity"] = now - 360;
        if (pictureState == "error" && id == 1) { task["attempt"] = 2; task["restarts"] = 1; }
        if (pictureState == "guidance" && id == 1)
            page["steers"] = new JsonArray(new JsonObject
            {
                ["id"] = 1, ["task"] = 1, ["attempt"] = 1, ["text"] = "Answer the refund ticket last: it waits for my decision in Needs you.",
                ["created"] = now - 5200, ["request_id"] = "00000000-0000-0000-0000-0000000000f1", ["client"] = "PC", ["read_at"] = now - 5100,
            });
        if (pictureState == "subtasks" && id == 2)
        {
            task["parent"] = 7;
            JsonObject Head(long n, string title, string state) => new()
            {
                ["id"] = n, ["title"] = title, ["state"] = state, ["owner"] = "theo", ["requester"] = "manager", ["goal"] = null,
                ["needs"] = "none", ["attempt"] = 1, ["accepted"] = null, ["created"] = now - 20000, ["parent"] = n == 7 ? null : 2,
            };
            page["parent_task"] = Head(7, "Get the shop ready for the spring sale", "working");
            page["subtasks"] = new JsonArray(Head(8, "Test the checkout on Android", "working"), Head(9, "Tell the customers whose orders failed", "submitted"));
        }
        if (pictureState == "steps" && id == 1)
        {
            // Pictures 2a to 2c of the fourth set: Customer Support's task waits for a permission of Bash since 15:06.
            page["task"]!.AsObject()["state"] = "input-required";
            page["permissions"] = new JsonArray(new JsonObject
            {
                ["id"] = 1, ["tool"] = "Bash", ["created"] = now - 360, ["decision"] = null, ["reason"] = null,
                ["input"] = "curl -s -X POST https://help.example.com/api/tickets/10517/reply -d @replies/10517.json",
            });
        }
        if (pictureState is "paused" or "stopping" && id == 2) page["holds"]!.AsArray().Add(Hold());
        if (pictureState == "failed" && id == 6)
        {
            // Picture 2 of the third set: "Post the new arrivals" failed, with its reason, and is not checked yet.
            task["state"] = "failed";
            task["accepted"] = null;
            task["checked_at"] = null;
            task["what"] = "The post did not go live. The shop's page refused the picture: it is larger than its limit of 8 MB.";
        }
    }

    /// <summary>A task's record as a helper sends it, for the states of the fourth and fifth sets: each event numbered in
    /// order, at a time before the sample's now.</summary>
    private sealed class Record(double now)
    {
        public readonly List<TaskEvent> Events = new();
        private long next;
        public long Attempt = 1;

        public TaskEvent Add(string type, double ago, string? text = null, string? title = null, string? kind = null,
                             string? status = null, string? output = null, string? message = null, string? call = null,
                             string? parent = null, IReadOnlyList<EventLocation>? locations = null,
                             IReadOnlyList<FileChange>? changes = null, EventSubagent? subagent = null,
                             IReadOnlyList<PlanEntry>? entries = null, string? runtime = null)
        {
            next++;
            var e = new TaskEvent(next, Attempt, "00000000-0000-4000-8000-00000000000" + Attempt, next, now - ago, type,
                                  Runtime: runtime, Text: text, ToolCallId: call, Title: title, Kind: kind, Status: status,
                                  Output: output, Message: message, Entries: entries, Parent: parent, Locations: locations,
                                  Changes: changes, Subagent: subagent);
            Events.Add(e);
            return e;
        }

        /// <summary>A tool call that the hub recorded at its end.</summary>
        public string Call(double ago, string title, string kind, string status = "completed", string? output = null,
                           string? parent = null, IReadOnlyList<EventLocation>? locations = null,
                           IReadOnlyList<FileChange>? changes = null, EventSubagent? subagent = null)
        {
            var call = "call-" + (next + 1);
            Add("tool_call", ago, title: title, kind: kind, status: status, output: output, call: call, parent: parent,
                locations: locations, changes: changes, subagent: subagent);
            return call;
        }

        public TaskActivity Activity() => TaskActivity.Of(ActivityTimeline.Of(Events), next);
    }

    /// <summary>A task's record as the store holds it: Customer Support's (task 1) or the Developer's (task 2) in a state
    /// of the fourth or the fifth set (windows-app-pictures-5.md, "Not from the sample"); every other task's record is
    /// read and empty.</summary>
    private TaskActivity SampleActivity(long id)
    {
        var r = new Record(now);
        const string Fetch = "Fetch https://help.example.com/api/tickets?status=open";
        string Reply(long n) => $"python3 replies/make_reply.py {n}";
        switch (pictureState, id)
        {
            case ("steps", 1):
                r.Add("session", 10650, runtime: "claude");
                r.Call(10600, Fetch, "fetch", output: "23 open tickets");
                r.Call(10540, "Read knowledge/refund-policy.md", "read");
                r.Call(10480, "Read knowledge/shipping-times.md", "read");
                r.Call(10420, "Search tracking in replies", "search");
                r.Call(10360, Reply(10482), "execute", "failed");
                r.Call(10300, "Edit replies/make_reply.py", "edit", changes: new[] { new FileChange("replies/make_reply.py", "modify", 4, 1) });
                r.Call(10240, Reply(10482), "execute");
                r.Call(10180, Reply(10517), "execute");
                r.Add("agent_message", 1020, text: "I answered 23 tickets today. One customer asks for a refund outside the 30 days: it is in Needs you.");
                r.Call(900, "Read replies/10517.json", "read");
                r.Call(840, "python3 replies/check_reply.py 10517", "execute");
                return r.Activity();
            case ("steps-opened", 1):
                r.Add("session", 10650, runtime: "claude");
                r.Call(10600, Fetch, "fetch", output: "23 open tickets");
                r.Call(10540, "Read knowledge/refund-policy.md", "read",
                       output: "# Refunds\nWe refund an order within 30 days of its delivery.\nAfter 30 days, the Fleet Manager decides.",
                       locations: new[] { new EventLocation("knowledge/refund-policy.md") });
                r.Call(10480, "Search tracking in replies", "search", output: "No matches.");
                r.Call(10420, Reply(10482), "execute", "failed",
                       "Traceback (most recent call last):\n  File \"replies/make_reply.py\", line 41, in <module>\n    tracking = order[\"tracking\"]\nKeyError: 'tracking'");
                r.Call(10360, Reply(10517), "execute", output: "Reply 10517 written.");
                return r.Activity();
            case ("script", 2):
            {
                const string Rg = "rg -n postcode Sources/Checkout";
                const string Found = "Sources/Checkout/AddressFields.swift:41:    form.postcode = field.postcode\nSources/Checkout/PaymentForm.swift:88:    body.postcode = form.postcode";
                r.Add("session", 8850, runtime: "codex");
                // A Codex script that made one call: the call takes the script's place, and the script's result opens under it.
                var script = "call-script";
                r.Add("tool_call", 8800, title: "exec: text(await tools.exec_command({cmd:\"" + Rg + "\"}))", kind: "execute", status: "in_progress", call: script);
                r.Call(8790, Rg, "execute", output: Found);
                r.Add("tool_call_update", 8780, status: "completed", call: script, output: "Script completed\nWall time 0.4 seconds\nOutput:\n" + Found);
                r.Call(8700, "Read Sources/Checkout/AddressFields.swift", "read");
                r.Call(8640, "Read Sources/Checkout/PaymentForm.swift", "read");
                return r.Activity();
            }
            case ("error", 1):
                r.Add("session", 10650, runtime: "claude");
                r.Call(10600, Fetch, "fetch");
                r.Call(10540, "Read knowledge/shipping-times.md", "read");
                r.Call(10480, Reply(10482), "execute");
                r.Call(10420, Reply(10517), "execute", "in_progress");
                r.Add("error", 10400, message: "The connection to the AI provider was lost: the program ended with code 1.");
                r.Attempt = 2;
                r.Add("session", 10300, runtime: "claude");
                r.Call(10200, Reply(10517), "execute");
                r.Call(10140, Reply(10521), "execute");
                r.Call(10080, Reply(10523), "execute");
                return r.Activity();
            case ("thinking", 1):
                r.Add("session", 10650, runtime: "claude");
                r.Add("agent_thought", 10600, text: "Two tickets ask where a parcel is. I read the shipping times first, then answer both with their tracking links.");
                r.Call(10540, "Read knowledge/shipping-times.md", "read");
                r.Call(10480, "Fetch https://track.example.com/10482", "fetch");
                r.Call(10420, Reply(10482), "execute");
                r.Add("agent_message", 10360, text: "I answered the shipping tickets. Two parcels are late, and both customers have their tracking links.");
                return r.Activity();
            case ("plan", 1):
                r.Add("session", 10650, runtime: "claude");
                foreach (var n in new long[] { 10441, 10442, 10443, 10444, 10445, 10446 }) r.Call(10600 - (n - 10441) * 60, Reply(n), "execute");
                r.Add("agent_message", 9000, text: "I answered the 14 order questions. Now the shipping questions.");
                r.Call(800, Reply(10530), "execute");
                r.Call(400, Reply(10531), "execute", "in_progress");
                r.Add("plan", 390, entries: new[]
                {
                    new PlanEntry("Read today's tickets", "completed"), new PlanEntry("Answer the order questions", "completed"),
                    new PlanEntry("Answer the shipping questions", "in_progress"), new PlanEntry("Write the refund case for Needs you", "pending"),
                });
                return r.Activity();
            case ("guidance", 1):
                r.Add("session", 10650, runtime: "claude");
                foreach (var n in new long[] { 10441, 10442, 10443, 10444, 10445, 10446 }) r.Call(10600 - (n - 10441) * 60, Reply(n), "execute");
                r.Call(5000, Reply(10501), "execute");
                r.Call(4940, Reply(10502), "execute");
                r.Call(4880, Reply(10503), "execute");
                r.Add("agent_message", 4800, text: "I answered the shipping tickets first. The refund ticket waits for your decision.");
                return r.Activity();
            case ("child", 1):
            {
                r.Add("session", 10650, runtime: "claude");
                r.Call(10600, Fetch, "fetch");
                var child = r.Call(10540, "Agent", "other", output: "Two parcels are late: 10482 (2 days) and 10517 (1 day).",
                                   subagent: new EventSubagent("Check the tracking of late parcels"));
                r.Call(10530, "Read knowledge/shipping-times.md", "read", parent: child);
                r.Call(10520, "Fetch https://track.example.com/10482", "fetch", parent: child);
                r.Call(10510, "Fetch https://track.example.com/10517", "fetch", parent: child);
                r.Add("agent_message", 10505, text: "Two parcels are late: 10482 (2 days) and 10517 (1 day).", parent: child);
                r.Call(10480, Reply(10482), "execute");
                return r.Activity();
            }
            case ("earlier", 1):
            {
                r.Add("session", 10650, runtime: "claude");
                // After the task's note ("Started: …"): 2 rows that "Earlier activity" brings back, then the 80 that show:
                // the picture's 16, and 64 more.
                double ago = 10600;
                void Run(int steps, int failed, string said)
                {
                    for (int i = 0; i < steps; i++) r.Call(ago -= 1, Reply(11000 + (long)ago), "execute", i < failed ? "failed" : "completed");
                    r.Add("agent_message", ago -= 1, text: said);
                }
                Run(4, 0, "I read the tickets of the night.");
                Run(14, 0, "I answered the order questions of the morning: 9 tickets.");
                Run(9, 0, "I answered the shipping questions of the morning: 6 tickets.");
                Run(11, 1, "I answered 23 tickets today. One customer asks for a refund outside the 30 days: it is in Needs you.");
                Run(6, 0, "The afternoon tickets are coming in. I answer them as they come.");
                Run(8, 0, "I answered 5 more tickets: 3 about orders and 2 about returns.");
                Run(12, 0, "A customer asks for an invoice with a new address. I sent it.");
                Run(7, 0, "Two customers ask when the spring sale starts. I told them Monday.");
                Run(5, 0, "I answered 4 more tickets about shipping times.");
                for (int n = 0; n < 32; n++) Run(2, 0, $"I answered ticket {10600 + n}.");
                return r.Activity();
            }
            case ("subtasks", 2):
                // After the task's note of 12:44 ("Started: …").
                r.Add("session", 8850, runtime: "codex");
                foreach (var n in Enumerable.Range(0, 8)) r.Call(8800 - n * 60, "Read Sources/Checkout/File" + n + ".swift", "read", n == 3 ? "failed" : "completed");
                r.Add("agent_message", 8000, text: "I found the checkout error: Safari on iPhone sent the postcode twice. I test the fix with three cards before it goes live.");
                return r.Activity();
            default:
                return new TaskActivity();
        }
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
    /// <summary>The three banners of the state "pictures", by their file names.</summary>
    private static readonly string[] Banners = ["banner-green.png", "banner-yellow.png", "banner-blue.png"];

    /// <summary>A banner's bytes: the file of that name in the folder that FOUNDERIZER_SAMPLE_PICTURES names (the
    /// pictures' run puts the drawing's banners there), else a plain one.</summary>
    private static byte[] SampleBanner(string name)
    {
        if (Proofs.Variable("FOUNDERIZER_SAMPLE_PICTURES") is { } folder && System.IO.File.Exists(System.IO.Path.Combine(folder, name)))
            return System.IO.File.ReadAllBytes(System.IO.Path.Combine(folder, name));
        return PlainPng(600, 600);
    }

    private static byte[] SampleFile(MessageAttachment file)
    {
        if (Array.IndexOf(Banners, file.Name) >= 0) return SampleBanner(file.Name);
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
