;; The committed arkworks guest crosses the real component boundary. A wrong
;; public input must fail verification; an always-true verifier cannot pass.
;; Proving is too slow for the shared smoke suite. Registered as test_clj_zk
;; in test/run_all.sh and tagged slow in test/units.list.
(ns zk-examples-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing run-tests]]))

(def ^:private fixture "test/e2e/fixtures/wasm/zk_groth16.component.wasm")
(def ^:private iface "hive:zk-groth16/tools@0.1.0#")

(deftest groth16-proof-and-trap-isolation
  (let [h (wasm/load-component fixture)
        call (fn [f & args] (apply wasm/component-call h (str iface f) args))
        seed (vec (repeat 32 7))
        [tag proof] (call "prove" 3 seed)]
    (is (= 35 (call "compute" 3)))
    (is (= :ok tag) "prove returns WIT result<list<u8>, string>")
    (is (= 128 (count proof)) "BN254 compressed Groth16 proof size")
    (is (= [:ok true] (call "verify" proof 35 seed)) "the public statement verifies")
    (is (= [:ok false] (call "verify" proof 36 seed)) "the same proof rejects a false y")
    (testing "a prover returning the same fixed proof cannot pass both statements"
      (let [[other-tag other-proof] (call "prove" 0 seed)]
        (is (= :ok other-tag))
        (is (not= proof other-proof))
        (is (= [:ok true] (call "verify" other-proof 5 seed)))))
    (testing "a guest clock trap kills the call, not the component instance"
      (let [message (try (call "probe-clock") nil
                         (catch Throwable t (.getMessage t)))]
        (is (string? message) "the guest trap is catchable as Throwable")
        (is (and (string? message) (str/includes? message "trap"))
            "the failure is a guest trap, not a missing export"))
      (is (= 35 (call "compute" 3)) "a later call on the same handle still answers")
      (is (= [:ok ["alpha" "beta"]] (call "echo-list"))
          "allocation and typed lifting still work after the trap"))))

(let [{:keys [fail error]} (run-tests 'zk-examples-test)]
  (System/exit (if (zero? (+ fail error)) 0 1)))
