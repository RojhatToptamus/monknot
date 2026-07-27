# Local Typing Assistance

Flow is Monknot's optional, entirely local writing-assistance path. It is
disabled by default and is currently an integration research surface, not a
production-readiness claim.

## Current behavior

- A small explicit typo map can correct a completed word after the user enables
  automatic word corrections.
- A 350 ms pause can request a grammar correction.
- Suggestions require explicit acceptance with Tab or the checkmark button.
- Escape or the dismiss button rejects a suggestion.
- Phrase completion is disabled.
- HTML source, code-like boundaries, fenced code, and shell-prompt lines do not
  receive automatic word corrections.
- Undo restores both accepted suggestions and automatic word corrections.

The editor binds every suggestion to the exact document, revision, text, caret,
and selection state that produced it. New typing, selection movement, document
switches, and stale responses invalidate the suggestion. Inference never runs
on the active typing path, model concurrency is limited to one, unrelated
requests are not batched, and every fallback leaves editor text unchanged.

## Local runtime

The current research profile uses:

```text
Endpoint:   http://127.0.0.1:11434
Model:      qwen3:4b-instruct-2507-q4_K_M
Context:    2048 tokens
keep_alive: 5m
```

The runtime accepts only HTTP loopback hosts (`127.0.0.1`, `localhost`, or
`::1`). Monknot does not store a provider key, contact a remote inference
service, or bundle the model. Ollama and the named local model must already be
installed. If the model is unloaded, Monknot returns no suggestion immediately
and warms it in the background. Probe failures and foreground or background
timeouts also return no suggestion.

## Release status

The current Qwen profile is a failed research baseline, not an approved product
model. Flow remains off by default while model selection, independent target
review, and representative opt-in user traces are incomplete. Completion stays
disabled until a separate completion-quality gate passes.
