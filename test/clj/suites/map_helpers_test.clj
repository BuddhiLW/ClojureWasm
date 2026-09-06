;; test/e2e/phase14_map_helpers.sh
;;
;; Phase 14 §9.16 row 14.13 — D-134 cluster 2. Eager map/seq helpers:
;; reduce-kv / update-keys / update-vals / not-any? / butlast. Pure
;; Pattern A over reduce / keys / get / assoc / some / not / reverse /
;; rest / conj (no lazy-seq dependency). (dedupe/distinct/frequencies/
;; group-by need a working universal `=` — D-136 — and follow that fix.)
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_map_helpers.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.map-helpers-test
  (:require [clojure.test :refer [deftest is]]))

(deftest map-helpers-cases
  (is (= "3" (pr-str (reduce-kv (fn* [acc k v] (+ acc v)) 0 {:a 1 :b 2}))) "reduce_kv_sum")
  (is (= ":a" (pr-str (get (update-keys {1 :a} inc) 2))) "update_keys")
  (is (= "2" (pr-str (get (update-vals {:a 1} inc) :a))) "update_vals")
  (is (= "true" (pr-str (not-any? (fn* [x] (= x 9)) [1 2 3]))) "not_any_true")
  (is (= "false" (pr-str (not-any? (fn* [x] (= x 2)) [1 2 3]))) "not_any_false")
  (is (= "[1 2]" (pr-str (into [] (butlast [1 2 3])))) "butlast_vec"))
