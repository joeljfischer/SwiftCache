import Foundation

/// Errors thrown by ``SwiftCache``.
public enum SwiftCacheError: LocalizedError, Equatable, Sendable {
    /// The provided cache configuration is invalid.
    case invalidConfiguration(String)

    /// The item is larger than the configured disk cache limit.
    case itemExceedsDiskLimit(itemSizeBytes: Int, diskLimitBytes: Int)

    /// A localized description of the cache error.
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            message
        case let .itemExceedsDiskLimit(itemSizeBytes, diskLimitBytes):
            "Cache item size (\(itemSizeBytes) bytes) exceeds the disk cache limit (\(diskLimitBytes) bytes)."
        }
    }
}
