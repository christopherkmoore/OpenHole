# Session Management & Reconnection

## Status: Implemented

Most of this is now implemented. Key change from the original plan: we switched from one-shot (`echo ... | claude -p`) to a **persistent process model** (`tail -f .in | claude -p ... > .out`). This changes the reconnection story significantly.

## Context

Sessions are stored server-side at `~/.claude/projects/<project-dir>/<uuid>.jsonl`. Each file contains the full conversation as JSONL. We can list them, read their history, and resume any session with `claude -p --resume <uuid>`.

## Changes

### 1. Session List Model

**New file:** `OpenButt/Claude/SessionInfo.swift`

```swift
struct SessionInfo: Identifiable {
    let id: String          // UUID from filename
    let firstMessage: String // First user prompt (label)
    let lastTimestamp: Date
    let messageCount: Int
    let projectDir: String  // e.g. "-home-ckm"
}
```

Fetch via SSH command that scans the JSONL files:
```bash
for f in ~/.claude/projects/*/*.jsonl; do
  SID=$(basename "$f" .jsonl)
  FIRST=$(head -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("content","?")[:80])' 2>/dev/null)
  LAST=$(tail -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("timestamp","?"))' 2>/dev/null)
  LINES=$(wc -l < "$f")
  echo "$SID|$LINES|$LAST|$FIRST"
done
```

Parse output into `[SessionInfo]`, sorted by `lastTimestamp` descending.

### 2. Session Picker View

**New file:** `OpenButt/Views/Chat/SessionPickerView.swift`

- Presented as a sheet from the Chat toolbar (replace current "New Session" menu item)
- List of sessions showing: first message (truncated), timestamp, message count
- Tapping a session calls `session.resumeExistingSession(id:settings:)`
- "New Session" button at top to start fresh
- Pull-to-refresh to reload session list

### 3. Resume with History

**Modify:** `OpenButt/Claude/ClaudeSession.swift`

Add `resumeExistingSession(id:settings:)` that:
1. Sets `sessionId = id`
2. Loads conversation history from the JSONL file via SSH (`cat ~/.claude/projects/*/<id>.jsonl`)
3. Parses the JSONL to rebuild `messages` array (extract user prompts and assistant responses)
4. Sets `state = .ready` — no need to send an init probe since the session already exists
5. Stores the session ID in `AppSettings` so we remember which session we were in

Add `loadSessionHistory(id:)` that reads the JSONL, parses each line into a `ClaudeEvent`, and builds the `messages` array using the existing `handleLine()` logic.

### 4. Auto-Reconnect on Foreground

**Modify:** `OpenButt/App/ContentView.swift`

Current behavior (already partially implemented):
- `scenePhase` `.active` triggers `ensureConnected()` + `startSession()`

Change to:
- If we have a saved `sessionId` in settings, resume that session instead of starting a new one
- Only start a new session if there's no saved session ID
- `ensureConnected()` health check stays as-is

**Modify:** `OpenButt/App/AppSettings.swift`

Add `activeSessionId: String?` — persisted to keychain. Set when a session starts or is resumed. Cleared on explicit "New Session."

### 5. Session-Aware Reconnection in ClaudeSession

**Status:** Partially implemented. The persistent process model changes the reconnection story.

With the persistent process, reconnection is no longer free — the server-side process may have died if SSH dropped. Current behavior:
- Process runs with `nohup`, so it survives SSH disconnects
- Polling loop detects 10 consecutive SSH errors and sets state to `.error`
- On app foreground, `ensureConnected()` reconnects SSH
- If session state is `.error` or `.idle`, `startSession()` is called which resumes via `--resume`

**TODO:** Detect when the server-side process died during a disconnect and auto-restart it. Currently the user needs to trigger a reconnect manually if the process is gone.

### 6. Permission Mode Default

**Modify:** `OpenButt/App/AppSettings.swift` (already done)

Default `permissionMode` to `"plan"` since one-shot can't handle interactive approvals.

### 7. Thinking Block Fix

**Modify:** `OpenButt/Claude/ClaudeModels.swift` (already done)

`.ignored` case for `thinking`, `server_tool_use`, and other unknown block types.

## Files to Modify

| File | Change |
|------|--------|
| `Claude/SessionInfo.swift` | **New** — SessionInfo model |
| `Claude/ClaudeSession.swift` | Add resumeExistingSession, loadSessionHistory, update startSession to check saved session |
| `Views/Chat/SessionPickerView.swift` | **New** — session list UI |
| `Views/Chat/ChatView.swift` | Add session picker sheet trigger in toolbar |
| `App/ContentView.swift` | Already done — scenePhase reconnection |
| `App/AppSettings.swift` | Add activeSessionId, already done — permission mode default |
| `SSH/SSHConnectionManager.swift` | Already done — ensureConnected health check |
| `Claude/ClaudeModels.swift` | Already done — .ignored case |

## Verification

1. Start app, send a message — session created, chat works
2. Background app, wait 10s, foreground — auto-reconnects, can send another message in same session
3. Kill app entirely, reopen — reconnects and resumes previous session with message history
4. Open session picker — see list of all sessions on server
5. Tap an old session — loads its conversation history and can continue chatting
6. Start a new session — creates fresh session, old one still available in picker
