import Foundation

/// Configuration values that control where and how a ``SwiftCache`` stores items.
public struct SwiftCacheConfiguration: Sendable {
    /// The default directory used for cache files and metadata.
    ///
    /// The directory is created under the platform's user-domain Caches directory and scoped to the
    /// current app when a bundle identifier is available.
    ///
    /// Defaults to the cache directory and falls back to the temporary directory, then builds `defaultDirectoryName` within that directory.
    public static var defaultDirectory: URL {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cacheRoot.appendingPathComponent(defaultDirectoryName, isDirectory: true)
    }

    /// The default cache directory name. Defaults to the bundle identifier, falls back to "SwiftCache".
    public static var defaultDirectoryName: String {
        Bundle.main.bundleIdentifier ?? "SwiftCache"
    }

    #if os(watchOS)
    /// The platform-specific default in-memory cache limit. Defaults to 4mb on watchOS, and 100mb elsewhere.
    public static let defaultMemoryLimitBytes = 4 * 1_024 * 1_024
    #else
    /// The platform-specific default in-memory cache limit. Defaults to 4mb on watchOS, and 100mb elsewhere.
    public static let defaultMemoryLimitBytes = 100 * 1_024 * 1_024
    #endif

    #if os(watchOS)
    /// The platform-specific default on-disk cache limit. Defaults to 32mb on watchOS, and 1gb elsewhere.
    public static let defaultDiskLimitBytes = 32 * 1_024 * 1_024
    #else
    /// The platform-specific default on-disk cache limit. Defaults to 32mb on watchOS, and 1gb elsewhere.
    public static let defaultDiskLimitBytes = 1_024 * 1_024 * 1_024
    #endif

    /// The directory where cache files and metadata are stored.
    public var directory: URL

    /// The maximum number of bytes to keep in memory.
    public var memoryLimitBytes: Int

    /// The maximum number of bytes to keep on disk.
    public var diskLimitBytes: Int

    /// A Boolean value indicating whether disk entries are reconciled and pruned during initialization.
    public var pruneOnInitialization: Bool

    /// The interval after which newly stored items expire automatically.
    ///
    /// A value of `nil` means items do not automatically expire unless a specific expiration date is
    /// provided when storing the item.
    public var defaultExpirationInterval: TimeInterval?

    /// Creates cache configuration.
    ///
    /// - Parameters:
    ///   - directory: The directory where cache files and metadata are stored. Defaults to
    ///     ``defaultDirectory``.
    ///   - memoryLimitBytes: The maximum number of bytes to keep in memory. Defaults to 100 MB on
    ///     iOS, macOS, and tvOS, and 4 MB on watchOS.
    ///   - diskLimitBytes: The maximum number of bytes to keep on disk. Defaults to 1 GB on iOS,
    ///     macOS, and tvOS, and 32 MB on watchOS.
    ///   - pruneOnInitialization: Whether to reconcile and prune disk entries during initialization.
    ///   - defaultExpirationInterval: The interval after which newly stored items expire automatically.
    ///     Defaults to `nil`, which means items do not automatically expire.
    public init(
        directory: URL = Self.defaultDirectory,
        memoryLimitBytes: Int = Self.defaultMemoryLimitBytes,
        diskLimitBytes: Int = Self.defaultDiskLimitBytes,
        pruneOnInitialization: Bool = true,
        defaultExpirationInterval: TimeInterval? = nil
    ) {
        self.directory = directory
        self.memoryLimitBytes = memoryLimitBytes
        self.diskLimitBytes = diskLimitBytes
        self.pruneOnInitialization = pruneOnInitialization
        self.defaultExpirationInterval = defaultExpirationInterval
    }

    /// A cache configuration using the platform defaults.
    public static var defaultConfiguration: Self { .init() }
}
