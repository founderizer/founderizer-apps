import Foundation
import Testing
@testable import FleetCore

/// A single "~" means "about" in the words that agents write, and no mark: Apple's parser read two of them as the ends
/// of a struck-out part, so the words between them went out with a line through them and both tildes went (the owner,
/// 20 November 2026, of a card's Details: "why is the text like repeated and crossed out?!?"). Each case here is one
/// that Apple's parser reads in its own way, measured on macOS; the reader must follow it, or a tilde shows a
/// backslash, breaks a link, or still strikes words through.
struct MessageTildeTests {
    /// What the app draws of a text: its words, whether any of them are struck through, and its links.
    private func drawn(_ text: String) -> (words: String, struck: Bool, links: [String]) {
        let read = MessageBlock.inline(text)
        let struck = read.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true }
        let links = read.runs.compactMap { run in run.link.map { "\($0.absoluteString) \(String(read[run.range].characters))" } }
        return (String(read.characters), struck, links)
    }

    @Test("A single tilde is a word's, and two of them strike nothing through")
    func aSingleTildeIsNoMark() {
        let said = "(yearly plan, ~13,600 listings from eBay) asked on 15 Nov; the AI also alters products "
            + "(~$3,900 once, ~$180/month)"
        // the parse itself must not fail: inline's fallback is the raw text, which strikes nothing through either
        let parsed = try? AttributedString(markdown: MessageBlock.keepingTildes(said),
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        #expect(parsed != nil)
        #expect(drawn(said).words == said)
        #expect(!drawn(said).struck)
        #expect(MessageBlock.plain(said) == said)          // the iPhone's list of conversations
        #expect(ChatList.plain(said) == said)               // the Mac's list
    }

    @Test("A bare web address keeps its tildes and its link where the parser links it, and only there")
    func anAddressKeepsItsTilde() {
        let cases: [(text: String, links: [String])] = [
            ("See https://example.com/~user/repo now, about ~5 of them",
             ["https://example.com/~user/repo https://example.com/~user/repo"]),
            // "www." after "/" is no address, and a ":" with "~/" after it neither: both tildes are words
            ("copy ~/www.example.com to host:~/www.example.com", []),
            // a no-break space does not end an address; a "~" that the parser cuts from its end keeps no escape
            ("https://example.com/a\u{A0}~5 and ~6", ["https://example.com/a%C2%A0~5 https://example.com/a\u{A0}~5"]),
            ("x~www.example.com~ and ~y", ["http://www.example.com www.example.com"]),
            ("https://é.example/~a and ~b", ["https://xn--9ca.example/~a https://é.example/~a"]),
            ("https://é_x.example_y/~1~2 ok", ["https://xn--_x-9ia.example_y/~1~2 https://é_x.example_y/~1~2"]),
            ("https://a.b.c.d.e.f.g.h.i.j.k.my_host.com/~1~2 ok",           // past 10 dots, an "_" is no fault
             ["https://a.b.c.d.e.f.g.h.i.j.k.my_host.com/~1~2 https://a.b.c.d.e.f.g.h.i.j.k.my_host.com/~1~2"]),
            // a "~" that the parser cuts from an address's end is a mark: with one more, both are escaped
            ("~1 then https://example.com/b~ ok", ["https://example.com/b https://example.com/b"]),
            ("(~1 see https://example.com/b~)", ["https://example.com/b https://example.com/b"]),
            // no address inside the "[" of a link, after a "/", with an "_" in its domain's last parts, or for "ssh"
            ("[see https://example.com/~1~2] and ~3", []),
            ("a/www.example.com/~1~2 ok", []),
            ("www.my_site.com/~1~2 ok", []),
            ("ssh://git@host/~/a.git and ssh://git@host/~/b.git", []),
            // but inside Apple's "^[" there is one
            ("^[see https://example.com/~1~2] and ~3", ["https://example.com/~1~2%5D https://example.com/~1~2]"]),
        ]
        for (text, links) in cases {
            let read = drawn(text)
            #expect(read.words == text, "\(text)")
            #expect(!read.struck, "\(text)")
            #expect(read.links == links, "\(text)")
        }
    }

    @Test("A tilde in code, HTML, an autolink or a link's address and title stays as written")
    func theRawPartsKeepTheirTildes() {
        let comment = "<!-- " + String(repeating: "about ~5 min, ", count: 40) + "-->"
        let cases: [(text: String, words: String)] = [
            ("copy `~/a` to `~/b`", "copy ~/a to ~/b"),
            (comment + " and ~3 or ~4", comment + " and ~3 or ~4"),
            ("<!-- a -- ~b --> and ~c or ~d", "<!-- a -- ~b --> and ~c or ~d"),
            ("<!DOCTYPE ~b> and ~c or ~d", "<!DOCTYPE ~b> and ~c or ~d"),
            (#"<a href="https://example.com/~me">~5</a> and ~6"#, #"<a href="https://example.com/~me">~5</a> and ~6"#),
            ("<https://example.com/~user> and <user@host:~/a> and ~b or ~c",
             "https://example.com/~user and <user@host:~/a> and ~b or ~c"),
            // what the parser does not read as HTML: a comment that ends with "--->", a declaration in small letters,
            // and any "<!" after a comment that failed
            ("<!-- ~a --->x and c~", "<!-- ~a --->x and c~"),
            ("<!doctype ~b> and c~", "<!doctype ~b> and c~"),
            ("<a\u{A0}b=\"~1~2\"> ok", "<a\u{A0}b=\"~1~2\"> ok"),
            ("<!-- a ---> and <!DOCTYPE ~b> and c~", "<!-- a ---> and <!DOCTYPE ~b> and c~"),
            ("a < b ~1 and ~2", "a < b ~1 and ~2"),
            ("<? ~a ?> and b~ or ~c", "<? ~a ?> and b~ or ~c"),
            ("<x~y@example.com> and ~1 or ~2", "x~y@example.com and ~1 or ~2"),
            (#"<a b="~1"c="2~"> ok"#, #"<a b="~1"c="2~"> ok"#),             // no space between two attributes: no tag
            ("<a b c=d e = 'f~' g=h/> and ~1 or ~2", "<a b c=d e = 'f~' g=h/> and ~1 or ~2"),
            ("<![x ~a] and <![CDATA[ ~b ]]> and c~", "<![x ~a] and <![CDATA[ ~b ]]> and c~"),
            // a link's address and title end at its ")": what comes after is words again
            ("[a](https://example.com)~5 and [b](https://example.com/b)x~", "a~5 and bx~"),
            (#"[t](<https://example.com/~a> "ti~tle")~5 and x~"#, "t~5 and x~"),
            (#"[t](u "https://example.com/a")~1~2"#, "t~1~2"),
            (#"[Foo](https://example.com/wiki/Foo_(bar "see https://example.com")~2 and 3~"#, "Foo~2 and 3~"),
            ("^[a](https://example.com)~1~2 ok", "a~1~2 ok"),
            ("^[a](x: (1) https://example.com/b)~1~2 ok", "a~1~2 ok"),
            ("^[\u{301}a](x: `y) ~1 and 2~ `", "\u{301}a ~1 and 2~ `"),       // a mark on the "[" hides no "^["
            ("x~\u{301}y z~\u{301}", "x~\u{301}y z~\u{301}"),
            ("-<A1-x:e\u{0}@~/>é~ ok", "-A1-x:e\u{FFFD}@~/é~ ok"),      // the parser reads a NUL as U+FFFD
            ("<!-- a\u{0}\u{301}~1 --> c~ d~", "<!-- a\u{FFFD}\u{301}~1 --> c~ d~"),  // also one with a mark on it
        ]
        for (text, words) in cases {
            let read = drawn(text)
            #expect(read.words == words, "\(text)")
            #expect(!read.struck, "\(text)")
        }
        #expect(drawn(#"[t](<https://example.com/~a> "ti~tle")~5"#).links == ["https://example.com/~a t"])
        // a piece far longer than ICU's regular expressions can read (about 500,000 characters) is still one piece
        let huge = "<!-- " + String(repeating: "about ~5 min, ", count: 43_000) + "--> and ~1 or ~2"
        #expect(drawn(huge).words == huge)
        let tag = "<a" + String(repeating: #" b="~""#, count: 40_000) + "> and ~1 or ~2"
        #expect(drawn(tag).words == tag)
    }

    @Test("Two tildes still strike through, and one mark alone leaves the text as it is")
    func theMarksThatStay() {
        let read = drawn("keep ~~this~~ out")
        #expect(read.words == "keep this out")
        #expect(read.struck)
        #expect(MessageBlock.keepingTildes("~1 and ~~2~~ and ~~~3 or ~4") == "\\~1 and ~~2~~ and ~~~3 or \\~4")
        // the parser reads at most 100 tildes as one run: the 101st is a single mark
        for count in [101, 102, 201] {
            let long = String(repeating: "~", count: count)
            #expect(!drawn("x \(long)a b\(long) c").struck, "\(count)")
            #expect(drawn("x \(long)a b\(long) c").words == "x \(long)a b\(long) c", "\(count)")
        }
        let run = String(repeating: "~", count: 102)        // its last two pair with a "~~" elsewhere
        for text in ["x \(run)a b~~ c", "x ~~a b\(run) c"] {
            #expect(!drawn(text).struck && drawn(text).words == text, "\(text)")
        }
        #expect(MessageBlock.keepingTildes("`~/a ~/b` and <https://example.com/~user> and \\~x")
                == "`~/a ~/b` and <https://example.com/~user> and \\~x")
        // the parser strikes through only between two marks, and an escape changes how it reads "*" and "_" next to it
        #expect(MessageBlock.keepingTildes("about ~5 min") == "about ~5 min")
        #expect(MessageBlock.keepingTildes("no tilde") == "no tilde")
    }
}
