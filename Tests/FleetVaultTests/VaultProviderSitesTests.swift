import Foundation
import Testing
@testable import FleetVaultCore

/// The model providers' own sites. The fleet's `test_hub_install.test_the_three_programs_agree_on_what_a_provider_site_is`
/// pins the same list, and these same hosts, for its hub, its Linux vault and its helper.
struct VaultProviderSitesTests {
    @Test func theListIsTheFleetsOwn() {
        #expect(VaultProviderSites.sites == ["claude.ai", "claude.com", "chatgpt.com", "auth.openai.com", "x.ai"])
        #expect(VaultProviderSites.keySites == ["platform.claude.com"])
    }

    @Test func aProviderSiteAndItsSubdomainsAreRefusedAndAnAPIKeySiteIsNot() {
        for host in ["claude.ai", "CLAUDE.AI", "claude.ai.", "app.claude.ai", "claude.com", "www.claude.com",
                     "chatgpt.com", "auth.chatgpt.com", "auth.openai.com", "AUTH.OPENAI.COM.", "x.ai", "api.x.ai"] {
            #expect(VaultProviderSites.contains(host: host), "\(host) is allowed")
        }
        for host in ["console.anthropic.com", "platform.claude.com", "PLATFORM.CLAUDE.COM.", "platform.openai.com",
                     "api.openai.com", "openai.com", "notclaude.ai", "notclaude.com", "claude.ai.example.com",
                     "auth.openai.com.example.com", "example.com", "", nil] as [String?] {
            #expect(!VaultProviderSites.contains(host: host), "\(host ?? "nil") is refused")
        }
        #expect(VaultProviderSites.contains(address: "https://Auth.OpenAI.com/log-in"))
        #expect(VaultProviderSites.contains(address: "https://claude.com/cai/oauth/authorize"))
        #expect(!VaultProviderSites.contains(address: "https://platform.openai.com/api-keys"))
        #expect(!VaultProviderSites.contains(address: "https://platform.claude.com/settings/keys"))
        #expect(!VaultProviderSites.contains(address: nil))
    }

    @Test func noLoginOnAProviderSiteLeavesTheVaultWhoeverSavedIt() throws {
        for url in ["https://claude.ai/login", "https://chatgpt.com/auth", "https://auth.openai.com/log-in", "https://x.ai/sign-in"] {
            let login = try VaultLogin(data: Data(#"{"username":"u","password":"p","url":"\#(url)"}"#.utf8), label: "owner")
            #expect(throws: VaultFailure.modelProvider) { try VaultProviderSites.checked(login) }
        }
        let key = try VaultLogin(data: Data(#"{"username":"","password":"sk-test","url":"https://platform.openai.com/api-keys"}"#.utf8), label: "key")
        #expect(try VaultProviderSites.checked(key).url == key.url)
    }
}
