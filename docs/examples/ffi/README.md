# C FFI: call a shared library from cljw

`cljw.ffi` opens a shared library with `dlopen` and turns a C symbol into an
ordinary Clojure fn. No libffi, no binding generator, no rebuild of cljw.

```clojure
(require '[cljw.ffi :as ffi])

(def libm (ffi/open "libm.so.6"))
(def pow (ffi/function libm "pow" [:double :double] :double))
(pow 2.0 10.0)   ;=> 1024.0
(map pow [2 3] [3 2])   ;=> (8.0 9.0)
```

| fn | does |
|---|---|
| `(open path)` | library handle; absolute, relative or bare soname |
| `(close lib)` | nil, idempotent; its functions then throw `{:ffi/error :closed}` |
| `(sym lib name)` | symbol address as an integer |
| `(function lib name arg-types ret-type)` | a Clojure fn; types resolved once |
| `(call lib name arg-types ret-type & args)` | one-shot call |
| `(string ptr)` | copy a NUL-terminated C string; 0 or nil gives nil |
| `(bytes ptr n)` | copy `n` bytes into a byte array |

Types: `:void` (return only), `:int` (C int), `:long` (int64), `:double`,
`:pointer` (address as integer, nil is NULL), `:string` (a copy both ways,
NULL is nil, a returned string is never freed), `:bytes` (argument only, a
copy of a byte array).

Limits: at most 6 integer-class and 8 `:double` arguments, no varargs
(`printf`), no structs by value, no `float`. Available on x86_64 and aarch64,
Linux and macOS; absent on wasm targets (`-Dffi=false` drops it from a build).
Failures are `ex-info` with `{:ffi/error :open|:symbol|:signature|:arity|:arg-type|:closed}`.

The same API ships in clojurust as `clojure.rust.ffi`, so a portable adapter
is one reader conditional:

```clojure
(:require #?(:cljw [cljw.ffi :as ffi] :rust [clojure.rust.ffi :as ffi]))
```

## The hive C ABI

[`hive_call.clj`](./hive_call.clj) drives any library that exports
`hive_call(op, json) -> char*` and `hive_free`: a Go c-shared, Rust cdylib,
C or Zig library alike.

```sh
cljw -M docs/examples/ffi/hive_call.clj /path/to/libvectorcraft.so ops
# {:ok true, :value [{:doc "Execute an engine command ...", :name "engine.execute", ...} ...]}
```
