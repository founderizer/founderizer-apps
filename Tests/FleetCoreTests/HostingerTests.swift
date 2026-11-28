import Foundation
import Testing
@testable import FleetCore

/// A server at Hostinger from this Mac, which bills by the month: a VPS that the account bought is set up and charges
/// nothing more, a new one is bought for one month with the account's default card and at most once per press, a step
/// after the purchase never deletes what was paid and keeps its id, and a remove ends the renewal. Every request is
/// proved against a stand-in for Hostinger's API, with made-up data only: no network, no account, no real token, and
/// nothing is bought anywhere.
struct HostingerTests {
    private static let token = "123|notarealtoken0123456789notarealtoken0123456789"
    /// A key made for this test with `ssh-keygen -t ed25519`, whose private half was thrown away.
    private static let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAo/DN+NoNbdAzU3DYGLTD7ne5vXT9bm+oEyoiacxwWg founderizer-test"
    private static let authKey = "tskey-auth-kAUTH1234CNTRL-notarealkey"
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!
    private static let api = "/api/vps/v1"
    private static let machines = """
        [{"id":71,"state":"initial","hostname":"srv71.hstgr.cloud","plan":"KVM 2","cpus":2,"memory":8192,"disk":102400,
          "data_center_id":null,"subscription_id":"S71"},
         {"id":72,"state":"initial","plan":"KVM old","cpus":1,"memory":1024,"disk":20480,"subscription_id":"S72"},
         {"id":73,"state":"running","hostname":"web-1","plan":"KVM 1","memory":4096,"data_center_id":29,"subscription_id":"S73",
          "template":{"id":3,"name":"Ubuntu 24.04 LTS"},"ipv4":[{"id":5,"address":"203.0.113.73"}]},
         {"id":74,"state":"running","hostname":"old-1","plan":"KVM 1","memory":4096,"data_center_id":29,"subscription_id":"S74",
          "template":{"id":3,"name":"Ubuntu 24.04 LTS"},"ipv4":[{"id":6,"address":"203.0.113.74"}]}]
        """
    private static let subscriptions = """
        [{"id":"S71","name":"KVM 2","status":"active","is_auto_renewed":true},
         {"id":"S72","name":"KVM old","status":"active","is_auto_renewed":true},
         {"id":"S73","name":"KVM 1","status":"active","is_auto_renewed":true},
         {"id":"S74","name":"KVM 1","status":"active","is_auto_renewed":false,"expires_at":"2026-12-20T00:00:00Z"},
         {"id":"S99","name":"Domain example.com","status":"active","is_auto_renewed":true},
         {"id":"S97","name":"VPS backups","status":"active","is_auto_renewed":true,"created_at":"2026-10-01T00:00:00Z"}]
        """

    private static func servers(_ stand: ProviderStandIn, shelf: MemoryShelf? = nil) -> CloudServers {
        CloudServers(provider: .hostinger, exchange: stand.exchange, shelf: shelf ?? MemoryShelf(Data(token.utf8)),
                     zone: berlin, pause: { _ in })
    }

    /// An account with two data centers; four VPS (one bought and not set up, one too small, one that runs, and one
    /// that runs with its renewal off) and their subscriptions, with a domain's and an add-on's of last month that no
    /// VPS holds; the catalog's KVM plans and one item
    /// that is no KVM plan; Ubuntu's templates; an expired card and the default one; and three post-install scripts: one
    /// of an earlier build of this app, more than an hour old, one of a build of a minute ago, and one of the owner's own.
    private static func account() -> ProviderStandIn {
        let stand = ProviderStandIn()
        stand.answer("GET", "\(api)/data-centers", 200, """
            [{"id":29,"name":"phx","location":"us","city":"Phoenix","continent":"North America"},
             {"id":17,"name":"nl","location":"nl","city":"Amsterdam","continent":"Europe"}]
            """)
        stand.answer("GET", "\(api)/virtual-machines", 200, machines)
        stand.answer("GET", "/api/billing/v1/subscriptions", 200, subscriptions)
        stand.answer("GET", "/api/billing/v1/catalog", 200, """
            [{"id":"hostingercom-vps-kvm8","name":"KVM 8","category":"VPS","prices":[
                {"id":"hostingercom-vps-kvm8-usd-1m","currency":"USD","price":5999,"first_period_price":2999,"period":1,"period_unit":"month"}]},
             {"id":"hostingercom-vps-kvm2","name":"KVM 2","category":"VPS","prices":[
                {"id":"hostingercom-vps-kvm2-usd-1y","currency":"USD","price":17988,"first_period_price":8388,"period":1,"period_unit":"year"},
                {"id":"hostingercom-vps-kvm2-usd-1m","currency":"USD","price":1799,"first_period_price":899,"period":1,"period_unit":"month"}]},
             {"id":"hostingercom-vps-game","name":"Game Panel","category":"VPS","prices":[
                {"id":"hostingercom-vps-game-usd-1m","currency":"USD","price":999,"period":1,"period_unit":"month"}]},
             {"id":"hostingercom-vps-kvm1","name":"KVM 1","category":"VPS","prices":[
                {"id":"hostingercom-vps-kvm1-usd-1m","currency":"USD","price":1299,"first_period_price":1299,"period":1,"period_unit":"month"}]}]
            """)
        stand.answer("GET", "\(api)/templates", 200, """
            [{"id":1,"name":"Ubuntu 24.04 with Docker"},{"id":2,"name":"Ubuntu 22.04 LTS"},{"id":3,"name":"Ubuntu 24.04 LTS"}]
            """)
        stand.answer("GET", "/api/billing/v1/payment-methods", 200, """
            [{"id":5,"is_default":false,"is_expired":true,"is_suspended":false},
             {"id":6,"is_default":true,"is_expired":false,"is_suspended":false}]
            """)
        let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        stand.answer("GET", "\(api)/post-install-scripts", 200, """
            [{"id":31,"name":"founderizer-worker-1-abc123","created_at":"2026-01-01T00:00:00Z"},
             {"id":32,"name":"founderizer-worker-2-def456","created_at":"\(now)"},
             {"id":33,"name":"my own script","created_at":"2026-01-01T00:00:00Z"}]
            """)
        stand.answer("DELETE", "\(api)/post-install-scripts/31", 200)
        stand.answer("POST", "\(api)/post-install-scripts", 201, #"{"id":44,"name":"script"}"#)
        stand.answer("DELETE", "\(api)/post-install-scripts/44", 200)
        return stand
    }

    private static func make(_ servers: CloudServers, _ name: String, _ offer: CloudOffer) async throws -> CloudServer {
        try await servers.createServer(name: name, use: .agent, publicKey: publicKey, authKey: authKey, offer: offer)
    }

    // MARK: - The token

    @Test func aHostingerTokenIsCheckedWithOneReadAndKept() async throws {
        let stand = ProviderStandIn()
        stand.answer("GET", "\(Self.api)/virtual-machines", 401, #"{"error":"Unauthenticated."}"#)
        stand.answer("GET", "\(Self.api)/virtual-machines", 200, "[]")
        let shelf = MemoryShelf()
        let servers = Self.servers(stand, shelf: shelf)
        await #expect(throws: CloudError.tokenNotAccepted(.hostinger)) { try await servers.connect(token: Self.token) }
        #expect(shelf.held == nil)
        try await servers.connect(token: " \(Self.token)\n")
        #expect(shelf.held == Data(Self.token.utf8))
        #expect(stand.call("GET", "\(Self.api)/virtual-machines")?.headers["Authorization"] == "Bearer \(Self.token)")
        // A Hostinger token has the rights of its user: no write is sent to find out what it may do.
        #expect(stand.calls.allSatisfy { $0.method == "GET" })
        await #expect(throws: CloudError.notAToken(.hostinger)) { try await servers.connect(token: "short|token") }
    }

    // MARK: - What the owner is shown

    @Test func aBoughtServerComesFirstThenEachMonthlyPlanCheapestFirstNearTheMac() async throws {
        let offers = try await Self.servers(Self.account()).offers(use: .agent)
        // The VPS of 1 GB is too small; the item that is no KVM plan, and the yearly price, are no offers.
        #expect(offers.map(\.type) == ["vm-71", "hostingercom-vps-kvm1-usd-1m", "hostingercom-vps-kvm2-usd-1m",
                                       "hostingercom-vps-kvm8-usd-1m"])
        let bought = offers[0]
        #expect(bought.paid && bought.monthlyPrice == 0 && bought.plan == "KVM 2" && bought.memoryGB == 8)
        #expect(bought.label == "srv71" && bought.boughtRow == "KVM 2 · 8 GB · Bought, not set up · Paid")
        // Berlin's nearest data center, by Hostinger's own list, for the bought VPS too.
        #expect(offers.allSatisfy { $0.location == "17" && $0.place == "Amsterdam, Netherlands" })
        let second = offers[2]
        #expect(!second.paid && second.monthlyPrice == Decimal(string: "17.99") && second.firstPrice == Decimal(string: "8.99"))
        #expect(second.currency == "USD" && second.cores == 2 && second.memoryGB == 8 && second.diskGB == 100)
        // A plan whose first month costs what each month costs has no first price of its own.
        #expect(offers[1].firstPrice == nil && offers[1].monthlyPrice == Decimal(string: "12.99"))
    }

    // MARK: - Making the server

    @Test func aBoughtServerIsSetUpAndNothingIsCharged() async throws {
        let stand = Self.account()
        let servers = Self.servers(stand)
        let offer = try #require(try await servers.offers(use: .agent).first)
        stand.answer("POST", "\(Self.api)/virtual-machines/71/setup", 200, #"{"id":71,"state":"creating"}"#)
        stand.answer("GET", "\(Self.api)/virtual-machines/71", 200, #"{"id":71,"state":"creating","ipv4":null}"#)
        stand.answer("GET", "\(Self.api)/virtual-machines/71", 200,
                     #"{"id":71,"state":"running","ipv4":[{"id":9,"address":"203.0.113.71"}]}"#)
        let server = try await Self.make(servers, "worker-2", offer)
        #expect(server.id == "71" && server.ipv4 == "203.0.113.71" && server.monthlyPrice == 0)
        let setup = try #require(stand.call("POST", "\(Self.api)/virtual-machines/71/setup")?.object)
        // The plain Ubuntu 24.04, not the one with Docker; the nearest data center; this app's key; the first boot.
        #expect(setup["template_id"] as? Int == 3 && setup["data_center_id"] as? Int == 17)
        #expect(setup["post_install_script_id"] as? Int == 44 && setup["hostname"] as? String == "worker-2")
        #expect(setup["ssh_keys"] as? [String] == [Self.publicKey])
        let script = try #require(stand.call("POST", "\(Self.api)/post-install-scripts")?.object)
        #expect((script["content"] as? String)?.contains("--auth-key=\(Self.authKey) --hostname=worker-2") == true)
        // Nothing is bought.
        #expect(stand.calls("POST", "\(Self.api)/virtual-machines").isEmpty)
        #expect(stand.calls("GET", "/api/billing/v1/payment-methods").isEmpty)
        // This build's script stays for Hostinger, which may run it after the wait; an earlier build's script of more
        // than an hour goes, and no other script.
        #expect(stand.calls.filter { $0.method == "DELETE" }.map(\.path) == ["\(Self.api)/post-install-scripts/31"])
    }

    /// A setup whose answer says nothing (Hostinger's own fault, or no answer) may have been taken: the VPS is read by its
    /// id, and one that left `initial` with this build's name is waited for, never set up twice. Else the end is not
    /// known, so the build's name stays taken, and the script stays, since Hostinger can still take the setup.
    @Test func aSetupWhoseAnswerSaysNothingReadsTheServerByItsId() async throws {
        let stand = Self.account()
        let servers = Self.servers(stand)
        let offer = try #require(try await servers.offers(use: .agent).first)
        stand.answer("POST", "\(Self.api)/virtual-machines/71/setup", 502, "<html><body>Bad Gateway</body></html>")
        stand.answer("GET", "\(Self.api)/virtual-machines/71", 200, #"{"id":71,"state":"installing","hostname":"worker-8"}"#)
        stand.answer("GET", "\(Self.api)/virtual-machines/71", 200,
                     #"{"id":71,"state":"running","hostname":"worker-8","ipv4":[{"id":9,"address":"203.0.113.71"}]}"#)
        let server = try await Self.make(servers, "worker-8", offer)
        #expect(server.id == "71" && server.ipv4 == "203.0.113.71")
        #expect(stand.calls("POST", "\(Self.api)/virtual-machines/71/setup").count == 1)

        // Still `initial` after a read that failed: not known, in Hostinger's own fault words, and nothing deleted.
        let fault = Self.account()
        let offerAgain = try #require(try await Self.servers(fault).offers(use: .agent).first)
        fault.answer("POST", "\(Self.api)/virtual-machines/71/setup", 502, "<html><body>Bad Gateway</body></html>")
        fault.answer("GET", "\(Self.api)/virtual-machines/71", 503, "")
        fault.answer("GET", "\(Self.api)/virtual-machines/71", 200, #"{"id":71,"state":"initial","hostname":"srv71.hstgr.cloud"}"#)
        let unsure = try #require(await #expect(throws: CloudError.unsure(.hostinger, says: "it answered 502 and said nothing",
                                                                          server: "worker-9", mark: "71")) {
            try await Self.make(Self.servers(fault), "worker-9", offerAgain)
        })
        #expect(BuildRecord.AtProvider.after(unsure) == .notKnown)
        #expect(fault.calls("POST", "\(Self.api)/virtual-machines/71/setup").count == 1)
        #expect(fault.calls("GET", "\(Self.api)/virtual-machines/71").count == CloudServers.findReads)
        #expect(fault.calls("DELETE", "\(Self.api)/post-install-scripts/44").isEmpty)

        // No answer, and the VPS runs under another name (a setup in hPanel at the same time): not this build's.
        let lost = Self.account()
        let offerThird = try #require(try await Self.servers(lost).offers(use: .agent).first)
        lost.answer("POST", "\(Self.api)/virtual-machines/71/setup", ProviderStandIn.dropped)
        lost.answer("GET", "\(Self.api)/virtual-machines/71", 200, #"{"id":71,"state":"running","hostname":"web-2"}"#)
        await #expect(throws: CloudError.unsure(.hostinger, says: nil, server: "worker-9", mark: "71")) {
            try await Self.make(Self.servers(lost), "worker-9", offerThird)
        }
        #expect(lost.calls("DELETE", "\(Self.api)/post-install-scripts/44").isEmpty)

        // A refusal in Hostinger's own words was not taken: its script goes at once.
        let refused = Self.account()
        let offerFourth = try #require(try await Self.servers(refused).offers(use: .agent).first)
        refused.answer("POST", "\(Self.api)/virtual-machines/71/setup", 422, #"{"message":"Hostname is taken"}"#)
        await #expect(throws: CloudError.self) { try await Self.make(Self.servers(refused), "worker-9", offerFourth) }
        #expect(refused.calls("GET", "\(Self.api)/virtual-machines/71").isEmpty)
        #expect(refused.calls("DELETE", "\(Self.api)/post-install-scripts/44").count == 1)
    }

    @Test func aNewServerIsBoughtForOneMonthWithTheDefaultCard() async throws {
        let stand = Self.account()
        let servers = Self.servers(stand)
        let offer = try #require(try await servers.offers(use: .agent).first { $0.type == "hostingercom-vps-kvm2-usd-1m" })
        stand.answer("POST", "\(Self.api)/virtual-machines", 200, #"{"order":{"id":1},"virtual_machine":{"id":88,"state":"creating"}}"#)
        stand.answer("GET", "\(Self.api)/virtual-machines/88", 200,
                     #"{"id":88,"state":"running","ipv4":[{"id":9,"address":"203.0.113.88"}]}"#)
        let server = try await Self.make(servers, "worker-3", offer)
        #expect(server.id == "88" && server.ipv4 == "203.0.113.88")
        let bought = try #require(stand.call("POST", "\(Self.api)/virtual-machines")?.object)
        #expect(bought["item_id"] as? String == "hostingercom-vps-kvm2-usd-1m" && bought["payment_method_id"] as? Int == 6)
        #expect((bought["setup"] as? [String: Any])?["template_id"] as? Int == 3)
        #expect(stand.calls("POST", "\(Self.api)/virtual-machines").count == 1)
    }

    @Test func aServerThatFailsAfterItsPurchaseStaysPaidAndItsRecordKeepsItsId() async throws {
        let stand = Self.account()
        let servers = Self.servers(stand)
        let offer = try #require(try await servers.offers(use: .agent).first { !$0.paid })
        stand.answer("POST", "\(Self.api)/virtual-machines", 200, #"{"virtual_machine":{"id":89,"state":"creating"}}"#)
        stand.answer("GET", "\(Self.api)/virtual-machines/89", 200, #"{"id":89,"state":"error"}"#)
        let error = try #require(await #expect(throws: CloudError.paidNotReady(.hostinger, "worker-4", "89")) {
            try await Self.make(servers, "worker-4", offer)
        })
        // The build's record keeps a server at the provider by its id, and the store never cuts that record.
        var record = BuildRecord(provider: .hostinger, use: .agent, hub: "https://hub.example:8765", name: "worker-4")
        record.callEnded(with: error)
        #expect(record.atProvider == .server && record.serverID == "89" && record.keepsAlways)
        #expect(stand.calls("POST", "\(Self.api)/virtual-machines").count == 1)
        // The script stays: a server that comes up later can still run it within the key's hour.
        #expect(stand.calls("DELETE", "\(Self.api)/post-install-scripts/44").isEmpty)
    }

    @Test func aPurchaseWhoseAnswerSaysNothingIsFoundAndNeverBoughtTwice() async throws {
        let stand = Self.account()
        let servers = Self.servers(stand)
        let offer = try #require(try await servers.offers(use: .agent).first { !$0.paid })
        // Hostinger's own fault after it took the purchase: the account's list then holds the new server.
        stand.answer("POST", "\(Self.api)/virtual-machines", 500, #"{"error":"Server Error"}"#)
        let more = Self.machines.dropLast() + #", {"id":90,"state":"creating","hostname":"worker-6","subscription_id":"S90"}]"#
        // The list is read for the offers, then once before the purchase, and the new server shows only after it.
        stand.clear("GET", "\(Self.api)/virtual-machines")
        stand.answer("GET", "\(Self.api)/virtual-machines", 200, Self.machines)
        stand.answer("GET", "\(Self.api)/virtual-machines", 200, Self.machines)
        stand.answer("GET", "\(Self.api)/virtual-machines", 200, String(more))
        stand.answer("GET", "\(Self.api)/virtual-machines/90", 200,
                     #"{"id":90,"state":"running","ipv4":[{"id":9,"address":"203.0.113.90"}]}"#)
        let server = try await Self.make(servers, "worker-6", offer)
        #expect(server.id == "90" && stand.calls("POST", "\(Self.api)/virtual-machines").count == 1)

        // No answer at all, and no new server comes: the payment counts as pending, which keeps the name, and the
        // press bought once.
        let lost = Self.account()
        let offerAgain = try #require(try await Self.servers(lost).offers(use: .agent).first { !$0.paid })
        lost.answer("POST", "\(Self.api)/virtual-machines", ProviderStandIn.dropped)
        let pending = try #require(await #expect(throws: CloudError.paymentPending(.hostinger)) {
            try await Self.make(Self.servers(lost), "worker-7", offerAgain)
        })
        #expect(BuildRecord.AtProvider.after(pending) == .notKnown)
        #expect(lost.calls("POST", "\(Self.api)/virtual-machines").count == 1)
        // Hostinger can still make it with this build's script: the script stays for the sweep.
        #expect(lost.calls("DELETE", "\(Self.api)/post-install-scripts/44").isEmpty)
    }

    @Test func aPaymentThatWaitsAWaitingPurchaseOrNoDefaultCardStopsWithOneTryAtMost() async throws {
        let stand = Self.account()
        let servers = Self.servers(stand)
        let offer = try #require(try await servers.offers(use: .agent).first { !$0.paid })
        stand.answer("POST", "\(Self.api)/virtual-machines", 202, #"{"order":{"id":2}}"#)
        await #expect(throws: CloudError.paymentPending(.hostinger)) { try await Self.make(servers, "worker-5", offer) }
        #expect(stand.calls("POST", "\(Self.api)/virtual-machines").count == 1)
        // Hostinger sets the VPS up with this build's script once the payment comes: the script stays for the sweep.
        #expect(stand.calls("DELETE", "\(Self.api)/post-install-scripts/44").isEmpty)

        // That purchase's subscription of a minute ago has no server yet: the next press buys nothing. The account's
        // add-on of last month, which no server holds either, stops no purchase (`aNewServerIsBought...`).
        let minute = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        stand.clear("GET", "/api/billing/v1/subscriptions")
        stand.answer("GET", "/api/billing/v1/subscriptions", 200,
                     Self.subscriptions.dropLast() + #", {"id":"S98","name":"KVM 1","status":"active","created_at":"\#(minute)"}]"#)
        await #expect(throws: CloudError.paymentPending(.hostinger)) { try await Self.make(servers, "worker-5", offer) }
        #expect(stand.calls("POST", "\(Self.api)/virtual-machines").count == 1)
        // That press's own script never reached a purchase: it goes at once.
        #expect(stand.calls("DELETE", "\(Self.api)/post-install-scripts/44").count == 1)

        // A default card that has expired is charged by no other card.
        stand.clear("GET", "/api/billing/v1/subscriptions")
        stand.answer("GET", "/api/billing/v1/subscriptions", 200, Self.subscriptions)
        stand.clear("GET", "/api/billing/v1/payment-methods")
        stand.answer("GET", "/api/billing/v1/payment-methods", 200,
                     #"[{"id":5,"is_default":true,"is_expired":true},{"id":6,"is_default":false,"is_expired":false}]"#)
        await #expect(throws: CloudError.noPaymentMethod(.hostinger)) { try await Self.make(servers, "worker-5", offer) }
        #expect(stand.calls("POST", "\(Self.api)/virtual-machines").count == 1)
    }

    // MARK: - The account's servers, and a remove

    @Test func theServersOfAHostingerAccountAreListedWithoutTheOnesNotSetUpOrEnding() async throws {
        let listed = try await Self.servers(Self.account()).servers()
        #expect(listed == [CloudExisting(id: "73", name: "web-1", ipv4: "203.0.113.73", type: "KVM 1", memoryMB: 4096,
                                         system: "ubuntu", version: "24.04", place: "Phoenix", running: true,
                                         project: nil, madeFor: nil)])
    }

    @Test func aRemoveEndsTheRenewalOnceAndDeletesNothing() async throws {
        let stand = Self.account()
        stand.answer("GET", "\(Self.api)/virtual-machines/73", 200, #"{"id":73,"subscription_id":"S73","state":"running"}"#)
        stand.answer("DELETE", "/api/billing/v1/subscriptions/S73/auto-renewal/disable", 200, #"{"is_auto_renewed":false}"#)
        let servers = Self.servers(stand)
        let taken = Taken()
        #expect(try await servers.deleteServer(id: "73", accepted: { taken.mark() }) == .deleted)
        #expect(taken.isSet && stand.calls("DELETE", "/api/billing/v1/subscriptions/S73/auto-renewal/disable").count == 1)
        #expect(stand.calls.allSatisfy { $0.method == "GET" || $0.path.hasSuffix("/auto-renewal/disable") })
        // A renewal that is off already (an earlier remove that the hub refused) is not asked again.
        stand.answer("GET", "\(Self.api)/virtual-machines/74", 200, #"{"id":74,"subscription_id":"S74","state":"running"}"#)
        #expect(try await servers.deleteServer(id: "74") == .deleted)
        #expect(stand.calls("DELETE", "/api/billing/v1/subscriptions/S74/auto-renewal/disable").isEmpty)
        // Start again names what it did at Hostinger as the renewal that ends, never as a deletion.
        #expect(StartAgain.Words.deletedAt(.hostinger) == "Renewal off at Hostinger")
        stand.answer("GET", "\(Self.api)/virtual-machines/75", 404, #"{"error":"Not found"}"#)
        guard case .notThere = try await servers.deleteServer(id: "75") else { Issue.record("a 404 is no removal"); return }
    }

    // MARK: - The owner's screens: words of a plan, the guide, and a remove

    @Test func aMonthlyPlanSaysItsFirstMonthAndHowItsChargeStops() {
        var plan = CloudOffer(provider: .hostinger, type: "hostingercom-vps-kvm2-usd-1m", location: "17", cores: 2,
                              memoryGB: 8, diskGB: 100, monthlyPrice: Decimal(string: "17.99")!, currency: "USD")
        plan.plan = "KVM 2"; plan.firstPrice = Decimal(string: "8.99"); plan.city = "Amsterdam, Netherlands"
        #expect(plan.row.hasPrefix("KVM 2 · 8 GB · Amsterdam · "))
        // Amounts in this Mac's own way of writing them ("$8.99", "8,99 US$").
        let first = CloudOffer.money(Decimal(string: "8.99")!, "USD"), each = CloudOffer.money(Decimal(string: "17.99")!, "USD")
        #expect(plan.priceWords == "\(first) first month, then \(each)")
        // What the card is charged now is the first month's price, and the renewal's after it.
        let line = try! #require(plan.chargeLine)
        #expect(line.hasPrefix("Hostinger charges the card on your account \(first) now and \(each) each month after that."))
        var bought = plan
        bought.paid = true
        #expect(bought.chargeLine == nil && bought.priceWords == "Paid" && bought.boughtRow == "8 GB · Bought, not set up · Paid")
        // A provider that bills by the hour has no charge line: its server goes with a delete.
        let hourly = CloudOffer(provider: .hetzner, type: "cx23", location: "fsn1", cores: 2, memoryGB: 4, diskGB: 40,
                                monthlyPrice: Decimal(string: "5.49")!, currency: "EUR")
        #expect(hourly.chargeLine == nil && hourly.priceWords == hourly.monthly)
    }

    @Test func eachKeyPageLinksALiveGuideInTheAppsLanguageAndAddServerShowsHostinger() {
        #expect(CloudProvider.hetzner.guide(language: "en")?.absoluteString == "https://founderizer.com/guides/hetzner")
        #expect(CloudProvider.digitalOcean.guide(language: "es-ES")?.absoluteString == "https://founderizer.com/es/guides/digitalocean")
        #expect(CloudProvider.shown.allSatisfy { $0.guide(language: nil) != nil })
        // Hostinger's guide is not on the site yet: its key page shows no link to a page that is missing.
        #expect(CloudProvider.hostinger.guide(language: "en") == nil)
        // The first run waits for its own step; Add server shows the card that the owner said yes to.
        #expect(!CloudProvider.shown.contains(.hostinger) && CloudProvider.addServer.last == .hostinger)
    }

    @Test func aRemoveAsksWithTheDateUntilWhichHostingerKeepsTheServerPaid() async throws {
        let stand = ProviderStandIn()
        stand.answer("GET", "\(Self.api)/virtual-machines/73", 200, #"{"id":73,"subscription_id":"Az19-x_7"}"#)
        stand.answer("GET", "/api/billing/v1/subscriptions", 200, """
            [{"id":"Other","next_billing_at":"2027-01-01T00:00:00Z"},
             {"id":"Az19-x_7","is_auto_renewed":true,"expires_at":null,"next_billing_at":"2026-12-25T10:00:00Z"}]
            """)
        let until = try #require(try await Self.servers(stand).paidUntil(id: "73"))
        #expect(until == ISO8601DateFormatter().date(from: "2026-12-25T10:00:00Z"))
        #expect(stand.calls.allSatisfy { $0.method == "GET" })
        // A server of a provider that bills by the hour has no such date.
        #expect(try await CloudServers(provider: .hetzner, exchange: stand.exchange, shelf: MemoryShelf(Data("x".utf8)),
                                       pause: { _ in }).paidUntil(id: "73") == nil)
    }

    @Test func aRemoveEndsTheRenewalOfTheNewestServerThatThisMacBoughtMonthlyForThisHub() {
        let hub = URL(string: "https://hub.example:8765")!
        let earlier = Date(timeIntervalSince1970: 1_790_000_000), later = earlier.addingTimeInterval(3600)
        var older = BuildRecord(provider: .hostinger, use: .agent, hub: hub.absoluteString, name: "worker-3", at: earlier)
        older.made(id: "101")
        var newer = BuildRecord(provider: .hostinger, use: .agent, hub: hub.absoluteString, name: "worker-3", at: later)
        newer.made(id: "102")
        var hourly = BuildRecord(provider: .hetzner, use: .agent, hub: hub.absoluteString, name: "worker-4")
        hourly.made(id: "99")
        let unanswered = BuildRecord(provider: .hostinger, use: .agent, hub: hub.absoluteString, name: "worker-5")
        var other = BuildRecord(provider: .hostinger, use: .agent, hub: "https://other.example:8765", name: "worker-6")
        other.made(id: "77")
        // A name that a Hetzner server took after a purchase of the same name: the newest is Hetzner's.
        var reused = BuildRecord(provider: .hetzner, use: .agent, hub: hub.absoluteString, name: "worker-8", at: later)
        reused.made(id: "8")
        var bought = BuildRecord(provider: .hostinger, use: .agent, hub: hub.absoluteString, name: "worker-8", at: earlier)
        bought.made(id: "108")
        var refused = BuildRecord(provider: .hostinger, use: .agent, hub: hub.absoluteString, name: "worker-9")
        refused.callEnded(with: CloudError.noPaymentMethod(.hostinger))
        // Newest first, as the store gives them: a name that came back is the newest server's, at any provider.
        let records = [newer, reused, hourly, unanswered, other, refused, older, bought]
        #expect(BoughtServers.record(named: "Worker-3", hub: hub, in: records)?.serverID == "102")
        #expect(BoughtServers.record(named: "worker-4", hub: hub, in: records) == nil)
        #expect(BoughtServers.record(named: "worker-6", hub: hub, in: records) == nil)
        #expect(BoughtServers.record(named: "worker-8", hub: hub, in: records) == nil)
        #expect(BoughtServers.unanswered(named: "worker-8", hub: hub, in: records) == nil)
        // A purchase with no id is looked up by its name; one that the provider refused bought nothing.
        #expect(BoughtServers.record(named: "worker-5", hub: hub, in: records) == nil)
        #expect(BoughtServers.unanswered(named: "worker-5", hub: hub, in: records)?.name == "worker-5")
        #expect(BoughtServers.unanswered(named: "worker-9", hub: hub, in: records) == nil)
    }

    @Test func theStoreNeverCutsTheRecordOfAServerBoughtMonthly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hostinger-kept-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = KeptRecords<BuildRecord>(folder: folder, launch: "test", keeps: 1)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var bought = BuildRecord(provider: .hostinger, use: .agent, hub: "https://hub.example:8765", name: "worker-3",
                                 launch: "test", at: start)
        bought.made(id: "88")
        bought.joined()
        store.write(bought)
        for minute in 1...3 {
            var later = BuildRecord(provider: .hetzner, use: .agent, hub: "https://hub.example:8765", name: "worker-\(9 + minute)",
                                    launch: "test", at: start.addingTimeInterval(Double(minute) * 60))
            later.made(id: "\(minute)")
            later.joined()
            store.write(later)
        }
        #expect(store.all().map(\.name) == ["worker-12", "worker-3"])
    }
}

/// Whether the provider took a removal, as the caller's `accepted` hears it.
private final class Taken: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func mark() { lock.withLock { set = true } }
    var isSet: Bool { lock.withLock { set } }
}
