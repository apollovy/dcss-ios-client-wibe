# DCSS iOS Client (MVP)

Independent iOS client for DCSS over WebSocket, implemented from scratch without GPL client source reuse.

## Stack

- Swift 6
- SwiftUI
- URLSessionWebSocketTask
- Actors for session state
- XCTest

## Structure

- `Sources/DCSSCore` - protocol codec, transport, session actor, storage.
- `Sources/DCSSApp` - SwiftUI app with Connect/Game/Settings screens.
- `Tests/DCSSCoreTests` - protocol/state/reconnect tests with fixtures.
- `Docs/ProtocolContract.md` - protocol contract.
- `Docs/AppStoreLegalChecklist.md` - legal/review checklist.

## Run tests

```bash
swift test
```
