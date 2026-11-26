namespace Founderizer.Owner.Vault;

/// <summary>**The sentences of the secure form and of its steps that a view file of the Mac holds**
/// (<c>SecretEntryView.swift</c>, <c>GrantSigning.swift</c>, <c>AgentSetup.swift</c>), word for word, with "PC" for "Mac"
/// where it is the owner's computer (windows-app-plan-v2.md, rule 14). No writer of vectors reaches a view file, so a test
/// holds each one to the Mac's own catalog, <c>app/Localization/Localizable.xcstrings</c>, with <c>%@</c> for a slot
/// (5.6).</summary>
public static class VaultWords
{
    public const string NoStatus = "No current status of this hub. Nothing was sent.";
    public const string NoStatusAgain = "No current status of this hub. Try again when it answers.";
    public const string HubDidNotAnswer = "The hub did not answer.";
    public const string NoList = "This hub has no list of secrets. Nothing was sent.";
    public const string Gone = "This secret is no longer in the list.";
    public const string CannotSend = "This secret cannot be sent. Nothing was sent.";
    public const string CannotSeal = "Founderizer could not seal it for the vault. Nothing was sent.";
    public const string NotGiven = "Not given.";
    public const string NotTakenBack = "Not taken back.";
    public const string HadAnswer = "It had an answer already.";
    public const string KeyInNote = "The note looks like it holds a key. A note is never a key.";
    public const string KeyInWords = "That looks like a key. Never send a key in a message.";
    public const string CannotSay = "Founderizer could not send the message now. Try again.";
    public const string NoFleet = "The hub did not say which fleet this is, so Founderizer signed nothing.";
    public const string NoOwnerKey = "This PC holds no owner key for this fleet, so it cannot sign the change.";

    public static string Replaces(string name) => $"The list has “{name}” already. Save replaces its key: the same agents keep it.";
    public static string Twice(string name) => $"The list has “{name}” two times. Remove one first.";
    public static string NotYet(string name) => $"Founderizer Vault cannot replace “{name}” yet. Try again in a few minutes.";
    public static string Second(string name) => $"The list has “{name}” already. Save again to add a second one.";
    public static string Full(string most) => $"The list has {most} secrets and takes no more. Nothing was sent.";
    public static string NoAnswerForSave(string why) => $"The hub did not answer for this save. Nothing was sent. {why}";
    public static string NothingSent(string why) => $"{why} Nothing was sent.";
    public static string CannotChange(string why) => $"Founderizer could not change this. {why}";
    public static string NotRegistered(string why) => $"The hub did not register this secret. {why} Save again to try once more.";
    public static string NoServer(string agent) => $"The hub names no server for {agent}, so Founderizer signed nothing.";
    public static string UsesVault(string agent) => $"{agent} uses its server's vault now.";
    public static string NoVaultAccess(string agent, string reasons) => $"{agent} has it, but it has no vault access yet, so it cannot use it now. {reasons}";
    public static string ReadsFromNextStart(string agent, string title) => $"{agent} reads ${title} in its sessions from their next start.";
    public static string NotDeclined(string why) => $"The decline did not reach the hub. {why}";
    public static string NotClarified(string why) => $"Your message did not reach the hub. {why}";

    /// <summary>The codes of why an agent has no vault access, as facts (the Mac's <c>VaultAccessControl.reason</c>).</summary>
    public static string AccessReason(string code) => code switch
    {
        "agent_without_key" => "This agent has no agent key yet.",
        "helper_without_broker_callers" => "Founderizer on its server is not updated for a shared vault yet.",
        "no_vault_store" => "Its server has no vault store.",
        "broker_status_unknown" => "Founderizer has no recent vault status from its server.",
        "vault_store_mismatch" => "The server's vault key is not the key that Founderizer recorded for it.",
        "broker_without_callers" => "The server's vault cannot serve more than one agent yet.",
        _ => "Founderizer cannot give vault access now.",
    };
}
