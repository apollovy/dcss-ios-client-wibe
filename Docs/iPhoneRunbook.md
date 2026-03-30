# iPhone Runbook (Xcode USB)

## Preconditions

- macOS with Xcode 16+
- iPhone with Developer Mode enabled
- Apple ID configured in Xcode -> Settings -> Accounts
- Valid WebSocket endpoint (prefer `wss://...`)

## Build and run

1. Open package folder in Xcode (`File -> Open` and select project root).
2. Select `DCSSApp` executable target/scheme.
3. Connect iPhone via USB and trust this computer.
4. In `Signing & Capabilities`, set your Team for app signing.
5. Pick iPhone as run destination and press Run.

## Network notes

- For `wss://` endpoints, default ATS policy usually works.
- For `ws://` or custom TLS endpoints, add ATS exceptions in app `Info.plist`.

## Smoke checklist

- App opens and Connect screen is interactive.
- Enter real endpoint and tap Connect.
- Status becomes `connected` and "Last connected at" is populated.
- Game frame is visible on Game tab.
- Send a command and verify server responds.
- Toggle network (airplane mode on/off) and verify reconnect behavior.
- Put app background -> foreground and verify session recovery.
- Disconnect performs clean stop (state returns to idle).

## Debug hints

- Use diagnostics on Connect screen:
  - Last event
  - Reconnect attempt
  - Last error
  - Last connected at
- If connection fails, capture endpoint + last error text from the app.

