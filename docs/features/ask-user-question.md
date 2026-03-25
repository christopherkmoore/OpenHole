# AskUserQuestion — Interactive Question Feature

## Goal
When Claude calls the `AskUserQuestion` tool (e.g. to ask Which approach should I take?), the iOS app should show a tappable card with the question and options instead of a generic permission approval banner. The user taps an option, and Claude continues with that answer.

## Current Status
**Partially implemented but broken.** The QuestionCard UI exists and displays correctly. The fundamental issue is that Claude Code auto-rejects `AskUserQuestion` in `-p` mode before the app can intercept it, so the answer never reaches Claude as a proper tool result.

## How AskUserQuestion Works (Claude Code Source)

Located in `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js` (v2.0.35).

### Tool Definition
```js
DtA = {
  name: "AskUserQuestion",
  isReadOnly: () => true,
  requiresUserInteraction: () => true,
  checkPermissions: async (A) => ({
    behavior: "ask",          // always "ask" — never auto-allow
    message: "Answer questions?",
    updatedInput: A
  }),
  async *call({ questions, answers = {} }, Q) {
    yield { type: "result", data: { questions, answers } }
  },
  mapToolResultToToolResultBlockParam({ answers }, B) {
    return {
      type: "tool_result",
      content: `User has answered your questions: ${
        Object.entries(answers).map(([I, G]) => `"${I}"="${G}"`).join(", ")
      }. You can now continue with the user's answers in mind.`,
      tool_use_id: B
    }
  }
}
```

### Input Schema
```js
{
  questions: Array<{
    question: string,   // full question text ending in "?"
    header: string,     // short chip label (max 12 chars)
    options: Array<{
      label: string,       // concise 1-5 word choice
      description: string  // explanation of the option
    }>,                 // min 2, max 4 options
    multiSelect: boolean
  }>,                   // min 1, max 4 questions
  answers?: Record<string, string>  // question text → answer string
}
```

**Note:** An "Other" free-text option is always added by the UI — callers should not include it.

## The Correct Mechanism: `control_request` / `control_response`

### How it works
Claude Code uses a transport-level protocol for interactive tool permission decisions:

1. Claude calls `AskUserQuestion` with `{ questions: [...] }`
2. Claude Code emits a `control_request` event to its output stream:
   ```json
   {
     "type": "control_request",
     "request_id": "<uuid>",
     "request": {
       "subtype": "can_use_tool",
       "tool_name": "AskUserQuestion",
       "input": { "questions": [...] },
       "tool_use_id": "<tool_use_id>",
       "permission_suggestions": [...]
     }
   }
   ```
3. Claude Code **waits** (does not emit `result`) for a `control_response` on its input stream
4. The host app sends back:
   ```json
   {
     "type": "control_response",
     "response": {
       "subtype": "success",
       "request_id": "<matching uuid from control_request>",
       "response": {
         "behavior": "allow",
         "updatedInput": {
           "questions": [...original questions...],
           "answers": { "Which approach should I take?": "Option A" }
         }
       }
     }
   }
   ```
5. Claude Code calls the tool with the updated input (including answers)
6. Tool produces a clean `tool_result`: "User has answered your questions: 'Which approach'='Option A'..."
7. Claude continues with proper context

### When this mechanism is active
The `control_request`/`control_response` protocol is ONLY active when:
- `--sdk-url ws://localhost:<port>` flag is passed to Claude Code

This flag causes Claude Code to use a WebSocket connection instead of stdio. Internally it sets `permissionPromptTool = "stdio"` which enables the control_request path.

**Without `--sdk-url`:** Claude Code auto-denies `AskUserQuestion` (and all `requiresUserInteraction` tools) in `-p` mode.

### `--permission-prompt-tool stdio` does NOT work
We investigated passing `--permission-prompt-tool stdio` to set `permissionPromptTool` without `--sdk-url`. This fails because the flag only accepts real MCP tool names — passing stdio triggers:
> `Error: MCP tool stdio (passed via --permission-prompt-tool) not found`

## Current (Broken) Implementation

### What's in place
- `ClaudeSession.buildCommand`: AskUserQuestion excluded from `--allowedTools`
- `ClaudeSession.handleLine` (result event): AskUserQuestion filtered from `permissionDenials`, tool left as `.running`
- `QuestionCard` in `ToolCallCard.swift`: parses and displays the question with tappable options
- `MessageBubble.swift`: routes AskUserQuestion with status `.running` to `QuestionCard`
- `ClaudeSession.answerQuestion`: sends user's tap as a plain user message to Claude

### Why it's broken
1. Claude Code auto-denies AskUserQuestion in `-p` mode before we can intercept
2. The `result` event fires immediately (Claude Code exits this "turn")
3. We suppress the denial but the tool never actually ran — Claude got no `tool_result`
4. `answerQuestion` sends a plain user message: Claude may understand from context but it's unreliable
5. No proper `tool_result` means Claude doesn't get structured answer data

## Implementation Plan: WebSocket Bridge

To use the correct mechanism, we need `--sdk-url`. Since Claude Code's WebSocket transport is its only way to use control_request, we need a bridge that:

1. Runs a WebSocket server on localhost
2. Starts Claude with `--sdk-url ws://localhost:<port>`
3. Bridges the WebSocket I/O ↔ our existing `.in`/`.out` file-based pipeline

### Bridge Architecture
Replace the current pipeline:
```
tail -f .in | claude -p ... > .out
```
With:
```
tail -f .in | node ~/open-butt-ws-bridge.js -p ... > .out
```

The bridge script (`open-butt-ws-bridge.js`):
- Uses only Node.js built-ins (`http`, `crypto`, `net`) — no npm install needed
- Starts an HTTP server with WebSocket upgrade support
- Starts Claude as a child process with `--sdk-url ws://localhost:<port>`
- Forwards: WebSocket frames → stdout (our `.out` file)
- Forwards: stdin lines (from `tail -f .in`) → WebSocket frames

### Changes Required
1. **Create** `~/open-butt-ws-bridge.js` on Mac — pure Node.js WS bridge
2. **`ClaudeModels.swift`** — Add `ControlRequestEvent` struct, `.controlRequest` case to `ClaudeEvent`
3. **`ClaudeStreamParser.swift`** — Handle `"control_request"` type
4. **`ClaudeSession.swift`**:
   - `@Published var pendingControlRequests: [String: ControlRequestEvent] = [:]`
   - Handle `.controlRequest` event: store by `tool_use_id`
   - `answerQuestion`: if pending control request exists for `toolCallId`, send `control_response`; else fallback to plain message
   - `buildCommand`: use `node ~/open-butt-ws-bridge.js` prefix instead of `claude`
   - Remove AskUserQuestion denial suppression from result handler
   - Update `isAwaitingQuestion`: `!pendingControlRequests.isEmpty`
   - Clear `pendingControlRequests` on session clear/new session

### Pure Node.js WebSocket Bridge (no npm)
```js
#!/usr/bin/env node
// open-butt-ws-bridge.js
// Usage: tail -f .in | node this.js <claude-args...> > .out
const http = require('http');
const crypto = require('crypto');
const { spawn } = require('child_process');
const readline = require('readline');

const server = http.createServer();

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  const accept = crypto.createHash('sha1')
    .update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
  );

  // WebSocket → stdout (our .out file)
  socket.on('data', (buf) => {
    parseFrames(buf).forEach(msg => process.stdout.write(msg + '\n'));
  });

  // stdin lines (from tail -f .in) → WebSocket
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', (line) => sendFrame(socket, line));

  socket.on('error', () => {});
  socket.on('close', () => process.exit(0));
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  const args = [...process.argv.slice(2), '--sdk-url', `ws://127.0.0.1:${port}`];
  const claude = spawn('claude', args, { stdio: 'ignore' });
  claude.on('exit', () => process.exit(0));
});

function parseFrames(buf) {
  const msgs = [];
  let offset = 0;
  while (offset + 2 <= buf.length) {
    const opcode = buf[offset] & 0x0f;
    const masked = !!(buf[offset + 1] & 0x80);
    let len = buf[offset + 1] & 0x7f;
    offset += 2;
    if (len === 126) { len = buf.readUInt16BE(offset); offset += 2; }
    else if (len === 127) { len = Number(buf.readBigUInt64BE(offset)); offset += 8; }
    let mask;
    if (masked) { mask = buf.slice(offset, offset + 4); offset += 4; }
    const payload = buf.slice(offset, offset + len);
    offset += len;
    if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
    if (opcode === 1) msgs.push(payload.toString('utf8'));
  }
  return msgs;
}

function sendFrame(socket, text) {
  const payload = Buffer.from(text, 'utf8');
  const len = payload.length;
  let header;
  if (len <= 125) { header = Buffer.from([0x81, len]); }
  else if (len <= 65535) { header = Buffer.alloc(4); header[0]=0x81; header[1]=126; header.writeUInt16BE(len,2); }
  else { header = Buffer.alloc(10); header[0]=0x81; header[1]=127; header.writeBigUInt64BE(BigInt(len),2); }
  socket.write(Buffer.concat([header, payload]));
}
```

## Files Changed So Far
- `ios/OpenHole/Claude/ClaudeSession.swift` — denial suppression, answerQuestion, isAwaitingQuestion
- `ios/OpenHole/Views/Chat/ToolCallCard.swift` — QuestionCard struct
- `ios/OpenHole/Views/Chat/MessageBubble.swift` — routes to QuestionCard
- `ios/OpenHole/Views/Chat/ChatView.swift` — "Waiting for your answer..." status bar text
- `ios/OpenHole/Views/Chat/InputBar.swift` — keyboard dismiss on send

## References
- Claude Code source: `/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js`
- `control_request` subtype `can_use_tool` with `tool_use_id`, `tool_name`, `input`
- `control_response` with `behavior: "allow"`, `updatedInput.answers: { questionText: answerLabel }`
- WebSocket bridge uses pure Node.js built-ins (no npm)
