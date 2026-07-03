# afmize

A Swift package that exposes Apple's FoundationModels SDK (macOS 27 / iOS 27) — both the
**on-device** model and **Private Cloud Compute** — to host applications such as a Tauri v2
app, on both macOS and iOS.

It speaks an [AI SDK](https://ai-sdk.dev)-flavored JSON protocol:

- **In:** `LanguageModelV3Message[]`-like transcripts (system/user/assistant/tool roles with
  text / file / reasoning / tool-call / tool-result parts) and
  `LanguageModelV3FunctionTool[]`-like tool definitions (name, description, JSON Schema input).
- **Out:** a realtime event stream (`text-delta`, `reasoning-delta`, `file`, `tool-call`,
  `error`, `finish` with usage).

Tools are **never executed in Swift**. When the model calls one or more tools, all tool calls
of the turn are emitted as `tool-call` events and the stream finishes with reason
`tool-calls`. The host app executes the tools and starts a **new** request with the tool-call
and tool-result parts appended to the message list.

## Requirements

- macOS 27 / iOS 27, Xcode 27 (FoundationModels SDK)
- Apple Intelligence enabled on the device for the on-device model; PCC eligibility for the
  cloud model. Check at runtime via `afmize_availability()` / `Afmize.availabilityJSON()`.

## API

### Swift

```swift
import afmize

// {"onDevice":{"available":true},"privateCloudCompute":{"available":false,"reason":"..."}}
let availability = Afmize.availabilityJSON()

for await eventJSON in Afmize.eventStream(requestJSON: requestJSON) {
    // each element is one event as a JSON string
}
```

### C FFI (for Rust / Tauri)

```c
// Heap-allocated JSON string; free with afmize_string_free.
char *afmize_availability(void);
void afmize_string_free(char *ptr);

// Starts a stream; returns a stream id (-1 on invalid arguments).
// The callback is invoked serially, once per event, with a NUL-terminated
// UTF-8 JSON string valid only for the duration of the call. After the final
// "finish" event the callback is invoked once more with NULL (no further
// calls will occur; safe point to free `context`).
typedef void (*afmize_event_callback)(void *context, const char *event_json);
int64_t afmize_stream_start(const char *request_json, void *context, afmize_event_callback callback);

// Cancels a running stream. A "finish" (reason "other") and the NULL sentinel
// are still delivered.
void afmize_stream_cancel(int64_t stream_id);
```

## Request JSON

```jsonc
{
  "model": "on-device",              // or "private-cloud-compute"
  "temperature": 0.7,                 // optional
  "maximumResponseTokens": 1024,      // optional
  "reasoningLevel": "moderate",       // optional: "light" | "moderate" | "deep" | custom string
  "toolChoice": "auto",               // optional: "auto" | "required" | "none"
  "tools": [                          // optional
    {
      "name": "get_weather",
      "description": "Get the current weather for a city.",
      "inputSchema": {                // JSON Schema
        "type": "object",
        "properties": { "city": { "type": "string" } },
        "required": ["city"]
      }
    }
  ],
  "messages": [
    { "role": "system", "parts": [{ "type": "text", "text": "Be concise." }] },
    { "role": "user", "parts": [
      { "type": "text", "text": "What's in this image and what's the weather in Paris?" },
      { "type": "file", "mediaType": "image/png", "data": "<base64 | data: URL | file:/http(s): URL>" }
    ]},

    // On subsequent turns, echo back what was streamed:
    { "role": "assistant", "parts": [
      { "type": "reasoning", "text": "..." },
      { "type": "text", "text": "..." },
      { "type": "tool-call", "toolCallId": "call-1", "toolName": "get_weather", "input": { "city": "Paris" } }
    ]},
    { "role": "tool", "parts": [
      { "type": "tool-result", "toolCallId": "call-1", "toolName": "get_weather",
        "output": { "type": "json", "value": { "temperatureCelsius": 21 } } }
    ]}
  ]
}
```

Notes:

- Only `image/*` file parts are supported (the FoundationModels transcript only accepts image
  attachments).
- If the last message is a `user` message it becomes the new prompt; otherwise (e.g. a
  trailing tool-result message) the model continues from the transcript.

## Event stream

Each event is a single JSON object. Order: `stream-start` first, `finish` last (exactly once).

| type | fields | meaning |
| --- | --- | --- |
| `stream-start` | — | stream opened |
| `text-delta` | `id`, `delta` | incremental response text |
| `text-replace` | `id`, `text` | full replacement of the text block (rare) |
| `reasoning-delta` | `id`, `delta` | incremental reasoning text (per reasoning block) |
| `reasoning-replace` | `id`, `text` | full replacement of a reasoning block (rare) |
| `file` | `mediaType`, `data` | file emitted by the model (base64 or URL) |
| `tool-call` | `toolCallId`, `toolName`, `input` | tool call; `input` is a JSON-encoded string |
| `error` | `code`, `message` | fatal error; followed by `finish` |
| `finish` | `finishReason`, `usage?` | `stop` \| `tool-calls` \| `error` \| `other` |

`usage` contains `inputTokens`, `cachedInputTokens`, `outputTokens`, `reasoningTokens`,
`totalTokens`.

Error codes include `model-unavailable`, `context-size-exceeded`, `rate-limited`,
`guardrail-violation`, `refusal`, `timeout`, `pcc-network-failure`, `pcc-quota-limit-reached`,
`pcc-service-unavailable`, `assets-unavailable`, `concurrent-requests`, `invalid-request`,
`unsupported-content`, and `unknown`.

## Using from a Tauri v2 app (macOS and iOS)

The same setup covers both platforms: link this package into the Rust core with
[`swift-rs`](https://crates.io/crates/swift-rs), declare the four C symbols, and forward
events to the webview over a Tauri channel. On macOS the Rust binary is the final link
product; on iOS the Rust static library and the Swift package are linked together into the
generated Xcode app — the same `extern "C"` symbols resolve in both cases.

### 1. Link the package (src-tauri/Cargo.toml + build.rs)

```toml
[build-dependencies]
swift-rs = { version = "1", features = ["build"] }
```

```rust
// src-tauri/build.rs
use swift_rs::SwiftLinker;

fn main() {
    SwiftLinker::new("27.0")            // macOS deployment target
        .with_ios("27.0")               // iOS deployment target
        .with_package("afmize", "../path/to/afmize") // path to this repo
        .link();
    tauri_build::build();
}
```

### 2. Declare the FFI and expose Tauri commands (src-tauri/src/lib.rs)

```rust
use std::ffi::{c_char, c_void, CStr, CString};
use tauri::ipc::Channel;

type EventCallback = unsafe extern "C" fn(*mut c_void, *const c_char);

unsafe extern "C" {
    fn afmize_availability() -> *mut c_char;
    fn afmize_string_free(ptr: *mut c_char);
    fn afmize_stream_start(
        request_json: *const c_char,
        context: *mut c_void,
        callback: EventCallback,
    ) -> i64;
    fn afmize_stream_cancel(stream_id: i64);
}

unsafe extern "C" fn on_event(context: *mut c_void, event_json: *const c_char) {
    if event_json.is_null() {
        // Terminal sentinel: reclaim the channel and stop.
        drop(unsafe { Box::from_raw(context as *mut Channel<serde_json::Value>) });
        return;
    }
    let channel = unsafe { &*(context as *const Channel<serde_json::Value>) };
    let json = unsafe { CStr::from_ptr(event_json) }.to_string_lossy();
    if let Ok(value) = serde_json::from_str(&json) {
        let _ = channel.send(value);
    }
}

#[tauri::command]
fn afm_availability() -> String {
    unsafe {
        let ptr = afmize_availability();
        let out = CStr::from_ptr(ptr).to_string_lossy().into_owned();
        afmize_string_free(ptr);
        out
    }
}

#[tauri::command]
fn afm_stream(request: serde_json::Value, on_event_channel: Channel<serde_json::Value>) -> i64 {
    let request = CString::new(request.to_string()).unwrap();
    let context = Box::into_raw(Box::new(on_event_channel)) as *mut c_void;
    unsafe { afmize_stream_start(request.as_ptr(), context, on_event) }
}

#[tauri::command]
fn afm_cancel(stream_id: i64) {
    unsafe { afmize_stream_cancel(stream_id) }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![afm_availability, afm_stream, afm_cancel])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
```

### 3. Call it from the webview

```ts
import { invoke, Channel } from "@tauri-apps/api/core";

const availability = JSON.parse(await invoke<string>("afm_availability"));

const events = new Channel<any>();
events.onmessage = (event) => {
  switch (event.type) {
    case "text-delta":      /* append event.delta */ break;
    case "reasoning-delta": /* append event.delta */ break;
    case "tool-call":       /* queue { toolCallId, toolName, input: JSON.parse(event.input) } */ break;
    case "error":           /* surface event.code / event.message */ break;
    case "finish":
      // event.finishReason === "tool-calls": run the queued tools, then
      // invoke("afm_stream") again with assistant tool-call parts and
      // tool role tool-result parts appended to `messages`.
      break;
  }
};

const streamId = await invoke<number>("afm_stream", {
  request: {
    model: "on-device",
    messages: [{ role: "user", parts: [{ type: "text", text: "Hello!" }] }],
  },
  onEventChannel: events,
});

// later, if needed:
await invoke("afm_cancel", { streamId });
```

### Platform notes

- **macOS:** nothing else — `swift-rs` compiles the package and links it (plus the Swift
  runtime and FoundationModels) into the Tauri binary.
- **iOS:** run `tauri ios init` / `tauri ios dev` as usual. The Rust staticlib built by cargo
  (which now embeds afmize) is linked into the generated Xcode project; no changes to
  `src-tauri/gen/apple` are required. Build with Xcode 27 against the iOS 27 SDK.
- The webview never talks to Swift directly; everything flows through the Rust commands, so
  the JS code is identical on both platforms.

## Development

```bash
swift build          # macOS build
swift test           # unit tests + live smoke tests (auto-skip without Apple Intelligence)
xcodebuild -scheme afmize -destination 'generic/platform=iOS' build   # iOS compile check
```
