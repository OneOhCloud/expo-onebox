import Foundation

/// 为在同步的 Libbox 回调中使用 async/await 代码而做的桥接。
/// Network Extension target 需要一份自己的副本。

func runBlocking<T>(_ block: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ExtRunBlockingBox<T>()
    Task.detached {
        let value = await block()
        box.result0 = value
        semaphore.signal()
    }
    semaphore.wait()
    return box.result0
}

func runBlocking<T>(_ tBlock: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ExtRunBlockingBox<T>()
    Task.detached {
        do {
            let value = try await tBlock()
            box.result = .success(value)
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.result.get()
}

private class ExtRunBlockingBox<T> {
    var result: Result<T, Error>!
    var result0: T!
}
