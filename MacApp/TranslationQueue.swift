import Foundation

@MainActor
final class TranslationQueue {
    private struct Job: Sendable {
        let data: Data
        let completion: CheckedContinuation<Data, Never>
    }

    private let continuation: AsyncStream<Job>.Continuation
    private var pending = 0
    private let worker: Task<Void, Never>

    init() {
        let (stream, continuation) = AsyncStream<Job>.makeStream()
        self.continuation = continuation
        self.worker = Task { await Self.consume(stream) }
    }

    func submit(_ data: Data) async -> Data {
        guard pending < 8 else {
            return Data(#"{"error":{"code":"busy","message":"翻译请求较多，请稍后重试。"}}"#.utf8)
        }
        pending += 1
        defer { pending -= 1 }
        return await withCheckedContinuation { completion in
            continuation.yield(Job(data: data, completion: completion))
        }
    }

    nonisolated private static func consume(_ stream: AsyncStream<Job>) async {
        let processor = TranslationProcessor()
        for await job in stream {
            job.completion.resume(returning: await processor.process(job.data))
        }
    }
}
