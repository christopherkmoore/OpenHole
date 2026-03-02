# Stream-JSON Reference

Captured from Claude Code 2.1.50.

## Command

```bash
claude -p --output-format stream-json --input-format stream-json --verbose
```

## Input Format (stdin, JSONL)

```json
{"type":"user","message":{"role":"user","content":"Say hello"},"session_id":"<session-id>"}
```

## Output Events (stdout, JSONL)

### 1. System Init

First message on every session start:

```json
{
  "type": "system",
  "subtype": "init",
  "cwd": "/home/ckm",
  "session_id": "794b629e-9e4d-40ec-9414-56823489c3f3",
  "tools": ["Task","Bash","Glob","Grep","Read","Edit","Write","NotebookEdit","WebFetch","WebSearch","AskUserQuestion","..."],
  "mcp_servers": [],
  "model": "claude-sonnet-4-6",
  "permissionMode": "default",
  "claude_code_version": "2.1.50",
  "agents": ["Bash","general-purpose","Explore","Plan"],
  "skills": ["debug","claude-developer-platform"],
  "fast_mode_state": "off"
}
```

### 2. Assistant Message

```json
{
  "type": "assistant",
  "message": {
    "id": "ed6cbb8e-3c99-4ffc-a975-d560ab48efc3",
    "model": "claude-sonnet-4-6",
    "role": "assistant",
    "stop_reason": "stop_sequence",
    "content": [
      {"type": "text", "text": "Hello! How can I help you?"},
      {"type": "tool_use", "id": "tool_123", "name": "Read", "input": {"file_path": "/path/to/file"}}
    ],
    "usage": {
      "input_tokens": 1234,
      "output_tokens": 567,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 0
    }
  },
  "session_id": "794b629e-...",
  "error": null
}
```

### 3. User (Tool Results)

```json
{
  "type": "user",
  "message": {
    "role": "user",
    "content": [
      {"type": "tool_result", "tool_use_id": "tool_123", "content": "file contents here"}
    ]
  },
  "session_id": "794b629e-..."
}
```

### 4. Result (Final)

Last message, summary of the session turn:

```json
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "duration_ms": 5432,
  "duration_api_ms": 4321,
  "num_turns": 3,
  "result": "I've made the changes...",
  "stop_reason": "end_turn",
  "session_id": "794b629e-...",
  "total_cost_usd": 0.0123,
  "usage": {
    "input_tokens": 5000,
    "output_tokens": 1000,
    "cache_creation_input_tokens": 0,
    "cache_read_input_tokens": 0
  },
  "permission_denials": [
    {
      "tool_name": "Write",
      "tool_use_id": "tool_456",
      "tool_input": {"file_path": "/path/to/file", "content": "..."}
    }
  ]
}
```

The `permission_denials` array is present when Claude attempted tools that weren't in
`--allowedTools`. Each entry identifies the tool, its call ID, and the input that was blocked.
This array is absent (or empty) when no tools were denied.

## Login Required

Claude Code requires `claude login` to be run interactively on the desktop (opens browser for OAuth). This is a one-time setup step.
