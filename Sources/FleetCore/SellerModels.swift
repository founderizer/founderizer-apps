import Foundation

// **A seller's list of its models**, in a file of its own (the AI providers build, round 2, item 18): its one request
// goes to the seller's public list, with no key and never to the hub. `OwnerMacKeyTests` names this file for that
// request, so its scan for a hub call that goes past the Mac's key still reads `ModelAccounts.swift`.

/// **A seller's list of its models**, read with no key (round 2, item 18): OpenCode Go and OpenRouter as `{data: [{id}]}`,
/// Ollama as `{models: [{name}]}`.
public enum SellerModels {
    private struct DataList: Decodable { struct Entry: Decodable { let id: String }; let data: [Entry] }
    private struct OllamaList: Decodable { struct Entry: Decodable { let name: String }; let models: [Entry] }

    /// The names of the list, or nil for an answer that is no such list.
    public static func names(_ data: Data, provider: ModelProvider) -> Set<String>? {
        switch provider {
        case .ollamaCloud: (try? JSONDecoder().decode(OllamaList.self, from: data)).map { Set($0.models.map(\.name)) }
        case .openCodeGo, .openRouter: (try? JSONDecoder().decode(DataList.self, from: data)).map { Set($0.data.map(\.id)) }
        default: nil
        }
    }

    /// The seller's list, or nil when it does not answer: then the page lets the name go on, and the server's check
    /// says it later (the setup page's sentence 9).
    public static func read(_ provider: ModelProvider, session: URLSession = .shared) async -> Set<String>? {
        guard let url = provider.modelsList else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return names(data, provider: provider)
    }

    /// The pasted name as the seller writes it, without its part in the program.
    public static func sellerName(_ pasted: String, provider: ModelProvider) -> String {
        let name = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix = provider.prefix, name.hasPrefix(prefix + "/") { return String(name.dropFirst(prefix.count + 1)) }
        return name
    }
}
