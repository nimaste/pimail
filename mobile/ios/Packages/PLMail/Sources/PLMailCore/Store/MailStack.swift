import Foundation
import OSLog
import SwiftData

/// Owns the SwiftData container.
///
/// The recovery strategy is the interesting part. Because everything in the
/// store is reconstructible from the server (see `SchemaV1`), a store that
/// cannot be opened is not a problem to be solved — it is a cache to be thrown
/// away. So there is no custom migration stage here, and there never should be:
/// on any failure, delete the file and re-sync behind a "catching up" state.
///
/// That trade is only sound while the rule holds. The moment something
/// irreplaceable is written here, this becomes data loss.
public enum MailStack {
    private static let logger = Logger(subsystem: "de.plmail", category: "store")

    public static let migrationPlan: (any SchemaMigrationPlan.Type)? = nil

    /// Opens the store, rebuilding it from scratch if it cannot be opened.
    public static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)

        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            logger.error("Store could not be opened, rebuilding: \(error, privacy: .public)")

            if inMemory == false {
                destroyStoreFiles()
            }

            do {
                return try ModelContainer(for: schema, configurations: configuration)
            } catch {
                // A container that cannot be created even from an empty file
                // means the device is out of space or the sandbox is broken.
                // There is no cache-shaped recovery from that.
                fatalError("Could not create the mail store: \(error)")
            }
        }
    }

    /// Deletes every cached message. Used on sign-out and on migration
    /// failure; the Keychain is the caller's responsibility.
    public static func destroyStoreFiles() {
        let directory = URL.applicationSupportDirectory

        // SwiftData writes a SQLite file plus its WAL and shared-memory
        // siblings. Removing only the first leaves a store that reopens with
        // stale contents.
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appending(path: "default.store\(suffix)")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
