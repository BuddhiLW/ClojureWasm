;; CLJW-WASM-INTERP-THREAD-TRAP: a handle warmed on the runtime thread must
;; still run when the next call comes from another thread (future / agent).
;; zwasm's interp cached the FIRST caller thread's native-stack low limit on
;; the instance's Runtime, so a later call from a thread whose stack sits
;; below that limit trapped CallStackExhausted.
(defn call [h] (try (wasm/call h "add" 2 3) (catch Throwable e (str "TRAPPED " (ex-message e)))))

(doseq [engine [:interp :jit :auto]
        warm [1 5000]]
  (let [h (wasm/load "bench/wasm/ffi/add.wasm" {:engine engine :fuel 0})]
    (dotimes [_ warm] (call h))
    (println (str "hop " (name engine) " " warm ": " @(future (call h))))
    ;; and back on the runtime thread after the worker ran
    (println (str "back " (name engine) " " warm ": " (call h)))))

;; first call on a worker, then on the runtime thread
(let [h (wasm/load "bench/wasm/ffi/add.wasm" {:engine :interp :fuel 0})]
  (println (str "worker-first interp: " @(future (call h)) " " (call h))))

(println "DONE")
