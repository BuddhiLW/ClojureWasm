# Security Policy

ClojureWasm (`cljw`) is a Clojure runtime with a **WebAssembly FFI**: it can
load and execute **untrusted `.wasm` bytecode** in the same process as the host
(through the embedded zwasm engine), and — in embeddings like the public
playground — it evaluates **untrusted Clojure source** in-process. Memory
safety and sandbox integrity are therefore first-class concerns, and we take
reports seriously.

## Supported versions

Security fixes land on the `main` branch and in the next release cut from it.
Only the newest release line is supported — this is a small project and there
is no backport branch.

| Version                        | Supported |
|--------------------------------|-----------|
| `main`                         | ✅        |
| newest `1.x` release           | ✅        |
| any older release              | ❌        |

If you are on Homebrew, `brew upgrade buddhilw/tap/cljw` puts you on the
supported line.

## Reporting a vulnerability

**Please do not open a public issue or Discussion for security problems.**

Report privately via GitHub's **[Private Vulnerability Reporting](https://github.com/BuddhiLW/ClojureWasm/security/advisories/new)**
(the "Report a vulnerability" button under the repository's *Security* tab).
If that is unavailable to you, open a minimal public Discussion asking a
maintainer to reach out — **without any exploit detail** — and mention
`@BuddhiLW`.

Please include, where possible:

- affected version / commit and target (`aarch64-macos`, `x86_64-linux`) and
  execution mode (interpreter / JIT / AOT for the Wasm FFI);
- a minimal reproducer — a `.clj` expression, or a `.wasm` / `.wat` module and
  the exact CLI / embedding call;
- the observed impact (host memory corruption, Wasm sandbox escape, WASI
  capability bypass, denial of service, etc.).

We aim to acknowledge a report within a few days. Because this is a small,
resource-limited project, please allow reasonable time for a fix before any
public disclosure.

## Scope

In scope: host memory corruption from a malformed or adversarial `.wasm`
module, Wasm sandbox / WASI-capability escapes, JIT code-generation bugs with a
security impact, and memory-safety faults in the Zig runtime reachable from
ordinary Clojure input.

Out of scope: behaviour of untrusted guest code that stays *within* the Wasm
sandbox, resource exhaustion by trusted local scripts you run yourself, and
misuse of the embedding API in ways the documentation warns against.
