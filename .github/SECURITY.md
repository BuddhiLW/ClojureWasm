# Security Policy

> [!IMPORTANT]
> **ClojureWasm is no longer maintained, and no version is supported. There
> will be no security fixes, including for critical vulnerabilities.**
>
> Do not deploy `cljw` where it is exposed to untrusted input. If you already
> have, treat the migration off it as the fix — waiting for a patch here is
> waiting for something that will not come.
>
> The rest of this document is kept because the threat model and the scope
> boundaries are still accurate, and are the right starting point for anyone
> forking the project. **A fork takes on its own security policy**; this one no
> longer speaks for it.

ClojureWasm (`cljw`) is a Clojure runtime with a **WebAssembly FFI**: it can
load and execute **untrusted `.wasm` bytecode** in the same process as the host
(through the embedded zwasm engine), and — in embeddings that accept
user-submitted code, as the now-retired public playground did — it evaluates
**untrusted Clojure source** in-process. Memory safety and sandbox integrity
are therefore first-class concerns for anyone running it.

## Supported versions

**None.** The project stopped at v1.10.1; there is no supported line, no
backport branch, and nothing that will be cut from `main`.

| Version                 | Supported |
|-------------------------|-----------|
| `main`                  | ❌        |
| v1.10.1 (final release) | ❌        |
| any earlier release     | ❌        |

Note that the embedded WebAssembly engine, **zwasm**, is a separate project and
[continues under its own maintainership](https://github.com/zwasm/zwasm) — a
vulnerability in the engine should go there, and is worth reporting because that
project can still act on it. What is unmaintained is `cljw`'s own runtime and
the specific zwasm version this project pinned.

## Reporting a vulnerability

Reports about `cljw` itself will not be acted on. If you find something anyway
and want it recorded for the benefit of anyone forking the project, the channel
below still exists — but expect no fix and no timeline.

**Please do not open a public Discussion for security problems.**

Report privately via GitHub's **[Private Vulnerability Reporting](https://github.com/clojurewasm/ClojureWasm/security/advisories/new)**
(the "Report a vulnerability" button under the repository's *Security* tab).
If that is unavailable to you, open a minimal public Discussion asking a
maintainer to reach out — **without any exploit detail** — and mention
`@chaploud`.

Please include, where possible:

- affected version / commit and target (`aarch64-macos`, `x86_64-linux`) and
  execution mode (interpreter / JIT / AOT for the Wasm FFI);
- a minimal reproducer — a `.clj` expression, or a `.wasm` / `.wat` module and
  the exact CLI / embedding call;
- the observed impact (host memory corruption, Wasm sandbox escape, WASI
  capability bypass, denial of service, etc.).

There is no acknowledgement window and no fix window; see the notice at the top.
You are under no obligation to delay disclosure on this project's behalf.

## Scope

The boundaries below describe what *would* have counted as a vulnerability in
`cljw`. They are retained as a threat model for forks, not as an active offer.

In scope: host memory corruption from a malformed or adversarial `.wasm`
module, Wasm sandbox / WASI-capability escapes, JIT code-generation bugs with a
security impact, and memory-safety faults in the Zig runtime reachable from
ordinary Clojure input.

Out of scope: behaviour of untrusted guest code that stays *within* the Wasm
sandbox, resource exhaustion by trusted local scripts you run yourself, and
misuse of the embedding API in ways the documentation warns against.
