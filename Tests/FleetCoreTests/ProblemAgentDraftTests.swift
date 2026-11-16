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

    /// **The app's own words** (the manager band's Report a problem, 16 November 2026) go into a free box as an
    /// agent's text does, never make the report an agent's, and leave the box free for the next such text while they
    /// are unchanged. Words that the owner added or changed are never written over.
    @Test func theAppsOwnWordsAreNoAgentsAndKeepTheBoxFree() {
        let apps = "The manager session is not running, since 12:45."
        var draft = ProblemReport.AgentDraft()
        draft.took(apps, byAgent: false)
        draft.changed(to: apps)
        #expect(!draft.isAgents)
        #expect(draft.isFree(box: apps, sent: nil))
        #expect(!draft.isFree(box: apps + " It stopped after the update.", sent: nil))
        draft.took(agents)                                              // an agent's text in their place
        #expect(draft.isAgents && draft.isFree(box: agents, sent: nil) && !draft.isFree(box: apps, sent: nil))
        // The app's words never go over an agent's text, which says more; an agent's new text may.
        #expect(!draft.isFree(box: agents, sent: nil, byAgent: false))
        #expect(draft.isFree(box: "", sent: nil, byAgent: false))
        var sent = ProblemReport.AgentDraft()
        #expect(sent.isFree(box: "My sent report.", sent: "My sent report.", byAgent: false))
        sent.took(apps, byAgent: false)
        #expect(sent.isFree(box: apps, sent: nil, byAgent: false))      // its own words of before, unchanged
        draft.took(apps, byAgent: false)                                // a text in the box is no agent's after this
        draft.changed(to: apps)
        #expect(!draft.isAgents)
    }

    /// The fact for an agent's text is one short row.
    @Test func theFactIsOneShortRow() {
        #expect(ProblemReport.writtenByAgent == ProblemReport.Fact(name: "Written by", value: "Your AI agent"))
    }
}
