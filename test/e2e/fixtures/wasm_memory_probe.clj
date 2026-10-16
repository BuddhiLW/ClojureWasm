;; Linear-memory surface fixture (ADR-0192). Exercises the (ptr,len) calling
;; convention end to end: the host fills a buffer, the guest reads it, the guest
;; writes it back, the host reads the result. Asserted by
;; test/e2e/phase16_wasm_memory.sh.
(def m (wasm/load "test/e2e/fixtures/wasm/mem_kernel.wasm"))

;; The memory answers in BYTES (one 64 KiB page here), not in pages.
(println "size" (wasm/mem-size m))

;; Round trip through the guest: write 4 doubles, have the guest sum them,
;; have the guest scale them in place, read the scaled buffer back.
(println "wrote" (wasm/mem-write! m :f64 0 [1.0 2.0 3.0 4.0]))
(println "sum" (wasm/call m "sum_f64" 0 4))
(println "newsum" (wasm/call m "scale_f64" 0 4 2.5))
(println "scaled" (wasm/mem-read m :f64 0 4))

;; Every element type, over the same bytes. The f64 1.5 written at 64 reads
;; back as its little-endian bytes, which is the wasm memory model.
(wasm/mem-write! m :f64 64 [1.5])
(println "as-u8" (wasm/mem-read m :u8 64 8))

;; An i64 past the i48 immediate window must survive exactly. 9007199254740993
;; is 2^53+1, which is NOT representable as an f64 — so an equal round trip
;; proves the value did not pass through a float.
(wasm/mem-write! m :i64 128 [9007199254740993 -1])
(println "i64" (wasm/mem-read m :i64 128 2))
(println "i64-exact" (= 9007199254740993 (first (wasm/mem-read m :i64 128 1))))

;; Unsigned vs signed over identical bytes.
(wasm/mem-write! m :u32 200 [4294967295])
(println "u32" (wasm/mem-read m :u32 200 1) "i32" (wasm/mem-read m :i32 200 1))

;; Unaligned access is supported: a (ptr,len) ABI hands the host whatever
;; offset the guest's allocator produced.
(wasm/mem-write! m :f64 301 [7.25])
(println "unaligned" (wasm/mem-read m :f64 301 1))

;; Every failure is a CATCHABLE cljw exception naming the fn the user wrote,
;; never an internal_error and never a host panic on caller data.
(defn probe [label f]
  (println label (try (do (f) "NOT-CAUGHT") (catch Exception e (.getMessage e)))))

(probe "no-memory" #(wasm/mem-size (wasm/load "docs/examples/wasm/add.wasm")))
(probe "bad-handle" #(wasm/mem-size 42))
(probe "bad-dtype" #(wasm/mem-read m :f16 0 1))
(probe "bad-index" #(wasm/mem-read m :f64 1.5 1))
(probe "oob" #(wasm/mem-read m :f64 65530 1))
(probe "negative" #(wasm/mem-read m :f64 -8 1))
(probe "overflow" #(wasm/mem-read m :f64 0 9223372036854775807))
(probe "bad-data" #(wasm/mem-write! m :f64 0 "nope"))
(probe "bad-element" #(wasm/mem-write! m :i32 0 [1 :x 3]))
(probe "element-range" #(wasm/mem-write! m :u8 0 [1 300]))
(probe "element-fraction" #(wasm/mem-write! m :i32 0 [1.5]))

(println "DONE")
