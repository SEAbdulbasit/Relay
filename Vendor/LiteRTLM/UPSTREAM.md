# LiteRT-LM Swift wrapper provenance

Unmodified Swift wrapper source from Google AI Edge LiteRT-LM v0.18.1, commit `bda624851d74be34d4e1f7fac1fc4155939539c7`.

Upstream: https://github.com/google-ai-edge/LiteRT-LM/tree/v0.18.1/swift

Copyright Google LLC and other upstream authors; Apache-2.0, see LICENSE. Only production top-level Swift files are vendored; tests, examples and Apple Foundation Models adapter are excluded.

The local package manifest is Relay-specific. It uses the original official macOS binary release and original SHA-256 checksum, excluding the unused iOS binary and avoiding a multi-gigabyte all-history repository fetch.

No local model weights are included.

`Sources/LiteRTLM/RelayActionTool.swift` is an original Relay schema-only bridge, not upstream code. It lives in this non-main-isolated module because Swift's property-wrapper tool protocol is incompatible with the application target's default main actor isolation. The 13 upstream production files remain unmodified.

The Relay-owned bridge advertises concrete native schemas for the 12 executor actions plus the harmless capability probe. It does not use an action wrapper or JSON-inside-JSON arguments. A schema-parity regression test compares function names, property names/types and required keys with the executor definitions. All bridge `run()` methods throw; SDK automatic execution remains disabled.
