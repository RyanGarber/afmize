import Foundation
import Synchronization

/// C ABI surface for host applications (e.g. the Rust core of a Tauri app).
///
/// Contract:
/// - `afmize_stream_start(requestJSON, context, callback)` starts a stream and
///   returns a stream id (or -1 on invalid arguments). The callback is invoked
///   serially, once per event, with a NUL-terminated UTF-8 JSON string. The
///   pointer is only valid for the duration of the callback. After the final
///   `finish` event the callback is invoked once more with NULL to signal that
///   no further calls will occur (safe point to free `context`).
/// - `afmize_stream_cancel(id)` cancels a running stream. A `finish` event
///   (reason `other`) and the NULL sentinel are still delivered.
/// - `afmize_availability()` returns a heap-allocated JSON string; free it
///   with `afmize_string_free`.

public typealias AfmizeEventCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?
) -> Void

private struct CallbackBox: @unchecked Sendable {
    let context: UnsafeMutableRawPointer?
    let callback: AfmizeEventCallback
}

private let streamTasks = Mutex<[Int64: Task<Void, Never>]>([:])
private let streamIDCounter = Atomic<Int64>(0)

@_cdecl("afmize_availability")
public func afmize_availability() -> UnsafeMutablePointer<CChar>? {
    strdup(Afmize.availabilityJSON())
}

@_cdecl("afmize_string_free")
public func afmize_string_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}

@_cdecl("afmize_stream_start")
public func afmize_stream_start(
    _ requestJSON: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?,
    _ callback: AfmizeEventCallback?
) -> Int64 {
    guard let requestJSON, let callback else { return -1 }
    let json = String(cString: requestJSON)
    let box = CallbackBox(context: context, callback: callback)
    let id = streamIDCounter.wrappingAdd(1, ordering: .relaxed).newValue

    let task = Task.detached {
        await Afmize.run(requestJSON: json) { event in
            event.jsonString().withCString { box.callback(box.context, $0) }
        }
        box.callback(box.context, nil)
        _ = streamTasks.withLock { $0.removeValue(forKey: id) }
    }
    streamTasks.withLock { $0[id] = task }
    return id
}

@_cdecl("afmize_stream_cancel")
public func afmize_stream_cancel(_ id: Int64) {
    let task = streamTasks.withLock { $0[id] }
    task?.cancel()
}
