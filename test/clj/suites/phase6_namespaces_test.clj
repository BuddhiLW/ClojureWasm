;; Namespace forms, require shapes, aliases, refers and private leaves.
;; Migrated from phase6_16_a_0_metadata.sh, phase6_16_b_4_*.sh,
;; phase6_16_d_clojure_string_shim.sh, phase6_clojure_string_cycle1.sh
;; and phase6_exit_smoke.sh. Fresh scratch namespaces preserve isolation.
(ns suites.phase6-namespaces-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.set :as cset]
            [clojure.string :as str]
            [clojure.walk :as walk]))

(def ^:private scratch-seq (atom 0))

(defn- ev [src]
  (let [n (symbol (str "p6.scratch" (swap! scratch-seq inc)))]
    (binding [*ns* (create-ns n)]
      (refer 'clojure.core)
      (load-string src))))

(defn- error-info [src]
  ;; Compile the outer try first. eval then compiles src inside its catch,
  ;; so analyzer-time errors reach the RuntimeException handler.
  (eval
    (list 'try
          (list 'eval (list 'read-string src))
          '(catch RuntimeException e [(ex-message e) (ex-data e)]))))

(deftest p6-metadata-baseline-and-errors
  (is (= 3 (+ 1 2)) "baseline_add")
  (is (= "HI" (str/upper-case "hi")) "baseline_string_upper")
  (is (= #{1 2} (cset/union (hash-set 1) (hash-set 2))) "baseline_set_union")
  (is (= [2 3 4] (walk/walk inc identity [1 2 3])) "baseline_walk")
  (let [[message data] (error-info "(no-such-var)")]
    ;; RuntimeException is the catchable name_error class (ADR-0060).
    (is (some? message) "unresolved_symbol_kind")
    (is (str/includes? message "Unable to resolve symbol")
        "unresolved_symbol_message")
    (is (or (nil? data) (map? data)) "unresolved_symbol_catchable")))

(deftest p6-ns-forms
  (is (nil? (ev "(ns foo)")) "ns_bare_returns_nil")
  (is (= 6 (ev "(ns my.test (:refer-clojure)) (reduce + 0 [1 2 3])"))
      "ns_with_refer_clojure_reduce")
  (is (= 42 (ev "(ns demo) (def x 42) demo/x")) "ns_def_stays_in_ns")
  (is (= "HI" (ev "(ns foo (:require [clojure.string :as s])) (s/upper-case \"hi\")"))
      "ns_require_directive_landed")
  (is (= 3 (ev "(ns foo (:refer-clojure :exclude [reduce])) (- 5 2)"))
      "ns_refer_clojure_exclude_landed")
  (let [[message] (error-info "(ns)")]
    (is (some? message) "ns_no_name_kind")
    (is (re-find #"ns requires a name|not supported in ClojureWasm" message)
        "ns_no_name_rejected")))

(deftest p6-private-core-leaf
  (is (= '(2 3 4) (map inc [1 2 3])) "public_wrapper_map")
  (is (= '(1 2) (filter pos? [-1 0 1 2])) "public_wrapper_filter")
  (let [[message] (error-info "(clojure.core/-take-eager 2 [1 2 3])")]
    (is (some? message) "private_leaf_qualified_kind")
    (is (str/includes? message "private") "private_leaf_qualified_template")
    (is (str/includes? message "clojure.core/-take-eager") "private_leaf_qualified_sym"))
  (is (= '(1 2) (ev "(in-ns 'clojure.core) (-take-eager 2 [1 2 3])"))
      "private_leaf_same_ns"))

(deftest p6-require-basic
  (is (nil? (ev "(require 'clojure.set)")) "require_clojure_set_noop")
  (is (nil? (ev "(require 'clojure.string)")) "require_clojure_string_noop")
  (is (nil? (ev "(require 'clojure.walk)")) "require_clojure_walk_noop")
  (is (nil? (ev "(require 'clojure.core)")) "require_clojure_core_noop")
  (is (= #{1 2} (ev "(require 'clojure.set) (clojure.set/union #{1} #{2})"))
      "require_then_qualified_use")
  (let [[message] (error-info "(require 'no.such.ns)")]
    (is (some? message) "require_unknown_kind")
    (is (str/includes? message "Could not locate") "require_unknown_template")
    (is (str/includes? message "no.such.ns") "require_unknown_ns"))
  (is (some? (ev "(var require)")) "require_resolves_as_var"))

(deftest p6-require-libspec
  (is (= #{1 2} (ev "(require '[clojure.set :as cs]) (cs/union #{1} #{2})"))
      "as_alias_union")
  (is (= "HI" (ev "(require '[clojure.string :as s]) (s/upper-case \"hi\")"))
      "as_alias_string_upper")
  (is (= #{3 4} (ev "(require '[clojure.set :refer [union]]) (union #{3} #{4})"))
      "refer_union_unqualified")
  (is (= #{2 3}
         (ev "(require '[clojure.set :refer [union intersection]]) (intersection #{1 2 3} #{2 3 4})"))
      "refer_multi_intersection")
  (is (= #{2}
         (ev "(require '[clojure.set :as cs :refer [union]]) (cs/intersection #{1 2} (union #{2} #{3}))"))
      "as_and_refer_combined")
  (let [[message] (error-info "(require '[clojure.core :refer [-take-eager]])")]
    (is (some? message) "refer_private_kind")
    (is (str/includes? message "private") "refer_private_template"))
  (let [[message] (error-info "(require '[clojure.set :refer [no-such-fn]])")]
    (is (some? message) "refer_missing_kind")
    (is (str/includes? message "no-such-fn") "refer_missing_name"))
  (is (nil? (ev "(require 'clojure.set)")) "bare_symbol_still_works"))

(deftest p6-private-string-leaf
  (let [[message] (error-info "(clojure.string/-upper-case \"hi\")")]
    (is (some? message) "private_string_leaf_qualified_kind")
    (is (str/includes? message "private") "private_leaf_qualified_template"))
  (is (= "HI" (ev "(in-ns 'clojure.string) (-upper-case \"hi\")"))
      "private_leaf_same_ns_works"))

(deftest p6-in-ns-and-exit-smoke
  (is (= 42 (ev "(in-ns (quote my.ns)) (def x 42) (in-ns (quote user)) my.ns/x"))
      "in_ns_round_trip")
  (is (= "HI"
         (ev "(ns demo (:refer-clojure)) (require '[clojure.string :as s]) (s/upper-case \"hi\")"))
      "ns_require_alias"))
