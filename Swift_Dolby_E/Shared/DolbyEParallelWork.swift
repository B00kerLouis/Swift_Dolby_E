// Copyright © 2026 B00kerLouis.
// SPDX-License-Identifier: LGPL-3.0-or-later
import Foundation
import Dispatch

/// A synchronous barrier keeps the existing stateful frame/file APIs atomic.
/// Inputs are immutable Sendable values; workers return independent values.
/// Errors and output are collected in input order, never completion order.
enum DolbyEParallelWork {
    static func limit(_ requested: Int) throws -> Int {
        guard (0...16).contains(requested) else { throw DolbyEError.invalidArgument("encoder parallelism must be0(auto)...16") }
        let available = max(1,ProcessInfo.processInfo.activeProcessorCount)
        return min(available,requested == 0 ? 8 : requested)
    }
    private final class Results<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Result<Value,Error>?]
        init(count: Int) { values = Array(repeating:nil,count:count) }
        func put(_ value: Result<Value,Error>,at index: Int) { lock.withLock { values[index] = value } }
        func finish() throws -> [Value] {
            try lock.withLock { try values.map {
                guard let value = $0 else { throw DolbyEError.malformed("encoder worker did not finish") }
                return try value.get()
            } }
        }
    }
    static func map<Input: Sendable,Output: Sendable>(_ values: [Input],parallelism: Int,
        _ transform: @escaping @Sendable (Input,Int) throws -> Output) throws -> [Output] {
        let count = min(try limit(parallelism),values.count)
        if count <= 1 { return try values.enumerated().map { try transform($0.element,$0.offset) } }
        let results = Results<Output>(count:values.count)
        DispatchQueue.concurrentPerform(iterations:count) { worker in
            for index in stride(from:worker,to:values.count,by:count) {
                results.put(Result { try transform(values[index],index) },at:index)
            }
        }
        return try results.finish()
    }
}
