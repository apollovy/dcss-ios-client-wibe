# DCSS WebSocket Protocol Contract (Playable MVP)

This document captures the app-side wire contract for a playable iPhone build.

## Outgoing commands

- `handshake`
  - payload: `clientVersion`
- `input`
  - payload: `command`
- `heartbeat`
  - payload: empty

## Incoming events (supported aliases)

- `hello` or `welcome`
  - payload: `serverVersion` or `version`
- `frame` or `update`
  - payload variants:
    - `grid` (newline-separated rows) + `statusLine`
    - `gridRows` (array of strings) + `status`
- `message` or `msg`
  - payload: `text` or `message`
- `heartbeat_ack` or `pong`
- `heartbeat` or `ping`
- `error`
  - payload: `code`, `text`/`message`

## Compatibility mode

If endpoint sends flattened JSON (without `{ type, payload }` envelope), codec falls back to:

- `type` from `type` field, or from `msg` field
- payload from the whole event object

## Reconnect and lifecycle semantics

- Socket read/send failures trigger reconnect with exponential backoff.
- Reconnect attempts are capped by `ReconnectPolicy.maxAttempts`.
- On app background:
  - receive loop is cancelled
  - socket is disconnected
  - connected state transitions to `idle`
- On app foreground:
  - actor reconnects using last successful endpoint

## Diagnostics exported by SessionActor

- `lastEventType`
- `reconnectAttempt`
- `lastError`
- `lastConnectedAt`
