# DCSS iOS Client (Playable MVP)

Independent iOS client for DCSS over WebSocket, implemented from scratch without GPL client source reuse.

## Stack

- Swift 6
- SwiftUI
- URLSessionWebSocketTask
- Actors for session state and lifecycle
- XCTest

## Structure

- `Sources/DCSSCore` - protocol codec, transport, session actor, storage.
- `Sources/DCSSApp` - SwiftUI app with Connect/Game/Settings screens.
- `Tests/DCSSCoreTests` - protocol/state/reconnect tests with fixtures.
- `Docs/ProtocolContract.md` - protocol contract and aliases.
- `Docs/iPhoneRunbook.md` - launch/run checklist for real iPhone.
- `Docs/AppStoreLegalChecklist.md` - legal/review checklist.

## Run tests

```bash
swift test
```

## Run on iPhone (Xcode USB)

1. Open `DCSSiOSHost.xcodeproj` in Xcode.
2. Select `DCSSiOSHost` scheme and your iPhone as target.
3. In target settings, set your Team in `Signing & Capabilities`.
4. Run and enter a real `wss://...` endpoint on Connect screen.

See detailed steps in `Docs/iPhoneRunbook.md`.
