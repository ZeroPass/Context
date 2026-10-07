# Context Agent Instructions

## Whiteboard

- `wb.md` is an alias for `whiteboard.md` in this project's root directory,
  not a request to create a file named `wb.md`.
- When the user asks for `wb.md` or to throw/publish an answer on the whiteboard,
  read `whiteboard.md`'s initial instructions and publish only the requested final
  Markdown output. `wb.md` alone means the preceding completed answer. Mere
  discussion of implementing Whiteboard is not a publication request.
- Use `scripts/publish-whiteboard` (Linux/WSL) or `scripts/publish-whiteboard.ps1`
  (Windows), sending the final output on stdin. Do not append/edit blocks by hand.
  The helper preserves instructions and surviving output, serializes writers,
  and removes all entries older than the newest three plus unframed debris.
- Do not claim publication unless the helper succeeds. Never publish thinking
  traces, tool logs, credentials, or unrelated private data.

## Local Data

- `codex sessions.md`, `whiteboard.md`, locks, and temporary files are private
  local data. Keep them out of commits, build staging, and APPX payloads.
- Do not infer provider homes or credentials from a specific Markdown filename.
