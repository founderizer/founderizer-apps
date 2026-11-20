import AppKit
import CryptoKit
import Foundation
import os

/// The browser's own signed-in session can access its page and cookies. This boundary protects
/// the vault's keys and handover identities; it does not turn a shared browser into an isolated OS user.
public enum VaultBrowser {
    /// AppleScript runs on the main thread, and AppKit gives the main thread only when this app's launch ends. The
    /// worker's socket opens before that launch (`FleetVaultMain`), because macOS can hold it for hours: after a macOS
    /// update on 4 November 2026, Setup Assistant held a Mac Studio's session for more than five hours, and the agents
    /// got no answer. Until the launch ends, browser work is refused at once: it keeps no later job of the queue
    /// waiting, and it fills no page hours after its request.
    public static func launchEnded() { launch.withLock { $0 = true } }
    private static let launch = OSAllocatedUnfairLock(initialState: false)

    /// The only way of the browser's work to the main thread: refused at once before the launch ended.
    static func onMainThread<T: Sendable>(_ work: @MainActor @Sendable () throws -> T) async throws -> T {
        guard launch.withLock({ $0 }) else { throw VaultFailure.browser }
        return try await MainActor.run(body: work)
    }

    static func jsonString(_ text: String) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), encoding: .utf8)!
    }

    /// The start of each script, inside its function: the only way of the scripts to the page. A page's markup can
    /// shadow a member of a form or of the document by a name, with no script, so a strict CSP does not stop it:
    /// `<input name="action">` makes `form.action` that field, and the check of the action then passed and the submit
    /// sent the user name and the password to the form's real action on another site; `<input name="requestSubmit">`
    /// stopped the fill after the password was typed; `<img name="querySelector">` broke `document.querySelector`. A
    /// member of a prototype is out of the markup's reach. `read` is a member that a prototype's getter gives, `$` one
    /// element of the document or of a form, `$$` all of them in the document, `form` the form of a field (none for an
    /// element that is no HTML field, such as an `input` inside `<svg>`), `own` the first of a form's own fields that a
    /// selector finds (its `elements`: also a field outside it that `form=` gives to it, and not one inside it that
    /// `form=` gives to another form), `away` whether the form's own action (its getter gives the resolved address)
    /// leaves the page's origin, `post` a GET form made a POST form (true when it was a GET form), `closes` whether a
    /// dialog submit of a form closes a dialog (the nearest HTML dialog around it is open), `valid` whether each field
    /// of a form that the browser checks is valid, `send` the form's submit and the wipe of its secret's field after
    /// it (false when nothing went: a field of a form that checks its fields was not valid, no submit event came, the
    /// submit threw, or the vault held it), `set` a field's value with the events that a page's framework listens to
    /// (and no submit event of any form while those run), `secret` the same for a password or a code, and `wipe` its
    /// field's value away again.
    ///
    /// `secret` types only into a field that keeps its value out of the markup and its CSS (`fits`: text, tel,
    /// password, number; a hidden field or a checkbox keeps it in its `value` attribute, where a selector reads it
    /// whole), and answers false for any other. Before it types, the field loses each attribute that judges a value
    /// that a script types (`pattern`, `min`, `max`, `step`; `dir` for `:dir()`), and gets inline important styles that
    /// keep its size and its glyphs out of the value: with one of these, the page's CSS learnt a bit of the secret at
    /// each fill (`:invalid`, `:out-of-range`, a font for each character, `field-sizing:content` with a container
    /// query), by a request to another site. A shadow root's `::slotted` rule with `!important` beats an inline
    /// important style, also in a closed shadow root, and it can wait for a state of the field. So `secret` makes the
    /// field `readonly` first, which has no validity (`:valid`, `:user-valid`, which the submit itself sets, and their
    /// opposites never match it), and then reads its computed style with a throwaway value in it (set with no event,
    /// and taken out again), so that the states that a value gives (`:not(:placeholder-shown)`) are in the look too. It
    /// answers false when the field's size or its glyphs are not the ones that it set, or when a transition or an
    /// animation is left on it (a delayed transition shows the old size in the look); an empty computed value is a
    /// property that the browser does not know. `wipe` takes `readonly` away again once the field is empty, and so does
    /// a refusal.
    ///
    /// A GET form puts its fields into the address, where the tab's history keeps them and the next page sends them in
    /// its Referer. Many login forms have no method and a handler of the page that sends them with `fetch`, and some
    /// handlers send a GET form into the address themselves (Next.js's `Form`, Turbo) or stop the submit and send the
    /// form later with `submit()`, which fires no event; a code page's own script sends the form when a field's input
    /// or change event says that the code is complete, and the vault's typing fires those, also by a click on the
    /// form's first submit button, whose `formaction` and `formmethod` (of the markup) win over the form's own. So
    /// `set` cancels each submit event while its own input and change events run, and the fill and the code make a
    /// GET form a POST form (`post`) before they type into it, for each send of it after that too: `post` also makes a
    /// GET `formmethod` of the form's buttons POST and takes away a `formaction` that leaves the origin, so that no
    /// later click (of a page's handler, or of the agent) sends the form elsewhere. It reads every `button` and `input`
    /// of the document whose form is that form: the form's `elements` leave out an image button. `send`
    /// submits it with a hidden submit button of its own (`formmethod=post`, which Next.js's `Form` leaves to the
    /// browser and Turbo sends by POST), and holds that submit when no handler of the page took it: its listener on
    /// the window comes after the page's own. A second one, of the capture phase, sees whether a
    /// submit event came at all. A submit that throws (a page's script broke `requestSubmit`) sent nothing either. Both
    /// listeners go when the submit ends, and so does the button. A form that checks its fields (no `novalidate`) and
    /// that has a field that is not valid sends no submit event, and `send` does not submit it at all: there
    /// `requestSubmit` focuses that field and lays the page out while the secret is in its field, and a shadow root's
    /// rule on `:host(:focus-within)` (a required checkbox that the shadow root slots too) gave a slotted code field
    /// the page's fonts for its digits. `valid` gives the same answer with no event: it reads each field's
    /// `willValidate` and `validity.valid` through the getters, as `checkValidity` fires `invalid` at each field that
    /// is not valid, and a listener of the page's own that focuses that field gave the same focus. It does not see the
    /// validity of a form-associated custom element, which keeps it in its own `ElementInternals`, or of an image
    /// button, which the form's `elements` leave out: only a page's script makes either one not valid.
    ///
    /// A page that went away keeps its fields in the tab's history: Back gives the login page again from the
    /// back/forward cache with the secret in its field, and a code page also from the form state of a reload, where one
    /// click on a button of the markup (`formmethod=get`, or a cover over the whole page) sends it into the address. So
    /// `send` wipes the secret's field at once when nothing went or when the browser itself sent the form (its body is
    /// built by then), and when the page goes when a handler of the page took the submit, or for a dialog form, whose
    /// page reads the fields when it closes: a `pagehide` listener of one use, the only one of the vault that stays. A
    /// dialog form closes the nearest HTML dialog around it, also past a MathML or SVG element named `dialog`, when
    /// that dialog is open (`closes`, read before the submit, which closes it); with none around it, or with one that
    /// is not open, it sends nothing and closes nothing: nothing went.
    ///
    /// AppleScript's `execute javascript` runs a script in the page's own world, where the page's own scripts can still
    /// replace a prototype: this keeps out markup, not the page's scripts. The scripts trust the login's origin, not
    /// the form: markup can give the first password field to another form of the page (`form=`, or a form of its own
    /// before the login form), and that form's own handler can still put its fields anywhere on the origin, also into
    /// the address when it reads neither the method nor the submitter. (A secret's field inside its own form, by
    /// `closest('form')`, would refuse the `form=` case, and also the legacy pages whose form does not hold its fields,
    /// such as a `<form>` around rows of a `<table>`.) A page's own listener of the capture phase on the window that
    /// stops the submit event before the vault's sees it gives `not-sent` although the page sent the form itself, and a
    /// handler that sends the form again later with `requestSubmit(event.submitter)` finds the vault's button gone and
    /// sends nothing: both are refusals, not leaks. A single-page app that changes its route with `pushState` fires no
    /// `pagehide`: when it keeps the login view out of the document while it hides it (a kept-alive view), the check
    /// does not find the field, and Back can show the view again with the secret in it. A page's own script that calls
    /// `submit()` while the vault types (it fires no event), or that sends the form later (a timer after the vault's
    /// events), sends what its fields hold then: by POST to its form's own action, or, through a button that a page's
    /// script added after the fill, where that button says. For a field that a shadow root slots, while the secret
    /// stays in the page (a handler of the page took the submit, or a dialog form), a `::slotted` rule whose condition
    /// comes true after the look still beats the inline styles, also when no script of the page changes anything: a
    /// container query that matches only after an animation, a transition or a late image resizes its container,
    /// `:target` (a meta refresh to the field's id), or `:hover` of the pointer; and so does a state that the page's
    /// own script changes: the focus, a class, or `readonly` taken away again (a framework's `readOnly` prop), which
    /// gives back `:valid` and `:user-valid`. It can then give the password's length, or a code's digits. Only a wipe
    /// at once, also when a handler of the page took the submit, would close this, and it would break the pages that
    /// read the field later.
    static let dom = "const D=Document.prototype,E=Element.prototype,F=HTMLFormElement.prototype," +
        "I=HTMLInputElement.prototype,N=Node.prototype,T=EventTarget.prototype,V=Event.prototype;" +
        "const read=(P,n,o)=>Object.getOwnPropertyDescriptor(P,n).get.call(o)," +
        "$=(n,s)=>(n===document?D:E).querySelector.call(n,s),$$=s=>D.querySelectorAll.call(document,s)," +
        "form=e=>e instanceof HTMLInputElement?read(I,'form',e):null," +
        "own=(f,s)=>{const c=read(F,'elements',f);" +
        "for(let i=0;i<c.length;i++)if(E.matches.call(c[i],s))return c[i];" +
        "return null}," +
        "away=f=>{try{return new URL(read(F,'action',f)).origin!==location.origin}catch(x){return true}}," +
        "post=f=>{const g=read(F,'method',f)==='get';if(g)E.setAttribute.call(f,'method','post');const c=$$('button,input');" +
        "for(let i=0;i<c.length;i++){const b=c[i],P=b instanceof HTMLButtonElement?HTMLButtonElement.prototype:" +
        "b instanceof HTMLInputElement?I:null;if(!P||read(P,'form',b)!==f)continue;" +
        "if(E.hasAttribute.call(b,'formmethod')&&read(P,'formMethod',b)==='get')E.setAttribute.call(b,'formmethod','post');" +
        "if(E.hasAttribute.call(b,'formaction')){let o=null;try{o=new URL(read(P,'formAction',b)).origin}catch(x){}" +
        "if(o!==location.origin)E.removeAttribute.call(b,'formaction')}}return g}," +
        "closes=f=>{for(let a=read(N,'parentElement',f);a;a=read(N,'parentElement',a))" +
        "if(a instanceof HTMLDialogElement)return read(HTMLDialogElement.prototype,'open',a);return false}," +
        "valid=f=>{const c=read(F,'elements',f);for(let i=0;i<c.length;i++){const x=c[i]," +
        "P=x instanceof HTMLInputElement?I:x instanceof HTMLSelectElement?HTMLSelectElement.prototype:" +
        "x instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype:x instanceof HTMLButtonElement?HTMLButtonElement.prototype:null;" +
        "if(P&&read(P,'willValidate',x)&&!read(ValidityState.prototype,'valid',read(P,'validity',x)))return false}return true}," +
        "send=(f,e,get)=>{if(!read(F,'noValidate',f)&&!valid(f)){wipe(e);return false}" +
        "const open=closes(f);let b=null,ev=null,held=false;" +
        "if(get){b=D.createElement.call(document,'button');" +
        "E.setAttribute.call(b,'type','submit');E.setAttribute.call(b,'formmethod','post');E.setAttribute.call(b,'hidden','');" +
        "N.appendChild.call(f,b)}" +
        "const c=x=>{if(read(V,'target',x)===f)ev=x}," +
        "h=x=>{if(read(V,'target',x)===f&&!read(V,'defaultPrevented',x)&&get){V.preventDefault.call(x);held=true}};" +
        "T.addEventListener.call(window,'submit',c,true);T.addEventListener.call(window,'submit',h);" +
        "try{F.requestSubmit.call(f,b)}catch(x){ev=null}finally{T.removeEventListener.call(window,'submit',c,true);" +
        "T.removeEventListener.call(window,'submit',h);if(b)E.remove.call(b)}" +
        "const took=!!ev&&read(V,'defaultPrevented',ev),dialog=read(F,'method',f)==='dialog'," +
        "went=!!ev&&!held&&(took||!dialog||open),page=went&&(took||dialog);" +
        "if(page)T.addEventListener.call(window,'pagehide',()=>wipe(e),{once:true});else wipe(e);return went}," +
        "set=(e,v)=>{Object.getOwnPropertyDescriptor(I,'value').set.call(e,v);" +
        "const q=x=>{V.preventDefault.call(x);V.stopImmediatePropagation.call(x)};T.addEventListener.call(window,'submit',q,true);" +
        "try{T.dispatchEvent.call(e,new Event('input',{bubbles:true}));T.dispatchEvent.call(e,new Event('change',{bubbles:true}))}" +
        "finally{T.removeEventListener.call(window,'submit',q,true)}}," +
        "fits=e=>e instanceof HTMLInputElement&&['text','tel','password','number'].includes(read(I,'type',e))," +
        "secret=(e,v)=>{if(!fits(e))return false;['pattern','min','max','step','dir'].forEach(n=>E.removeAttribute.call(e,n));" +
        "E.setAttribute.call(e,'readonly','');" +
        "const s=read(HTMLElement.prototype,'style',e),C=CSSStyleDeclaration.prototype,u=Object.getOwnPropertyDescriptor(I,'value').set," +
        "w=[['field-sizing','fixed'],['-webkit-text-security','disc'],['transition','none'],['animation','none']];" +
        "w.forEach(([n,x])=>C.setProperty.call(s,n,x,'important'));u.call(e,'1');const k=getComputedStyle(e)," +
        "beaten=[['field-sizing','fixed'],['-webkit-text-security','disc'],['transition-property','none'],['animation-name','none']]" +
        ".some(([n,x])=>{const y=C.getPropertyValue.call(k,n);return y!==''&&y!==x});u.call(e,'');" +
        "if(beaten){E.removeAttribute.call(e,'readonly');return false}set(e,v);return true}," +
        "wipe=e=>{if(fits(e)){set(e,'');E.removeAttribute.call(e,'readonly')}};"

    static func fillScript(_ login: VaultLogin) throws -> String {
        // Recheck location inside the same script that fills: no check/use gap between tab navigation and fill. The
        // user name goes into the first user field of the form itself (`own`), and the password with `secret`. The
        // origin and the action are read again just before the submit, because the page's own listeners of the input
        // events run in between; a form that moved sends nothing and gets its password field emptied. `send` wipes the
        // password field after the submit too (`not-sent`: no submit event came, the submit threw, or the vault held it).
        let origin = try jsonString(login.origin)
        return """
        (()=>{\(dom)if(location.origin!==\(origin))return 'wrong-origin';
        const p=$(document,'input[type=password]');const f=p&&form(p);if(!f)return 'no-form';
        if(away(f))return 'wrong-action';const g=post(f),u=own(f,'input[type=email],input[type=text],input:not([type])');
        if(u)set(u,\(try jsonString(login.username)));if(!secret(p,\(try jsonString(login.password))))return 'bad-field';
        if(away(f)||location.origin!==\(origin)){wipe(p);return 'moved';}return send(f,p,g)?'filled':'not-sent';})()
        """
    }

    static let otpSelector = "input[autocomplete=one-time-code],input[name*=otp i],input[id*=otp i],input[name=code],input[id=code]"
    static func checkScript(_ origin: String) throws -> String {
        // A page that is still loading can get its form later. Without a field it is `loading`, never `none`:
        // `signIn` takes only `none` for signed in and only `otp` for a code page. Every other answer is a refusal.
        // A password or a code that is still in the page after its submit (a page that did not go: an answer of 204, a
        // form into a hidden frame) is wiped, so that no later click sends it: a button of the markup can send its form
        // by GET, or to another site.
        """
        (()=>{\(dom)if(location.origin!==\(try jsonString(origin)))return 'wrong-origin';
        const p=$(document,'input[type=password]'),k=$(document,\(try jsonString(otpSelector)));wipe(p);wipe(k);
        return p?'form':k?'otp':read(D,'readyState',document)==='loading'?'loading':'none';})()
        """
    }

    static func otpScript(_ origin: String, code: String) throws -> String {
        // The same checks as the fill, also again just before the submit.
        let origin = try jsonString(origin)
        return """
        (()=>{\(dom)if(location.origin!==\(origin))return 'wrong-origin';
        const e=$(document,\(try jsonString(otpSelector)));const f=e&&form(e);if(!f)return 'no-form';
        if(away(f))return 'wrong-action';const g=post(f);if(!secret(e,\(try jsonString(code))))return 'bad-field';
        if(away(f)||location.origin!==\(origin)){wipe(e);return 'moved';}return send(f,e,g)?'filled':'not-sent';})()
        """
    }

    /// Reads the one field that a selector names (`capture`). The script checks the origin and reads in the same
    /// step, in the top document only, and answers in JSON, so every character of the value arrives without change.
    /// The answer stays inside the vault. A list of elements has no member that markup can shadow.
    static func captureScript(origin: String, selector: String) throws -> String {
        """
        (()=>{\(dom)if(location.origin!==\(try jsonString(origin)))return JSON.stringify({s:'wrong-origin'});
        let m;try{m=$$(\(try jsonString(selector)));}catch(x){return JSON.stringify({s:'bad-selector'});}
        if(m.length!==1)return JSON.stringify({s:'count',n:m.length});const e=m[0];
        const v=e instanceof HTMLInputElement?read(I,'value',e):e instanceof HTMLTextAreaElement?
        read(HTMLTextAreaElement.prototype,'value',e):e instanceof HTMLSelectElement?
        read(HTMLSelectElement.prototype,'value',e):read(Node.prototype,'textContent',e);
        return JSON.stringify({s:'ok',v:String(v==null?'':v)});})()
        """
    }

    /// The value of a capture script's answer, exactly as the page has it. An empty text: the tab does not show the
    /// page any more. Short values and values with white space are values.
    static func captured(_ answer: String) throws -> String {
        guard !answer.isEmpty else { throw VaultFailure.captureTab }
        guard answer.utf8.count <= 262_144, let object = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any],
              let state = object["s"] as? String else { throw VaultFailure.browser }
        switch state {
        case "ok":
            guard let value = object["v"] as? String else { throw VaultFailure.browser }
            guard !value.isEmpty else { throw VaultFailure.captureEmpty }
            return value
        case "wrong-origin": throw VaultFailure.captureTab
        case "count", "bad-selector": throw VaultFailure.captureField
        default: throw VaultFailure.browser
        }
    }

    /// Chrome's tabs: for each one its id and its address. It runs nothing in a page. The id stays a number: as text,
    /// AppleScript writes a number of 2^29 or more in an exponent form, and a tab id is frequently that large.
    static let tabsSource = """
        tell application id "com.google.Chrome"
            set found to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set end of found to {(id of t) as integer, (URL of t) as text}
                end repeat
            end repeat
            return found
        end tell
        """

    /// The tabs of an answer to `tabsSource`. An item that is no pair of an id and an address is passed over.
    static func tabs(in answer: NSAppleEventDescriptor) -> [(id: Int, address: String)] {
        guard answer.numberOfItems > 0 else { return [] }
        return (1...answer.numberOfItems).compactMap { index in
            guard let pair = answer.atIndex(index), pair.numberOfItems == 2, let id = pair.atIndex(1)?.int32Value, id > 0,
                  let address = pair.atIndex(2)?.stringValue else { return nil }
            return (Int(id), address)
        }
    }

    /// The id of the one tab whose address is exactly the page's, in any window and in front or not. No such tab and
    /// more than one are refusals: the vault does not choose.
    static func chosenTab(for page: String, in tabs: [(id: Int, address: String)]) throws -> Int {
        let found = tabs.filter { $0.address == page }
        guard let one = found.first else { throw VaultFailure.captureTab }
        guard found.count == 1 else { throw VaultFailure.captureTabs }
        return one.id
    }

    /// Runs the capture script in the tab with this id, only while that tab still has this exact address.
    static func captureSource(tab id: Int, address: String, origin: String, selector: String) throws -> String {
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return """
        tell application id "com.google.Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if (id of t as integer) is \(id) then
                        considering case
                            if (URL of t) is \(quote(address)) then return (execute t javascript \(quote(try captureScript(origin: origin, selector: selector))))
                        end considering
                        return ""
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """
    }

    /// Reads the field in the one Chrome tab that shows `page`, the address that the hub confirmed. The tab need not be
    /// in front: an agent that works through a browser extension cannot bring it there.
    static func capture(page: String, selector: String) async throws -> String {
        try await onMainThread { try captureOnMainThread(page: page, selector: selector) }
    }

    @MainActor private static func captureOnMainThread(page: String, selector: String) throws -> String {
        guard let url = URL(string: page), URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.isEmpty == false else {
            throw VaultFailure.hub
        }
        let id = try chosenTab(for: page, in: tabs(in: run(tabsSource)))
        return try captured(run(captureSource(tab: id, address: page, origin: VaultLogin.origin(of: url), selector: selector)).stringValue ?? "")
    }

    /// Whether Chrome runs one harmless script for this app. No page is read, and the page in front does not matter.
    static func scriptable() async -> Bool {
        (try? await onMainThread { scriptableOnMainThread() }) ?? false
    }

    @MainActor private static func scriptableOnMainThread() -> Bool {
        (try? run("tell application id \"com.google.Chrome\" to execute active tab of front window javascript \"1\"")) != nil
    }

    /// AppleScript inside the hardened process: no `osascript` child and no command line.
    @MainActor private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: source) else { throw VaultFailure.browser }
        let result = apple.executeAndReturnError(&error)
        // AppleScript errors can include the source. Never log or return the error dictionary.
        guard error == nil else { throw VaultFailure.browser }
        return result
    }

    static func tab(origin: String, script: String, expect: String, id: Int = 0) async throws -> Int {
        try await onMainThread { try tabOnMainThread(origin: origin, script: script, expect: expect, id: id) }
    }

    @MainActor private static func tabOnMainThread(origin: String, script: String, expect: String, id: Int) throws -> Int {
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // NSAppleScript stays inside the hardened process. No secret-bearing osascript child or command line.
        let source = """
        tell application id "com.google.Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if \(id) is 0 or (id of t as integer) is \(id) then
                        if (URL of t) starts with \(quote(origin + "/")) then
                            if (execute t javascript \(quote(script))) is \(quote(expect)) then return id of t
                        end if
                    end if
                end repeat
            end repeat
            return 0
        end tell
        """
        var error: NSDictionary?
        guard let apple = NSAppleScript(source: source) else { throw VaultFailure.browser }
        let result = apple.executeAndReturnError(&error)
        // AppleScript errors can include the source. Never log or return the error dictionary.
        guard error == nil else { throw VaultFailure.browser }
        return Int(result.stringValue ?? "") ?? Int(result.int32Value)
    }

    static func signIn(_ login: VaultLogin) async throws -> Bool {
        let id = try await tab(origin: login.origin, script: fillScript(login), expect: "filled")
        guard id > 0 else { throw VaultFailure.browser }
        try await Task.sleep(for: .seconds(3))
        let check = try checkScript(login.origin)
        if try await tab(origin: login.origin, script: check, expect: "none", id: id) == id { return false }
        guard let seed = login.totp,
              try await tab(origin: login.origin, script: check, expect: "otp", id: id) == id else { throw VaultFailure.browser }
        let script = try otpScript(login.origin, code: totp(seed: seed, at: Date().timeIntervalSince1970))
        guard try await tab(origin: login.origin, script: script, expect: "filled", id: id) == id else { throw VaultFailure.browser }
        try await Task.sleep(for: .seconds(3))
        guard try await tab(origin: login.origin, script: check, expect: "none", id: id) == id else { throw VaultFailure.browser }
        return true
    }

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        // Python's whitespace set also includes the four ASCII separators.
        scalar.properties.isWhitespace || (0x1c...0x1f).contains(scalar.value)
    }

    static func canonicalSeed(_ raw: String) -> String {
        let seed: String
        if raw.hasPrefix("otpauth://") {
            let parts = URLComponents(string: raw.replacingOccurrences(of: "+", with: " "))
            seed = parts?.queryItems?.first(where: { $0.name == "secret" })?.value ?? ""
        } else { seed = raw }
        return String(String.UnicodeScalarView(seed.uppercased().unicodeScalars.filter {
            !isWhitespace($0) && $0 != "-" && $0 != "="
        }))
    }

    static func totp(seed raw: String, at time: TimeInterval) throws -> String {
        var seed = raw, digits = 6, period = 30, algorithm = "SHA1"
        if raw.hasPrefix("otpauth://") {
            guard let parts = URLComponents(string: raw.replacingOccurrences(of: "+", with: " ")), parts.host == "totp" else { throw VaultFailure.login }
            let items = parts.queryItems ?? []
            guard Set(items.map(\.name)).count == items.count else { throw VaultFailure.login }
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            seed = values["secret"] ?? ""; algorithm = (values["algorithm"] ?? "SHA1").uppercased()
            guard let d = Int(values["digits"] ?? "6"), let p = Int(values["period"] ?? "30") else { throw VaultFailure.login }
            digits = d; period = p
        }
        guard (6...8).contains(digits), (1...300).contains(period), time >= 0, time.isFinite else { throw VaultFailure.login }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let clean = canonicalSeed(seed)
        var bits: UInt64 = 0, count = 0, key = Data()
        for character in clean {
            guard let value = alphabet.firstIndex(of: character) else { throw VaultFailure.login }
            bits = ((bits << 5) | UInt64(value)) & 0xffff; count += 5
            if count >= 8 { count -= 8; key.append(UInt8((bits >> count) & 255)) }
        }
        guard !key.isEmpty, bits & ((1 << count) - 1) == 0 else { throw VaultFailure.login }
        var counter = UInt64(time / Double(period)).bigEndian
        let data = withUnsafeBytes(of: &counter) { Data($0) }
        let symmetric = SymmetricKey(data: key)
        let mac: [UInt8]
        switch algorithm {
        case "SHA1": mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetric))
        case "SHA256": mac = Array(HMAC<SHA256>.authenticationCode(for: data, using: symmetric))
        case "SHA512": mac = Array(HMAC<SHA512>.authenticationCode(for: data, using: symmetric))
        default: throw VaultFailure.login
        }
        let offset = Int(mac.last! & 15)
        let value = mac[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fffffff
        return String(format: "%0*u", digits, value % UInt32(pow(10.0, Double(digits))))
    }
}
