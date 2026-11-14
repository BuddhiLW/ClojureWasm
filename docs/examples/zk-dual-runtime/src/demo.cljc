;; The shared program. Identical text on both runtimes.
;;
;; It never names cljrs or cljw, and never names Wasm or a dylib. It calls
;; zk/compute, zk/prove, zk/verify and zk/ambient, and each runtime is
;; responsible for making that namespace exist:
;;
;;   cljrs : a native dylib registers `zk` at startup (cljrs.edn :rust)
;;   cljw  : cljw/run.clj defines `zk` over a Wasm component
;;
;; So the Rust library is the same, the Clojure is the same, and the only thing
;; that differs is how much authority the prover holds while it runs.

(def secret 3)
(def seed (vec (repeat 32 7)))

(defn run []
  (let [y (zk/compute secret)]
    (println "public statement : x^3 + x + 5 ==" y)
    (println "secret witness   : x =" secret)

    (let [proof (zk/prove secret seed)
          verified (zk/verify proof y seed)
          rejected (zk/verify proof 36 seed)]
      (assert (= 35 y))
      (assert (= 128 (count proof)))
      (assert (true? verified))
      (assert (false? rejected))
      (println "proof            :" (count proof) "bytes")
      (println "verify true  y =" y "->" verified)
      (println "verify false y = 36 ->" rejected))

    (println "\nambient authority held by the prover:")
    (doseq [line (zk/ambient)]
      (println "  " line))))

(run)
