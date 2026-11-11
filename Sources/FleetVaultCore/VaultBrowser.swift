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

    static func fillScript(_ login: VaultLogin) throws -> String {
        // Recheck location inside the same script that fills: no check/use gap between tab navigation and fill.
        """
        (()=>{if(location.origin!==\(try jsonString(login.origin)))return 'wrong-origin';
        const p=document.querySelector('input[type=password]');if(!p||!p.form)return 'no-form';
        const f=p.form;if(new URL(f.action||location.href,location.href).origin!==location.origin)return 'wrong-action';
        const u=f.querySelector('input[type=email],input[type=text],input:not([type])');
        const set=(e,v)=>{Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,v);
        e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));};
        if(u)set(u,\(try jsonString(login.username)));set(p,\(try jsonString(login.password)));
        if(f.requestSubmit)f.requestSubmit();else f.submit();return 'filled';})()
        """
    }

    static let otpSelector = "input[autocomplete=one-time-code],input[name*=otp i],input[id*=otp i],input[name=code],input[id=code]"
    static func checkScript(_ origin: String) throws -> String {
        // A page that is still loading can get its form later. Without a field it is `loading`, never `none`:
        // `signIn` takes only `none` for signed in and only `otp` for a code page. Every other answer is a refusal.
        """
        (()=>{if(location.origin!==\(try jsonString(origin)))return 'wrong-origin';
        return document.querySelector('input[type=password]')?'form':
        document.querySelector(\(try jsonString(otpSelector)))?'otp':
        document.readyState==='loading'?'loading':'none';})()
        """
    }

    static func otpScript(_ origin: String, code: String) throws -> String {
        """
        (()=>{if(location.origin!==\(try jsonString(origin)))return 'wrong-origin';
        const e=document.querySelector(\(try jsonString(otpSelector)));if(!e||!e.form)return 'no-form';
        const f=e.form;if(new URL(f.action||location.href,location.href).origin!==location.origin)return 'wrong-action';
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,\(try jsonString(code)));
        e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
        if(f.requestSubmit)f.requestSubmit();else f.submit();return 'filled';})()
        """
    }

    /// Reads the one field that a selector names (`capture`). The script checks the origin and reads in the same
    /// step, in the top document only, and answers in JSON, so every character of the value arrives without change.
    /// The answer stays inside the vault.
    static func captureScript(origin: String, selector: String) throws -> String {
        """
        (()=>{if(location.origin!==\(try jsonString(origin)))return JSON.stringify({s:'wrong-origin'});
        let m;try{m=document.querySelectorAll(\(try jsonString(selector)));}catch(e){return JSON.stringify({s:'bad-selector'});}
        if(m.length!==1)return JSON.stringify({s:'count',n:m.length});const e=m[0];
        const v=(e instanceof HTMLInputElement||e instanceof HTMLTextAreaElement||e instanceof HTMLSelectElement)?e.value:e.textContent;
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
