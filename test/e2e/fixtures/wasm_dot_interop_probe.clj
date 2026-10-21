;; Dot-interop on a core wasm module handle (ADR-0203 decision 2). Every
;; method-call form on a `wasm_module` value is `wasm/call` with the method
;; symbol's name as the export name, verbatim. Asserted by
;; test/e2e/phase16_wasm_dot_interop.sh.
(def h (wasm/load "docs/examples/wasm/add.wasm"))
(println "dot-method" (.add h 40 2))
(println "dot-form" (. h add 40 2))
(println "dot-list" (. h (add 40 2)))
(println "same-as-call" (= (.add h 40 2) (wasm/call h "add" 40 2)))

;; A C kernel: the export name `sum_f64` works as written (no munging), and the
;; buffer comes from the guest's own allocator.
(def m (wasm/load "docs/examples/polyglot/c/kernel.wasm"))
(def buf (wasm/call m "buf_addr"))
(wasm/mem-write! m :f64 buf [1.0 2.0 3.0 4.0])
(println "c-sum" (.sum_f64 m buf 4))
(println "c-scale" (.scale_f64 m buf 4 2.0) (.sum_f64 m buf 4))

(defn msg [f]
  (try (f) "NOT-RAISED" (catch Throwable e (.getMessage e))))

;; A missing export and a trap raise exactly what wasm/call raises.
(println "missing-same" (= (msg #(.nope h 1)) (msg #(wasm/call h "nope" 1))))
(println "missing" (msg #(.nope h 1)))
(println "arity" (msg #(.add h 1)))
(def t (wasm/load "docs/examples/wasm/trap.wasm"))
(println "trap-same" (= (msg #(.boom t)) (msg #(wasm/call t "boom"))))
(println "trap" (msg #(.boom t)))

;; Non-wasm receivers are unchanged.
(println "string" (.toUpperCase "abc"))
(println "nonwasm" (msg #(.add 42 1)))
(println "DONE")
