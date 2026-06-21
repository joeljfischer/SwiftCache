import Foundation
import Testing
@testable import SwiftCache

private struct Profile: Codable, Equatable, Sendable {
    var id: Int
    var name: String
}

@Test func usesDefaultMemoryAndDiskLimits() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let configuration = SwiftCacheConfiguration(directory: directory)
    #if os(watchOS)
    #expect(configuration.memoryLimitBytes == 4 * 1_024 * 1_024)
    #expect(configuration.diskLimitBytes == 32 * 1_024 * 1_024)
    #else
    #expect(configuration.memoryLimitBytes == 100 * 1_024 * 1_024)
    #expect(configuration.diskLimitBytes == 1_024 * 1_024 * 1_024)
    #endif

    let cache = try SwiftCache(configuration: configuration)
    try await cache.store(Data("hello".utf8), forKey: "greeting")

    let statistics = await cache.currentStatistics
    #expect(statistics.memoryUsageBytes == 5)
    #expect(statistics.diskUsageBytes == 5)
}

@Test func defaultDirectoryUsesCachesDirectory() {
    let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    let directory = SwiftCacheConfiguration.defaultDirectory

    #expect(directory.lastPathComponent == SwiftCacheConfiguration.defaultDirectoryName)
    if let cacheRoot {
        #expect(directory.path.hasPrefix(cacheRoot.path))
    }
}

@Test func storesAndReadsData() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 64
        )
    )

    let data = Data("hello".utf8)
    try await cache.store(data, forKey: "greeting")

    let cachedData = try await cache.data(forKey: "greeting")
    #expect(cachedData == data)

    let statistics = await cache.currentStatistics
    #expect(statistics.memoryItemCount == 1)
    #expect(statistics.memoryUsageBytes == data.count)
    #expect(statistics.diskItemCount == 1)
    #expect(statistics.diskUsageBytes == data.count)
}

@Test func returnsNilForExpiredDataAndRemovesIt() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 64
        )
    )

    try await cache.store(
        Data("expired".utf8),
        forKey: "token",
        expiresAt: Date(timeIntervalSinceNow: -1)
    )

    #expect(try await cache.data(forKey: "token") == nil)

    let statistics = await cache.currentStatistics
    #expect(statistics.memoryItemCount == 0)
    #expect(statistics.diskItemCount == 0)
}

@Test func keepsUnexpiredDataUntilExpiryDate() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 64
        )
    )

    let data = Data("fresh".utf8)
    try await cache.store(
        data,
        forKey: "token",
        expiresAt: Date(timeIntervalSinceNow: 3_600)
    )

    #expect(try await cache.data(forKey: "token") == data)
}

@Test func prunesExpiredDiskEntriesOnStartup() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let firstCache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 64
        )
    )

    try await firstCache.store(
        Data("expired".utf8),
        forKey: "expired",
        expiresAt: Date(timeIntervalSinceNow: 3_600)
    )
    try await firstCache.store(Data("fresh".utf8), forKey: "fresh")

    let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
    let manifestData = try Data(contentsOf: manifestURL)
    var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    var entries = try #require(manifest?["entries"] as? [[String: Any]])
    let pastDate = Date(timeIntervalSinceNow: -1).timeIntervalSinceReferenceDate
    let entryIndex = try #require(entries.firstIndex { $0["key"] as? String == "expired" })
    entries[entryIndex]["expiresAt"] = pastDate
    manifest?["entries"] = entries
    let updatedManifest = try JSONSerialization.data(withJSONObject: try #require(manifest))
    try updatedManifest.write(to: manifestURL)

    let secondCache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 64
        )
    )

    #expect(try await secondCache.data(forKey: "expired") == nil)
    #expect(try await secondCache.data(forKey: "fresh") == Data("fresh".utf8))

    let statistics = await secondCache.currentStatistics
    #expect(statistics.diskItemCount == 1)
}

@Test func storesAndRetrievesCodableValues() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 128,
            diskLimitBytes: 256
        )
    )

    let profile = Profile(id: 42, name: "Blob")
    try await cache.store(profile, forKey: "profile")

    let cachedProfile = try await cache.object(forKey: "profile", as: Profile.self)
    #expect(cachedProfile == profile)
}

@Test func returnsNilForExpiredCodableValues() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 128,
            diskLimitBytes: 256
        )
    )

    try await cache.store(
        Profile(id: 1, name: "Expired"),
        forKey: "profile",
        expiresAt: Date(timeIntervalSinceNow: -1)
    )

    let cachedProfile = try await cache.object(forKey: "profile", as: Profile.self)
    #expect(cachedProfile == nil)
}

@Test func evictsLeastRecentlyUsedMemoryEntryWhenMemoryLimitIsExceeded() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 5,
            diskLimitBytes: 32
        )
    )

    let firstData = Data("abc".utf8)
    let secondData = Data("def".utf8)

    try await cache.store(firstData, forKey: "first")
    try await cache.store(secondData, forKey: "second")

    var statistics = await cache.currentStatistics
    #expect(statistics.memoryItemCount == 1)
    #expect(statistics.memoryUsageBytes == secondData.count)
    #expect(statistics.diskItemCount == 2)

    #expect(try await cache.data(forKey: "first") == firstData)

    statistics = await cache.currentStatistics
    #expect(statistics.memoryItemCount == 1)
    #expect(statistics.memoryUsageBytes == firstData.count)
    #expect(try await cache.data(forKey: "second") == secondData)
}

@Test func evictsLeastRecentlyUsedDiskEntryWhenDiskLimitIsExceeded() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 5
        )
    )

    let firstData = Data("abc".utf8)
    let secondData = Data("def".utf8)

    try await cache.store(firstData, forKey: "first")
    try await cache.store(secondData, forKey: "second")

    let statistics = await cache.currentStatistics
    #expect(statistics.diskItemCount == 1)
    #expect(statistics.diskUsageBytes == secondData.count)
    #expect(statistics.memoryItemCount == 1)

    #expect(try await cache.data(forKey: "first") == nil)
    #expect(try await cache.data(forKey: "second") == secondData)
}

@Test func storesItemsLargerThanMemoryLimitOnDiskOnly() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 2,
            diskLimitBytes: 16
        )
    )

    let data = Data("abcd".utf8)
    try await cache.store(data, forKey: "large")

    var statistics = await cache.currentStatistics
    #expect(statistics.memoryItemCount == 0)
    #expect(statistics.diskItemCount == 1)

    #expect(try await cache.data(forKey: "large") == data)

    statistics = await cache.currentStatistics
    #expect(statistics.memoryItemCount == 0)
    #expect(statistics.diskItemCount == 1)
}

@Test func rejectsItemsLargerThanDiskLimit() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 16,
            diskLimitBytes: 3
        )
    )

    await #expect(throws: SwiftCacheError.itemExceedsDiskLimit(itemSizeBytes: 4, diskLimitBytes: 3)) {
        try await cache.store(Data("abcd".utf8), forKey: "too-large")
    }

    let statistics = await cache.currentStatistics
    #expect(statistics.memoryItemCount == 0)
    #expect(statistics.diskItemCount == 0)
}

@Test func persistsDiskEntriesAcrossCacheInstances() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let data = Data("persistent".utf8)
    let firstCache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 64
        )
    )
    try await firstCache.store(data, forKey: "saved")

    let secondCache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 64
        )
    )

    #expect(try await secondCache.data(forKey: "saved") == data)
}

@Test func prunesDiskEntriesOnStartup() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let firstCache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 64
        )
    )

    try await firstCache.store(Data("abc".utf8), forKey: "first")
    try await firstCache.store(Data("def".utf8), forKey: "second")

    let secondCache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 5
        )
    )

    let statistics = await secondCache.currentStatistics
    #expect(statistics.diskItemCount == 1)
    #expect(try await secondCache.data(forKey: "first") == nil)
    #expect(try await secondCache.data(forKey: "second") == Data("def".utf8))
}

@Test func manualPruneReconcilesMissingAndOrphanedFiles() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 64
        )
    )

    try await cache.store(Data("abc".utf8), forKey: "first")

    let cacheFile = try #require(cacheFileURLs(in: directory).first)
    try FileManager.default.removeItem(at: cacheFile)

    let orphanedFile = directory.appendingPathComponent("orphan.cache", isDirectory: false)
    try Data("orphan".utf8).write(to: orphanedFile)

    let statistics = try await cache.prune()
    let remainingCacheFiles = try cacheFileURLs(in: directory)
    #expect(statistics.diskItemCount == 0)
    #expect(remainingCacheFiles.isEmpty)
    #expect(try await cache.data(forKey: "first") == nil)
}

@Test func removesSingleValuesAndAllValues() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 32,
            diskLimitBytes: 64
        )
    )

    try await cache.store(Data("abc".utf8), forKey: "first")
    try await cache.store(Data("def".utf8), forKey: "second")

    #expect(try await cache.removeValue(forKey: "first"))
    #expect(try await cache.data(forKey: "first") == nil)
    #expect(try await cache.data(forKey: "second") == Data("def".utf8))

    try await cache.removeAll()

    let statistics = await cache.currentStatistics
    let remainingCacheFiles = try cacheFileURLs(in: directory)
    #expect(statistics.memoryItemCount == 0)
    #expect(statistics.diskItemCount == 0)
    #expect(remainingCacheFiles.isEmpty)
}

@Test func supportsConcurrentAccessThroughActorIsolation() async throws {
    let directory = makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }

    let cache = try SwiftCache(
        configuration: SwiftCacheConfiguration(
            directory: directory,
            memoryLimitBytes: 1_024,
            diskLimitBytes: 2_048
        )
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<25 {
            group.addTask {
                let data = Data("value-\(index)".utf8)
                try await cache.store(data, forKey: "key-\(index)")
                #expect(try await cache.data(forKey: "key-\(index)") == data)
            }
        }

        try await group.waitForAll()
    }

    let statistics = await cache.currentStatistics
    #expect(statistics.diskItemCount == 25)
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftCacheTests-\(UUID().uuidString)", isDirectory: true)
}

private func removeTemporaryDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func cacheFileURLs(in directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return []
    }

    return try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "cache" }
}
