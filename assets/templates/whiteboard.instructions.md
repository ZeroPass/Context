<!-- context:whiteboard:instructions:v1
Context Whiteboard - instructions for agents

Canonical file: {{WHITEBOARD_PATH}}
Alias: wb.md means THIS whiteboard.md at THIS location. Do not create wb.md.
When the user says wb.md or asks to throw/publish an answer on the whiteboard,
publish the requested final output here. If the user says only wb.md, publish
the preceding completed answer. Discussion about implementing wb.md is not
itself a request to publish. Do not publish automatically after other replies.

Publish only the actual final Markdown output, not thinking, tool traces,
terminal logs, or an extra summary of the output. Keep links and file paths.
Never edit surviving entries or this header. Use the publishing helper; it
serializes concurrent writes, appends the new output, removes ALL entries older
than the newest three, and cleans unframed debris. Do not append by hand.

Helper: {{PUBLISH_COMMAND}}
Pass --title "Short description" and optionally --provider codex/kimi/opencode/qwen.
Send the final output on standard input (a quoted heredoc is suitable). The
helper records your working directory for relative-file previews. Successful
publication is a JSON acknowledgement; do not claim publication after failure.
Do not include account credentials, tokens, or unrelated private data.
-->
<!-- context:whiteboard:header-end -->
