import Foundation
import Testing
@testable import FleetCore

/// An agent that words name by its whole role shows by its name with its role beside it (`RoleNames`), as a card draws
/// its words (`CardJoin.join`, which `CardBadgeText` draws): a badge in brackets.
struct RoleNamesTests {
    private static let team: [(name: String, role: String?)] = [
        ("wren", "Marketing"), ("nova", "Customer Support Lead"), ("manager", "Fleet Manager"), ("ana", "Designer"),
        ("bo", "Designer"), ("kai", "Sales"), ("ivy", "support")]
    private let book = CardNames(agents: Self.team)
    private let roles = AgentNames.roles(Self.team.map { ($0.name, $0.role) })

    private func pieces(_ text: AttributedString, oneLine: Bool = false) -> [CardNames.Piece] {
        CardJoin.join(book.pieces(text), roles: roles, oneLine: oneLine)
    }
    private func drawn(_ text: String, oneLine: Bool = false) -> [String] {
        pieces(AttributedString(text), oneLine: oneLine).map {
            $0.badge == nil ? String($0.words.characters) : "[\(String($0.words.characters))]"
        }
    }

    /// **A card names an agent by its name where an agent wrote its whole role, with the role muted beside it** (the
    /// owner, 23 November 2026: "We should ALWAYS use the name", and his answer "The name with the role in grey"): a role
    /// of several words anywhere, a role of one word right after a word, and "'s" stays after the badge. The badge
    /// keeps its agent, its link and its marks, and its role part is the one that a drawer draws muted. The bug that
    /// this catches: a card reads "Marketing" where the sidebar reads "Wren", the option "Give Marketing write" shows
    /// no name, "Marketing's plan" loses its "'s", "Fleet Manager" turns into "Manager", the new words are no link, or
    /// the role is no part of its own.
    @Test func aWholeRoleDrawsItsAgentsNameWithTheRoleBesideIt() {
        #expect(drawn("Add the key, so Marketing and Customer Support Lead can count visits.") ==
                ["Add the key, so ", "[Wren · Marketing]", " and ", "[Nova · Customer Support Lead]",
                 " can count visits."])
        #expect(drawn("I asked Marketing.") == ["I asked ", "[Wren · Marketing]", "."])
        // a verb that opens the step is no part of a name (`CardNames.opening`)
        #expect(drawn("Give Marketing write") == ["Give ", "[Wren · Marketing]", " write"])
        #expect(drawn("I read Wren's plan.") == ["I read ", "[Wren]", "'s plan."])
        for mark in ["'", "’"] {
            #expect(drawn("I read Marketing\(mark)s plan.") == ["I read ", "[Wren · Marketing]", "\(mark)s plan."],
                    "\(mark)")
        }
        // "de" is no article and "campaña" no title; a role of several words after an article is its agent
        #expect(drawn("Revisa la campaña de Marketing.") == ["Revisa la campaña de ", "[Wren · Marketing]", "."])
        #expect(drawn("Then ask the Customer Support Lead first.") ==
                ["Then ask the ", "[Nova · Customer Support Lead]", " first."])
        // the label of an agent whose role holds its name is the role, alone and beside the name
        #expect(drawn("Then ask Fleet Manager first.") == ["Then ask ", "[Fleet Manager]", " first."])
        #expect(drawn("Then ask Manager (Fleet Manager) first.") == ["Then ask ", "[Fleet Manager]", " first."])
        var bold = AttributedString("Marketing")
        bold.inlinePresentationIntent = .stronglyEmphasized
        let named = pieces(AttributedString("I asked ") + bold + AttributedString("."))
        #expect(named.map(\.badge) == [nil, .agent("wren"), nil])
        #expect(String(named[1].words.characters) == "Wren · Marketing")
        #expect(named[1].words.runs.allSatisfy {
            $0.link == CardNames.Target.agent("wren").url && $0.inlinePresentationIntent == .stronglyEmphasized
        })
        // the role is the marked part, and nothing else of the words is
        #expect(named[1].words.runs[RoleNames.RolePart.self].compactMap {
            $0.0 == true ? String(named[1].words[$0.1].characters) : nil
        } == [" · Marketing"])
        // the same words with no badge, for a drawer that draws a card's words plain: no link, and the role part kept
        let option = RoleNames.words(AttributedString("Give Customer Support Lead write"), names: book, roles: roles)
        #expect(String(option.characters) == "Give Nova · Customer Support Lead write")
        #expect(option.runs.allSatisfy { $0.link == nil })
        #expect(option.runs[RoleNames.RolePart.self].compactMap { $0.0 == true ? String(option[$0.1].characters) : nil }
                == [" · Customer Support Lead"])
    }

    /// **A card keeps the words of a run that can be no agent, or that says a role** (a wrong badge must never also
    /// change the words): a role of one word at a line's start or after a sentence's end, the start of a role, a role
    /// that two agents hold, and a role in one sentence with its agent's own name. The bug that this catches: "Marketing
    /// spend rose 10%" reads "Wren · Marketing spend rose 10%", a designer's role names one of the two designers, or
    /// "Nova is Customer Support Lead" reads "Nova is Nova · Customer Support Lead".
    @Test func aRunThatCanBeNoAgentAndARoleBesideItsNameKeepTheirWords() {
        #expect(drawn("Marketing spend rose 10%.") == ["[Marketing]", " spend rose 10%."])
        #expect(drawn("Done. Marketing spend rose.") == ["Done. ", "[Marketing]", " spend rose."])
        #expect(drawn("We asked\nMarketing spend rose.") == ["We asked\n", "[Marketing]", " spend rose."])
        // a join before it takes words away, and the bracket that stood before the role still counts
        #expect(drawn("Nova (Customer Support Lead) Marketing spend rose.") ==
                ["[Nova]", " ", "[Marketing]", " spend rose."])
        #expect(drawn("Then ask Customer Support first.") == ["Then ask ", "[Customer Support]", " first."])
        #expect(drawn("Then ask a Designer first.") == ["Then ask a Designer first."])
        #expect(drawn("Nova is Customer Support Lead now.") ==
                ["[Nova]", " is ", "[Customer Support Lead]", " now."])
        #expect(drawn("We ask Customer Support Lead, so app.example and Nova agree.") ==
                ["We ask ", "[Customer Support Lead]", ", so app.example and ", "[Nova]", " agree."])
        // the name in another sentence, or on another line, is no reason to keep the role
        #expect(drawn("Nova is back. Please ask Customer Support Lead.") ==
                ["[Nova]", " is back. Please ask ", "[Nova · Customer Support Lead]", "."])
        #expect(drawn("Nova is back\nPlease ask Customer Support Lead.") ==
                ["[Nova]", " is back\nPlease ask ", "[Nova · Customer Support Lead]", "."])
    }

    /// **A role keeps its words where they speak of a person's title, of the role itself, or of a common word** (the
    /// review of 23 November 2026): after "of" in a longer title, a role of one word after an article or a determiner
    /// (a common noun in English and Spanish), after the word "role" or "title", in quotation marks, with an apostrophe
    /// alone after it, and a role that starts with a small letter. The bug that this catches: "Head of Marketing at
    /// Acme" reads "Head of Wren · Marketing at Acme", "Increase the Marketing budget" reads "Increase the Wren ·
    /// Marketing budget", "the role Customer Support Lead" reads "the role Nova · …", "I need support" reads "I need Ivy
    /// · support", or "Sales' report" reads "Kai · Sales' report".
    @Test func aRoleThatSpeaksOfATitleOrOfTheRoleKeepsItsWords() {
        #expect(drawn("The customer is Head of Marketing at Acme.") ==
                ["The customer is Head of ", "[Marketing]", " at Acme."])
        #expect(drawn("I wrote to the VP of Sales.") == ["I wrote to the VP of ", "[Sales]", "."])
        #expect(drawn("Habla con el Jefe de Marketing.") == ["Habla con el Jefe de ", "[Marketing]", "."])
        // a title and "a" or "an" keep a role of several words too: another person of that role
        #expect(drawn("The customer is Head of Customer Support Lead at Acme.") ==
                ["The customer is Head of ", "[Customer Support Lead]", " at Acme."])
        #expect(drawn("We should hire a Customer Support Lead.") ==
                ["We should hire a ", "[Customer Support Lead]", "."])
        for (before, after) in [("Increase the ", " budget."), ("We cut our ", " spend."), ("Sube el ", " en junio."),
                                ("Revisa nuestra ", " de mayo."), ("Guarda sus ", " para mayo.")] {
            #expect(drawn("\(before)Marketing\(after)") == [before, "[Marketing]", after], "\(before)")
        }
        // the role of two words that is not a one-word noun, after an article, is its agent (`aWholeRole...`)
        #expect(drawn("Give Mia the role Customer Support Lead.") ==
                ["Give Mia the role ", "[Customer Support Lead]", "."])
        #expect(drawn("Dale el rol Marketing.") == ["Dale el rol ", "[Marketing]", "."])
        #expect(drawn("Set the title to \"Customer Support Lead\".") ==
                ["Set the title to \"", "[Customer Support Lead]", "\"."])
        #expect(drawn("Rename the role ‘Customer Support Lead’ now.") ==
                ["Rename the role ‘", "[Customer Support Lead]", "’ now."])
        #expect(drawn("“Customer Support Lead is busy,” she wrote.") ==
                ["“", "[Customer Support Lead]", " is busy,” she wrote."])
        #expect(drawn("I read Sales' report.") == ["I read ", "[Sales]", "' report."])
        #expect(drawn("I need support today.") == ["I need ", "[support]", " today."])
    }

    /// **Words that a place draws on one line keep the names of their lines** (`CardJoin.join`'s `oneLine`; the folded
    /// reason of a card): each line break is a space, and a role at a line's start keeps its words as on the open card.
    /// The bug that this catches: the folded card reads "We asked Wren · Marketing spend rose." where the open card
    /// reads "Marketing spend rose."
    @Test func wordsOnOneLineKeepTheNamesOfTheirLines() {
        #expect(drawn("We asked\nMarketing spend rose.\nI asked Marketing.", oneLine: true) ==
                ["We asked ", "[Marketing]", " spend rose. I asked ", "[Wren · Marketing]", "."])
    }
}
