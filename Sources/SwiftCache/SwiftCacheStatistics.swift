/// A snapshot of the cache's current memory and disk usage.
public struct SwiftCacheStatistics: Equatable, Sendable {
    /// The number of items currently held in memory.
    public var memoryItemCount: Int

    /// The number of bytes currently held in memory.
    public var memoryUsageBytes: Int

    /// The number of items currently tracked on disk.
    public var diskItemCount: Int

    /// The number of bytes currently tracked on disk.
    public var diskUsageBytes: Int

    /// Creates a cache statistics snapshot.
    ///
    /// - Parameters:
    ///   - memoryItemCount: The number of items currently held in memory.
    ///   - memoryUsageBytes: The number of bytes currently held in memory.
    ///   - diskItemCount: The number of items currently tracked on disk.
    ///   - diskUsageBytes: The number of bytes currently tracked on disk.
    public init(
        memoryItemCount: Int,
        memoryUsageBytes: Int,
        diskItemCount: Int,
        diskUsageBytes: Int
    ) {
        self.memoryItemCount = memoryItemCount
        self.memoryUsageBytes = memoryUsageBytes
        self.diskItemCount = diskItemCount
        self.diskUsageBytes = diskUsageBytes
    }
}
