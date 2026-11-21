import Foundation

/// **What this build of the Mac app draws, said to the hub on each read of the state** (owner API 1.285, header
/// `X-Fleet-Draws`): the hub raises an item with pictures only while each app of the owner's said that it draws them,
/// so an item never asks him to choose a picture that he cannot see. A build says only the names that it draws: a build
/// from before the owner's yes said none. The iPhone and the PC say their own, on their own reads. **Only the Mac app
/// reads the state through `HubClient.stateReading`** (its store, its first run, its link and restore pages, and its
/// install pages through `MachineInstaller`), which says it on each read with the owner's computer key: a
/// program that links FleetCore and draws no card must read the state another way, or the hub takes its word as the
/// computer's.
public enum AppDraws {
    public static let header = "X-Fleet-Draws"
    /// Pictures as the options of a Needs-you item (the owner's "Yes, as drawn" of 21 November 2026 to the drawings of
    /// Needs you and of a chat's card): `OwnerNeed.optionPictures(features:)`.
    public static let needPictures = "need_pictures"
    /// Exactly the names that this build draws.
    public static let names = [needPictures]
    /// The header's value: the names with commas between them.
    public static var value: String { names.joined(separator: ",") }
}

extension OwnerNeed {
    /// **The pictures that the card draws as its options**, one for each option in its order (owner feature
    /// `need_pictures`, API 1.285), or nil, and the card is the card of before: a hub that does not name the feature, an
    /// item with no pictures, a request for a key or a login, and an item whose pictures are not one for each option it
    /// draws, or not each a picture file, so no picture stands over another option's words. The iPhone's rule
    /// (`NeedPictures.drawn`) is the same, with its own line for the options that only a computer presses.
    public func optionPictures(features: [String]?) -> [MessageAttachment]? {
        guard features?.contains(AppDraws.needPictures) == true, !asksForSecret, let pictures, !pictures.isEmpty,
              pictures.count == (options ?? []).count, pictures.count == choices.count,
              pictures.allSatisfy({ $0.isImage && (try? $0.validate()) != nil }) else { return nil }
        return pictures
    }
}
