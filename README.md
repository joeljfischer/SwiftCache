# SwiftCache

SwiftCache is a Swift Package Manager library for caching `Data` and `Codable`
objects in memory and on disk. It is strict-concurrency safe, uses least
recently used eviction, supports optional expiration dates, and automatically
prunes stale cache entries.

## Requirements

- Swift 6.3+
- iOS 15+
- macOS 13+
- tvOS 15+
- watchOS 9+

## Installation

Add SwiftCache to a Swift Package Manager project:

```swift
.package(url: "https://github.com/joeljfischer/SwiftCache.git", from: "0.1.0")
```

Then add the product to your target:

```swift
.product(name: "SwiftCache", package: "SwiftCache")
```

## Quick Start

Create a cache with the platform defaults:

```swift
import SwiftCache

let cache = try SwiftCache()
```

Store and retrieve raw data:

```swift
let data = Data("hello".utf8)

try await cache.store(data, forKey: "greeting")
let cachedData = try await cache.data(forKey: "greeting")
```

Store and retrieve `Codable` objects:

```swift
struct Profile: Codable, Sendable {
    var id: Int
    var name: String
}

try await cache.store(Profile(id: 1, name: "Avery"), forKey: "profile")

let profile = try await cache.object(forKey: "profile", as: Profile.self)
```

Add an expiration date:

```swift
try await cache.store(
    data,
    forKey: "temporary-response",
    expiresAt: Date().addingTimeInterval(60 * 60)
)
```

Or configure an automatic expiration interval for every stored item:

```swift
let cache = try SwiftCache(
    configuration: SwiftCacheConfiguration(defaultExpirationInterval: 60 * 60)
)
```

## Configuration

`SwiftCacheConfiguration` controls the cache directory and byte limits:

```swift
let configuration = SwiftCacheConfiguration(
    directory: customDirectory,
    memoryLimitBytes: 50 * 1_024 * 1_024,
    diskLimitBytes: 500 * 1_024 * 1_024,
    defaultExpirationInterval: 60 * 60
)

let cache = try SwiftCache(configuration: configuration)
```

By default, SwiftCache stores files in the platform Caches directory under an
app-scoped subdirectory. The directory name is `Bundle.main.bundleIdentifier`,
falling back to `SwiftCache`.

Default limits:

| Platform | Memory | Disk |
| --- | ---: | ---: |
| iOS, macOS, tvOS | 100 MB | 1 GB |
| watchOS | 4 MB | 32 MB |

## Eviction and Pruning

SwiftCache tracks both memory and disk usage in bytes. When a write exceeds a
configured limit, the least recently used entries are evicted until the cache is
back under the limit.

The cache prunes automatically:

- during initialization, by default
- after writes
- when an expired item is read
- when `prune()` is called

If `defaultExpirationInterval` is set, items stored without an explicit
`expiresAt` date expire after that interval. Passing `expiresAt` to `store`
overrides the default interval for that item.

Manual pruning returns a usage snapshot:

```swift
let statistics = try await cache.prune()
```

You can also inspect current usage without pruning:

```swift
let statistics = await cache.statistics()
print(statistics.memoryUsageBytes)
print(statistics.diskUsageBytes)
```

## Removing Values

Remove a single key:

```swift
let removed = try await cache.removeValue(forKey: "profile")
```

Remove everything:

```swift
try await cache.removeAll()
```

## Concurrency

`SwiftCache` is an actor. All mutable cache metadata is isolated inside the
actor, and public configuration/statistics/error types are `Sendable`.

## Notes

- Cached files are re-creatable data and may be removed by the system.
- Items larger than the disk limit are rejected.
- Items larger than the memory limit may still be stored on disk.
- `Codable` values are encoded and decoded with `JSONEncoder` and `JSONDecoder`.
