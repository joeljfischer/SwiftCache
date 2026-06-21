import CryptoKit
import Foundation

/// A strict-concurrency-safe cache that stores `Data` and `Codable` values in memory and on disk.
public actor SwiftCache {
    private let configuration: SwiftCacheConfiguration
    private let manifestURL: URL

    private var memoryEntries: [String: MemoryEntry]
    private var diskEntries: [String: DiskEntry]
    private var memoryUsageBytes: Int
    private var diskUsageBytes: Int
    private var accessCounter: UInt64

    /// Creates a cache using the provided configuration.
    ///
    /// Initialization creates the cache directory if needed, loads existing metadata, reconciles it with
    /// files on disk, and prunes stale entries when configured to do so.
    ///
    /// - Parameter configuration: The cache configuration.
    /// - Throws: ``SwiftCacheError`` for invalid configuration, or a filesystem error while preparing storage.
    public init(configuration: SwiftCacheConfiguration = .defaultConfiguration) throws {
        try Self.validate(configuration)

        let manifestURL = configuration.directory.appendingPathComponent(Self.manifestFileName, isDirectory: false)
        let initialState = try Self.loadInitialState(
            configuration: configuration,
            manifestURL: manifestURL
        )

        self.configuration = configuration
        self.manifestURL = manifestURL
        self.memoryEntries = [:]
        self.diskEntries = initialState.diskEntries
        self.memoryUsageBytes = 0
        self.diskUsageBytes = initialState.diskUsageBytes
        self.accessCounter = initialState.accessCounter
    }

    /// Stores data in the cache.
    ///
    /// The item is written to disk and retained in memory when it fits within the memory limit. If storing
    /// the item causes either cache tier to exceed its byte limit, least-recently-used entries are evicted.
    ///
    /// - Parameters:
    ///   - data: The data to cache.
    ///   - key: The cache key used to retrieve the data later.
    ///   - expiresAt: The optional date after which the cached item should be treated as missing.
    /// - Throws: ``SwiftCacheError/itemExceedsDiskLimit(itemSizeBytes:diskLimitBytes:)`` when the item is
    ///   larger than the disk limit, or a filesystem error while writing the item.
    public func store(_ data: Data, forKey key: String, expiresAt: Date? = nil) throws {
        guard data.count <= configuration.diskLimitBytes else {
            throw SwiftCacheError.itemExceedsDiskLimit(
                itemSizeBytes: data.count,
                diskLimitBytes: configuration.diskLimitBytes
            )
        }

        let access = nextAccess()
        let filename = Self.filename(forKey: key)
        let fileURL = cacheFileURL(filename: filename)
        let previousDiskSize = diskEntries[key]?.sizeBytes ?? 0

        if isExpired(expiresAt) {
            try removeValue(forKey: key)
            return
        }

        try data.write(to: fileURL, options: [.atomic])

        diskEntries[key] = DiskEntry(
            key: key,
            filename: filename,
            sizeBytes: data.count,
            lastAccess: access,
            expiresAt: expiresAt
        )
        diskUsageBytes += data.count - previousDiskSize

        if data.count <= configuration.memoryLimitBytes {
            let previousMemorySize = memoryEntries[key]?.sizeBytes ?? 0
            memoryEntries[key] = MemoryEntry(
                data: data,
                sizeBytes: data.count,
                lastAccess: access,
                expiresAt: expiresAt
            )
            memoryUsageBytes += data.count - previousMemorySize
        } else {
            removeMemoryEntry(forKey: key)
        }

        try pruneStorage()
        try saveManifest()
    }

    /// Encodes and stores a `Codable` value in the cache.
    ///
    /// Values are encoded with `JSONEncoder` and stored using the same eviction and expiration behavior
    /// as ``store(_:forKey:expiresAt:)-5kh73``.
    ///
    /// - Parameters:
    ///   - value: The value to encode and cache.
    ///   - key: The cache key used to retrieve the value later.
    ///   - expiresAt: The optional date after which the cached value should be treated as missing.
    /// - Throws: An encoding error, ``SwiftCacheError``, or a filesystem error while storing the value.
    public func store<Value: Encodable & Sendable>(
        _ value: Value,
        forKey key: String,
        expiresAt: Date? = nil
    ) throws {
        let data = try JSONEncoder().encode(value)
        try store(data, forKey: key, expiresAt: expiresAt)
    }

    /// Returns the cached data for a key.
    ///
    /// Accessing data updates its least-recently-used metadata. Expired entries are removed and returned
    /// as `nil`.
    ///
    /// - Parameter key: The key for the cached data.
    /// - Returns: The cached data, or `nil` when no unexpired item exists for the key.
    /// - Throws: A filesystem error while reading or pruning cache files.
    public func data(forKey key: String) throws -> Data? {
        let access = nextAccess()

        if let memoryEntry = memoryEntries[key] {
            if isExpired(memoryEntry.expiresAt) {
                try removeValue(forKey: key)
                return nil
            }

            memoryEntries[key] = MemoryEntry(
                data: memoryEntry.data,
                sizeBytes: memoryEntry.sizeBytes,
                lastAccess: access,
                expiresAt: memoryEntry.expiresAt
            )
            if let diskEntry = diskEntries[key] {
                diskEntries[key] = diskEntry.updatingLastAccess(access)
                try saveManifest()
            }
            return memoryEntry.data
        }

        guard let diskEntry = diskEntries[key] else {
            return nil
        }

        if isExpired(diskEntry.expiresAt) {
            try removeValue(forKey: key)
            return nil
        }

        let fileURL = cacheFileURL(filename: diskEntry.filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            removeDiskEntry(forKey: key)
            try saveManifest()
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let actualSize = data.count
        diskEntries[key] = diskEntry.updating(sizeBytes: actualSize, lastAccess: access)
        diskUsageBytes += actualSize - diskEntry.sizeBytes

        if actualSize <= configuration.memoryLimitBytes {
            memoryEntries[key] = MemoryEntry(
                data: data,
                sizeBytes: actualSize,
                lastAccess: access,
                expiresAt: diskEntry.expiresAt
            )
            memoryUsageBytes += actualSize
            pruneMemory()
        }

        try pruneStorage()
        try saveManifest()

        return data
    }

    /// Returns and decodes a cached `Codable` value for a key.
    ///
    /// The value is decoded with `JSONDecoder`. Expired entries are removed and returned as `nil`.
    ///
    /// - Parameters:
    ///   - key: The key for the cached value.
    ///   - type: The value type to decode.
    /// - Returns: The decoded value, or `nil` when no unexpired item exists for the key.
    /// - Throws: A decoding error or a filesystem error while reading or pruning cache files.
    public func object<Value: Decodable & Sendable>(
        forKey key: String,
        as type: Value.Type = Value.self
    ) throws -> Value? {
        guard let data = try data(forKey: key) else { return nil }

        return try JSONDecoder().decode(type, from: data)
    }

    /// Removes a cached item from memory and disk.
    ///
    /// - Parameter key: The key for the item to remove.
    /// - Returns: `true` when an item was removed from either cache tier.
    /// - Throws: A filesystem error while removing the item or saving metadata.
    @discardableResult
    public func removeValue(forKey key: String) throws -> Bool {
        var removed = false

        if let diskEntry = diskEntries[key] {
            try removeCacheFile(named: diskEntry.filename)
            removeDiskEntry(forKey: key)
            removed = true
        }

        if memoryEntries[key] != nil {
            removeMemoryEntry(forKey: key)
            removed = true
        }

        if removed {
            try saveManifest()
        }

        return removed
    }

    /// Removes all cached items from memory and disk.
    ///
    /// - Throws: A filesystem error while removing cache files or saving metadata.
    public func removeAll() throws {
        try removeCacheFiles()
        memoryEntries.removeAll(keepingCapacity: false)
        diskEntries.removeAll(keepingCapacity: false)
        memoryUsageBytes = 0
        diskUsageBytes = 0
        try saveManifest()
    }

    /// Reconciles and prunes the cache immediately.
    ///
    /// Pruning removes expired entries, removes metadata for missing files, deletes unknown cache files,
    /// and evicts least-recently-used entries until configured byte limits are satisfied.
    ///
    /// - Returns: A statistics snapshot after pruning completes.
    /// - Throws: A filesystem error while inspecting, removing, or saving cache files.
    @discardableResult
    public func prune() throws -> SwiftCacheStatistics {
        try reconcileDiskEntries(removeUnknownCacheFiles: true)
        try pruneStorage()
        try saveManifest()
        return statisticsSnapshot()
    }

    /// Returns a snapshot of the cache's current memory and disk usage.
    ///
    /// - Returns: A statistics snapshot.
    public var currentStatistics: SwiftCacheStatistics {
        statisticsSnapshot()
    }
}

private extension SwiftCache {
    static let manifestFileName = "manifest.json"
    static let cacheFileExtension = "cache"

    struct Manifest: Codable {
        var accessCounter: UInt64
        var entries: [DiskEntry]
    }

    struct InitialState {
        var diskEntries: [String: DiskEntry]
        var diskUsageBytes: Int
        var accessCounter: UInt64
    }

    struct DiskEntry: Codable, Sendable {
        var key: String
        var filename: String
        var sizeBytes: Int
        var lastAccess: UInt64
        var expiresAt: Date?

        func updatingLastAccess(_ lastAccess: UInt64) -> DiskEntry {
            DiskEntry(
                key: key,
                filename: filename,
                sizeBytes: sizeBytes,
                lastAccess: lastAccess,
                expiresAt: expiresAt
            )
        }

        func updating(sizeBytes: Int, lastAccess: UInt64) -> DiskEntry {
            DiskEntry(
                key: key,
                filename: filename,
                sizeBytes: sizeBytes,
                lastAccess: lastAccess,
                expiresAt: expiresAt
            )
        }
    }

    struct MemoryEntry: Sendable {
        var data: Data
        var sizeBytes: Int
        var lastAccess: UInt64
        var expiresAt: Date?
    }

    static func validate(_ configuration: SwiftCacheConfiguration) throws {
        guard configuration.directory.isFileURL else {
            throw SwiftCacheError.invalidConfiguration("Cache directory must be a file URL.")
        }

        guard configuration.memoryLimitBytes >= 0 else {
            throw SwiftCacheError.invalidConfiguration("Memory limit must be greater than or equal to zero.")
        }

        guard configuration.diskLimitBytes >= 0 else {
            throw SwiftCacheError.invalidConfiguration("Disk limit must be greater than or equal to zero.")
        }
    }

    static func filename(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hexDigest = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hexDigest).\(cacheFileExtension)"
    }

    static func loadInitialState(
        configuration: SwiftCacheConfiguration,
        manifestURL: URL
    ) throws -> InitialState {
        try FileManager.default.createDirectory(
            at: configuration.directory,
            withIntermediateDirectories: true
        )

        var diskEntries: [String: DiskEntry] = [:]
        var diskUsageBytes = 0
        var accessCounter: UInt64 = 0

        if let manifest = try loadManifest(at: manifestURL, directory: configuration.directory) {
            accessCounter = manifest.accessCounter
            for entry in manifest.entries {
                diskEntries[entry.key] = entry
            }
        }

        try reconcileDiskEntries(
            &diskEntries,
            diskUsageBytes: &diskUsageBytes,
            directory: configuration.directory,
            removeUnknownCacheFiles: true
        )

        accessCounter = max(accessCounter, diskEntries.values.map(\.lastAccess).max() ?? 0)

        if configuration.pruneOnInitialization {
            try pruneExpiredDiskEntries(
                &diskEntries,
                diskUsageBytes: &diskUsageBytes,
                directory: configuration.directory
            )
            try pruneDiskEntries(
                &diskEntries,
                diskUsageBytes: &diskUsageBytes,
                diskLimitBytes: configuration.diskLimitBytes,
                directory: configuration.directory
            )
            try saveManifest(
                entries: diskEntries,
                accessCounter: accessCounter,
                manifestURL: manifestURL
            )
        }

        return InitialState(
            diskEntries: diskEntries,
            diskUsageBytes: diskUsageBytes,
            accessCounter: accessCounter
        )
    }

    static func loadManifest(at manifestURL: URL, directory: URL) throws -> Manifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            try removeCacheFiles(in: directory)
            try? FileManager.default.removeItem(at: manifestURL)
            return nil
        }
    }

    static func saveManifest(
        entries: [String: DiskEntry],
        accessCounter: UInt64,
        manifestURL: URL
    ) throws {
        let manifest = Manifest(
            accessCounter: accessCounter,
            entries: sortedEntries(entries)
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }

    static func sortedEntries(_ entries: [String: DiskEntry]) -> [DiskEntry] {
        entries.values.sorted { lhs, rhs in
            if lhs.lastAccess == rhs.lastAccess {
                return lhs.key < rhs.key
            }
            return lhs.lastAccess < rhs.lastAccess
        }
    }

    /// Rebuilds metadata from the files that actually exist on disk. This keeps the manifest from
    /// trusting stale byte counts and removes files that SwiftCache does not know how to reach.
    static func reconcileDiskEntries(
        _ entries: inout [String: DiskEntry],
        diskUsageBytes: inout Int,
        directory: URL,
        removeUnknownCacheFiles: Bool
    ) throws {
        var reconciledEntries: [String: DiskEntry] = [:]
        var reconciledUsage = 0
        var knownFilenames = Set<String>()

        for entry in entries.values {
            let fileURL = cacheFileURL(filename: entry.filename, directory: directory)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                continue
            }

            let size = try fileSize(at: fileURL)
            let reconciledEntry = entry.updating(sizeBytes: size, lastAccess: entry.lastAccess)
            reconciledEntries[entry.key] = reconciledEntry
            reconciledUsage += size
            knownFilenames.insert(entry.filename)
        }

        entries = reconciledEntries
        diskUsageBytes = reconciledUsage

        if removeUnknownCacheFiles {
            for fileURL in try cacheFileURLs(in: directory) {
                guard !knownFilenames.contains(fileURL.lastPathComponent) else {
                    continue
                }
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    static func pruneExpiredDiskEntries(
        _ entries: inout [String: DiskEntry],
        diskUsageBytes: inout Int,
        directory: URL,
        now: Date = Date()
    ) throws {
        let expiredKeys = entries.values
            .filter { isExpired($0.expiresAt, now: now) }
            .map(\.key)

        for key in expiredKeys {
            guard let entry = entries.removeValue(forKey: key) else {
                continue
            }

            try removeCacheFile(named: entry.filename, directory: directory)
            diskUsageBytes -= entry.sizeBytes
        }
    }

    /// Removes the coldest disk entries until tracked usage fits the configured byte limit.
    static func pruneDiskEntries(
        _ entries: inout [String: DiskEntry],
        diskUsageBytes: inout Int,
        diskLimitBytes: Int,
        directory: URL
    ) throws {
        while diskUsageBytes > diskLimitBytes {
            guard let entry = entries.min(by: { lhs, rhs in
                lhs.value.lastAccess < rhs.value.lastAccess
            }) else {
                return
            }

            try removeCacheFile(named: entry.value.filename, directory: directory)
            entries.removeValue(forKey: entry.key)
            diskUsageBytes -= entry.value.sizeBytes
        }
    }

    static func isExpired(_ expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let expiresAt else {
            return false
        }

        return expiresAt <= now
    }

    static func cacheFileURL(filename: String, directory: URL) -> URL {
        directory.appendingPathComponent(filename, isDirectory: false)
    }

    static func cacheFileURLs(in directory: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return files.filter { $0.pathExtension == cacheFileExtension }
    }

    static func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int ?? 0
    }

    static func removeCacheFile(named filename: String, directory: URL) throws {
        let fileURL = cacheFileURL(filename: filename, directory: directory)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    static func removeCacheFiles(in directory: URL) throws {
        for fileURL in try cacheFileURLs(in: directory) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func saveManifest() throws {
        try Self.saveManifest(
            entries: diskEntries,
            accessCounter: accessCounter,
            manifestURL: manifestURL
        )
    }

    func reconcileDiskEntries(removeUnknownCacheFiles: Bool) throws {
        var reconciledEntries: [String: DiskEntry] = [:]
        var reconciledUsage = 0
        var knownFilenames = Set<String>()

        for entry in diskEntries.values {
            let fileURL = cacheFileURL(filename: entry.filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                removeMemoryEntry(forKey: entry.key)
                continue
            }

            let size = try fileSize(at: fileURL)
            let reconciledEntry = entry.updating(sizeBytes: size, lastAccess: entry.lastAccess)
            reconciledEntries[entry.key] = reconciledEntry
            reconciledUsage += size
            knownFilenames.insert(entry.filename)
        }

        diskEntries = reconciledEntries
        diskUsageBytes = reconciledUsage

        if removeUnknownCacheFiles {
            for fileURL in try cacheFileURLs() {
                guard !knownFilenames.contains(fileURL.lastPathComponent) else {
                    continue
                }
                try FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func pruneStorage() throws {
        try pruneExpiredEntries()
        pruneMemory()
        try pruneDisk()
    }

    func pruneExpiredEntries(now: Date = Date()) throws {
        let expiredMemoryKeys = memoryEntries
            .filter { Self.isExpired($0.value.expiresAt, now: now) }
            .map(\.key)

        for key in expiredMemoryKeys {
            removeMemoryEntry(forKey: key)
        }

        let expiredDiskKeys = diskEntries.values
            .filter { Self.isExpired($0.expiresAt, now: now) }
            .map(\.key)

        for key in expiredDiskKeys {
            guard let entry = diskEntries[key] else {
                continue
            }

            try removeCacheFile(named: entry.filename)
            removeDiskEntry(forKey: key)
            removeMemoryEntry(forKey: key)
        }
    }

    func pruneMemory() {
        while memoryUsageBytes > configuration.memoryLimitBytes {
            guard let entry = memoryEntries.min(by: { lhs, rhs in
                lhs.value.lastAccess < rhs.value.lastAccess
            }) else {
                return
            }
            removeMemoryEntry(forKey: entry.key)
        }
    }

    func pruneDisk() throws {
        let originalKeys = Set(diskEntries.keys)
        try Self.pruneDiskEntries(
            &diskEntries,
            diskUsageBytes: &diskUsageBytes,
            diskLimitBytes: configuration.diskLimitBytes,
            directory: configuration.directory
        )
        let removedKeys = originalKeys.subtracting(diskEntries.keys)
        for key in removedKeys {
            removeMemoryEntry(forKey: key)
        }
    }

    func nextAccess() -> UInt64 {
        accessCounter += 1
        return accessCounter
    }

    func isExpired(_ expiresAt: Date?) -> Bool {
        Self.isExpired(expiresAt)
    }

    func cacheFileURL(filename: String) -> URL {
        Self.cacheFileURL(filename: filename, directory: configuration.directory)
    }

    func cacheFileURLs() throws -> [URL] {
        try Self.cacheFileURLs(in: configuration.directory)
    }

    func fileSize(at url: URL) throws -> Int {
        try Self.fileSize(at: url)
    }

    func removeCacheFile(named filename: String) throws {
        try Self.removeCacheFile(named: filename, directory: configuration.directory)
    }

    func removeCacheFiles() throws {
        try Self.removeCacheFiles(in: configuration.directory)
    }

    func removeMemoryEntry(forKey key: String) {
        if let memoryEntry = memoryEntries.removeValue(forKey: key) {
            memoryUsageBytes -= memoryEntry.sizeBytes
        }
    }

    func removeDiskEntry(forKey key: String) {
        if let diskEntry = diskEntries.removeValue(forKey: key) {
            diskUsageBytes -= diskEntry.sizeBytes
        }
    }

    func statisticsSnapshot() -> SwiftCacheStatistics {
        SwiftCacheStatistics(
            memoryItemCount: memoryEntries.count,
            memoryUsageBytes: memoryUsageBytes,
            diskItemCount: diskEntries.count,
            diskUsageBytes: diskUsageBytes
        )
    }
}
