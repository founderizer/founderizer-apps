import FleetCore
import Foundation
import os

/// **A copy of the recovery code off this Mac** (DevOps plan V12, owner feature `recovery_copy`, UI-API 1.95; the
/// coordinator, 6 November 2026: the phone takes the code at its next enrollment from the existing Add device picture,
/// and nothing new shows on either screen).
///
/// The recovery code lives in this Mac's login keychain only (`RecoveryKeychain`). A newer phone sends a second key of
/// its own at enrollment, bound to the same one-time value of this Mac's QR as its signing key. When that binding
/// matches a QR that this Mac drew, this Mac seals the code to that key (`RecoverySeal`) and gives the hub the box. The
/// hub cannot open it; the phone opens it with its own chip, keeps the code on that phone alone, and says so, and the
/// hub then deletes the box. The code is in memory here only for the seal.
@MainActor
enum RecoveryCopy {
    static let feature = "recovery_copy"
    private static let log = Logger(subsystem: "com.founderizer.app", category: "recovery-copy")

    /// True once the hub has the box, or when there is nothing to send; false when it should be tried again.
    static func send(for device: OwnerDevice, bind: String, fleet: String, store: FleetStore, hub: URL,
                     database: String) async -> Bool {
        guard let key = device.recovery_key, let binding = device.recovery_binding,
              DeviceBinding.binding(bind: bind, key: key) == binding else {
            log.error("The recovery key of \(device.device, privacy: .public) does not match this Mac's QR: no copy.")
            return true
        }
        guard let code = RecoveryKeychain.code(fleet: fleet) else {
            log.notice("This Mac keeps no recovery code for this fleet: no copy.")
            return true
        }
        do {
            let sealed = try RecoverySeal.seal(Data(code.normalized.utf8), to: key, device: device.device)
            try await VaultClient().recoveryCopy(hub: hub, database: database, client: store.installation,
                                                 device: device.device, sealed: sealed)
            log.notice("The recovery code is sealed to \(device.device, privacy: .public).")
            return true
        } catch {
            log.error("The hub did not take the recovery code's copy: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
