import Testing
@testable import FleetCore

/// The box of the report form when the owner's own agent wrote into it (`ProblemReport.AgentDraft`).
@Suite struct ProblemAgentDraftTests {
    private let agents = "The install stopped at the step Check the server."

    /// An agent's text goes into an empty box, over its own text of before, and over the unchanged text of a report
    /// that was sent. Nothing else is free.
    @Test func anAgentsTextGoesOnlyIntoAFreeBox() {
        var draft = ProblemReport.AgentDraft()
        #expect(draft.isFree(box: "", sent: nil) && draft.isFree(box: " \n", sent: nil))
        #expect(!draft.isFree(box: "My own words.", sent: nil))
        draft.took(agents)
        #expect(draft.isFree(box: agents, sent: nil))                       // the agent's text of before, unchanged
        #expect(!draft.isFree(box: agents + " And more of mine.", sent: nil))
        #expect(!draft.isFree(box: "My own words.", sent: nil))
        // A report that was sent: its unchanged text may go, a new text of the owner in the same window may not.
        var other = ProblemReport.AgentDraft()
        #expect(other.isFree(box: "My sent report.", sent: "My sent report."))
        #expect(!other.isFree(box: "A new report that I began.", sent: "My sent report."))
        other.took(agents)
        #expect(other.isAgents)
    }

    /// The report is an agent's while the box still holds the agent's text whole: the owner may write before it and
    /// after it. A change inside it, a new text in its place and an empty box make the report the owner's own.
    @Test func theReportIsAnAgentsWhileItsTextIsWhole() {
        var draft = ProblemReport.AgentDraft()
        #expect(!draft.isAgents)
        draft.took(agents)
        draft.changed(to: agents)
        #expect(draft.isAgents)
        draft.changed(to: "A word of mine first. " + agents + " And one after.")
        #expect(draft.isAgents)
        var edited = draft
        edited.changed(to: agents.replacingOccurrences(of: "stopped", with: "ended"))
        #expect(!edited.isAgents)
        var replaced = draft
        replaced.changed(to: "x")                                            // select all, then one key
        #expect(!replaced.isAgents)
        var emptied = draft
        emptied.changed(to: "")
        #expect(!emptied.isAgents)
        // Once the report is the owner's own, the agent's words typed again by hand do not make it an agent's.
        emptied.changed(to: agents)
        #expect(!emptied.isAgents)
        // A box that changed with no agent's text in play changes nothing.
        var none = ProblemReport.AgentDraft()
        none.changed(to: "My own words.")
        #expect(!none.isAgents)
    }

    /// The fact for an agent's text is one short row.
    @Test func theFactIsOneShortRow() {
        #expect(ProblemReport.writtenByAgent == ProblemReport.Fact(name: "Written by", value: "Your AI agent"))
    }
}
