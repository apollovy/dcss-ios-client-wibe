# DCSS WebSocket Protocol Contract (MVP)

This document captures the app-side protocol contract used by this project.

## Outgoing commands

- `handshake`
  - payload: `clientVersion`
- `input`
  - payload: `command`
- `heartbeat`
  - payload: empty

## Incoming events

- `hello`
  - payload: `serverVersion`
- `frame`
  - payload: `grid` (newline-separated rows), `statusLine`
- `message`
  - payload: `text`
- `heartbeat_ack`
  - payload: empty
- `error`
  - payload: `code`, `text`

## Error and reconnect semantics

- Decode/parsing errors set session state to `failed`.
- Socket read/send failures trigger reconnect with exponential backoff.
- Reconnect attempts are capped by policy (`maxAttempts`).

## Background/foreground behavior

- In MVP, app keeps explicit connect/disconnect controls.
- Next step: automatic suspend/resume hooks via scene phase transitions.
