import CoreServices
import Foundation

// Watch only the open tab. FSEvents batches worktree and Git metadata changes,
// including index updates for linked worktrees outside the working directory.
@MainActor
final class RepositoryEvents {
    let updates: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var stream: FSEventStreamRef?

    init?(paths: [String]) {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<RepositoryEvents>.fromOpaque(info).takeUnretainedValue().continuation.yield()
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.45, 0) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { stop(); return nil }
        continuation.yield()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        continuation.finish()
    }
}
