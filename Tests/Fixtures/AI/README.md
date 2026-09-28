# Chat Completions fixtures

`chat-completions-fixtures.json` is a deterministic, in-process fixture registry for the provider-neutral contract in PRD section K.10. It covers successful Unicode/multiline responses, anonymous and authenticated requests, HTTP errors, transport failures, timeout/cancellation races, malformed response shapes, oversized output, control characters, and transcript prompt-injection data.

The authenticated case intentionally contains no credential. The client test injects an ephemeral test value and asserts that the exact `Authorization` value is sent once and never appears in logs, history, diagnostics, or fixture output.

The `responseTemplate` case is materialized by a test server as 65,537 ASCII bytes; it is not stored as a giant source file. Transport cases describe the deterministic server behavior because TLS and cross-origin redirect behavior require the integration harness.

`AI-MALFORMED-PROVIDER-ARTIFACT-CHANNEL` and `AI-MALFORMED-PROVIDER-ARTIFACT-CHANNEL-DELIMITED` separately capture trailing `<channel|>` and `<|channel|>` provider/runtime artifacts. The client must not silently strip or rewrite either payload; both fixtures treat the response as malformed and exercise exact raw-transcript fallback.
