import Foundation
import os

/// **The only place where the apps' defaults come from** (the tests of the Mac app's views, 21 November 2026, with the
/// yes of the areas App shell and look and Release, ship and tests): `UserDefaults.standard` in the apps, and a test's
/// own defaults (`TestDefaults`, a folder of its own) in a test of the app's views, which sets them once, before
/// anything reads them (`use`). No path of the app switches them while it runs: a second set, or a set after a read,
/// stops the process. Every read and write of the app's settings goes through `store`, an `@AppStorage` with
/// `store: AppDefaults.store` too; the start's own arguments (`UserDefaults.argumentDomain`) are read where they are.
/// FleetCore's functions that keep a value take it as their default (`in defaults: UserDefaults = AppDefaults.store`).
/// A rule test (`AppDefaultsRuleTests`) keeps any other read of the standard defaults out of the Mac app's sources and
/// FleetCore's.
public enum AppDefaults {
    private static let state = OSAllocatedUnfairLock<(chosen: UserDefaults?, read: Bool)>(uncheckedState: (nil, false))

    /// The app's defaults: the standard ones, or a test's (`use`).
    public static var store: UserDefaults {
        state.withLockUnchecked { state in
            state.read = true
            return state.chosen ?? .standard
        }
    }

    /// A test's defaults, set once before anything reads the app's: a second set, or a set after a read, is a
    /// programmer error, so that no code path can switch the app's defaults while it runs.
    public static func use(_ defaults: UserDefaults) {
        state.withLockUnchecked { state in
            precondition(state.chosen == nil && !state.read,
                         "AppDefaults.use: the app's defaults are chosen once, before anything reads them")
            state.chosen = defaults
        }
    }
}

/// **The folder that holds the apps' own files** (`Founderizer/` in it: the outbox, staged files, kept readings and
/// records): Application Support in the apps, and a test's own folder in a test of the Mac app's views, set once
/// before anything reads it (`use`). A set after a read is a programmer error, not a silent change: what a store read
/// stays where it read it. Every path of the apps under Application Support starts here (`AppDefaultsRuleTests`).
public enum AppFolders {
    private static let state = OSAllocatedUnfairLock<(chosen: URL?, read: Bool)>(uncheckedState: (nil, false))

    /// Application Support, or a test's folder (`use`).
    public static var support: URL {
        state.withLockUnchecked { state in
            state.read = true
            return state.chosen ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
    }

    /// A test's folder in place of Application Support, set once before anything reads it.
    public static func use(support folder: URL) {
        state.withLockUnchecked { state in
            precondition(state.chosen == nil && !state.read,
                         "AppFolders.use(support:): the folder is chosen once, before anything reads it")
            state.chosen = folder
        }
    }
}
