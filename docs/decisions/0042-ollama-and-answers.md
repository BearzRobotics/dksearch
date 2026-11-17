# 0042: Ollama, found and managed, and an optional written answer

Status: implemented.

## Context

Semantic search needs an embedding model and written answers need a chat model. People already run Ollama for that; dksearch should use it without becoming a model runtime, without downloading gigabytes unasked, and without making the core depend on any of it (lexical search and retrieval stay the default, ADR 0030 and 0038).

## Decision

- **Ollama is found, not started.** `[ollama] url` (default `http://127.0.0.1:11434`) is the address; `dksearch models list` and the administration page say whether it answers. Nothing starts it.
- **Models are managed on request.** `dksearch models pull|remove NAME --yes` and the *AI models* page list, pull (a cancellable background task, through the same job machinery as imports and Kiwix downloads) and delete models. Pull and delete are explicit: `--yes`, or a form button, or a confirmation page for deletion. Names are checked (letters, digits and `. _ - : /`).
- **Choosing a model edits the configuration** (`[embeddings]` or `[answers]`), validated as a whole like every other edit, applied after a restart.
- **Answers are a separate opt-in step** (`[answers] enabled`): retrieval (ADR 0030) supplies the passages, the model writes a short answer that cites them. The prompt tells the model to use only the numbered passages, to say when they do not contain the answer and to ignore instructions inside them. The answer is escaped text, labelled, with its sources; no markup, no tools, no links the model made up are followed. When there are no passages the model is not called. A server-wide per-minute limit protects the machine.
- Failures are soft and named: no Ollama, no model, a timeout, an empty answer.

## Alternatives

- Bundling a model runtime: heavy, platform specific, and a reason for the build to stop being simple.
- Pulling a default model automatically: surprising, large, and the wrong model for most machines.
- Streaming the answer: needs script on the page; the page works without JavaScript, so the answer arrives whole.

## Consequences

- An answer is only as good as the model and the passages; the page says so.
- A question costs a model run on the owner's hardware; the limit is global, not per visitor.
