#if os(iOS)
import Foundation

enum KytosIOSFilesystem {
    static let appGroupID = "group.me.jwintz.Syntropment"
    private static let oldAppGroupID = "group.me.jwintz.Kytos"
    private static let migrationKey = "kytos_appGroupMigrated_v1"

    /// Sets up the home directory inside the shared app group container.
    /// Returns the path to `<container>/home/`.
    @discardableResult
    static func setupHomeDirectory() -> String {
        migrateAppGroupIfNeeded()

        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID)!
        let home = container.appendingPathComponent("home")

        let subdirs = ["Documents", "Library", "Library/bin", "tmp", ".config"]
        for dir in subdirs {
            try? FileManager.default.createDirectory(
                at: home.appendingPathComponent(dir),
                withIntermediateDirectories: true)
        }

        return home.path
    }

    /// One-time migration from old app group container to new one.
    private static func migrateAppGroupIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        guard let oldContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: oldAppGroupID),
              let newContainer = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID) else { return }

        let fm = FileManager.default
        let oldKytos = oldContainer.appendingPathComponent("Kytos")
        let newKytos = newContainer.appendingPathComponent("Kytos")

        guard fm.fileExists(atPath: oldKytos.path) else { return }

        try? fm.createDirectory(at: newKytos, withIntermediateDirectories: true)
        if let contents = try? fm.contentsOfDirectory(at: oldKytos, includingPropertiesForKeys: nil) {
            for item in contents {
                let dest = newKytos.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: item, to: dest)
                }
            }
        }
    }
}
#endif
