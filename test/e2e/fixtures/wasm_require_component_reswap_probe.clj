;; Re-requiring a component whose bytes changed at the SAME path. The export
;; table is the source of truth for which Vars `require-component` owns in a
;; namespace: exports the new build dropped are unmapped, exports it kept keep
;; their Var identity, and anything the user defined there is never touched.
;;
;; The swap copies BYTES (clojure.java.io/copy from File to File): a .wasm is
;; binary, so a spit/slurp round-trip through a String would corrupt it.
;; CLJW_SWAP_DIR names a scratch dir the e2e script owns; the fixture writes
;; exactly one file there.
(require 'cljw.wasm '[clojure.java.io :as io])

(def swap-path (str (or (System/getenv "CLJW_SWAP_DIR") "/tmp") "/swap_component.wasm"))
(def counter-bytes "test/e2e/fixtures/wasm/resource_counter.wasm")
(def echo-bytes "test/e2e/fixtures/wasm/two_export_component.wasm")

(defn put-bytes! [src] (io/copy (io/file src) (io/file swap-path)))

(defn publics [ns-sym] (set (map name (keys (ns-publics ns-sym)))))

(defn component-publics
  "Names of the Vars in `ns-sym` that require-component interned."
  [ns-sym]
  (set (for [[s v] (ns-publics ns-sym)
             :when (:cljw.wasm/component-export (meta v))]
         (name s))))

(defn check [label ok? detail]
  (assert ok? (str label ": " detail))
  (println "PASS" label))

;; --- generation 1: resource_counter (counter / increment / get) -------------
(put-bytes! counter-bytes)
(cljw.wasm/require-component swap-path :as swp :refer [increment])
(check "gen1-exports"
       (= #{"counter" "increment" "get"} (publics 'swp))
       (pr-str (publics 'swp)))
(check "gen1-tagged"
       (and (true? (:cljw.wasm/component-export (meta #'swp/get)))
            (= swap-path (:cljw.wasm/component-path (meta #'swp/get))))
       (pr-str (meta #'swp/get)))
(check "gen1-arglists-kept" (seq (:arglists (meta #'swp/counter))) (pr-str (meta #'swp/counter)))
(check "gen1-refer" (some? (ns-resolve 'user 'increment)) "increment was not referred into user")

;; A user def in the component's namespace, and one that SHADOWS an export
;; name: `def` rebinds the Var and replaces its metadata, so the shadowing Var
;; is the user's from then on.
(in-ns 'swp)
(def user-helper :mine)
(def increment :shadowed-by-user)
(clojure.core/in-ns 'user)
(check "gen1-shadow-untagged"
       (nil? (:cljw.wasm/component-export (meta #'swp/increment)))
       (pr-str (meta #'swp/increment)))

(def gen1-get-var #'swp/get)
(def gen1-handle (swp/counter 5))
(check "gen1-call" (= 5 (swp/get gen1-handle)) "counter(5)->get")

;; --- generation 2: two_export_component (echo-bool / echo-s32), same path ---
(put-bytes! echo-bytes)
(cljw.wasm/require-component swap-path :as swp :refer [increment])

(check "gen2-component-publics-exact"
       (= #{"echo-bool" "echo-s32"} (component-publics 'swp))
       (pr-str (component-publics 'swp)))
(check "gen2-user-defs-survive"
       (= #{"echo-bool" "echo-s32" "user-helper" "increment"} (publics 'swp))
       (pr-str (publics 'swp)))
(check "gen2-user-shadow-value" (= :shadowed-by-user @(ns-resolve 'swp 'increment)) "user's increment rebound")
(check "gen2-dropped-unmapped"
       (and (nil? (ns-resolve 'swp 'get)) (nil? (ns-resolve 'swp 'counter)))
       "get / counter still resolve in swp")
(check "gen2-refer-dropped-unmapped"
       (nil? (ns-resolve 'user 'increment))
       (pr-str (ns-resolve 'user 'increment)))
(check "gen2-new-exports-call"
       (and (= 7 (swp/echo-s32 7)) (true? (swp/echo-bool true)))
       "echo-s32 / echo-bool")

;; A Var captured before the swap no longer reaches the old instance: calling
;; it is a catchable error naming the removed export, not a silent call into
;; the previous generation.
(let [r (try (gen1-get-var gen1-handle) :NOT-CAUGHT
             (catch Exception e (ex-message e)))]
  (check "gen2-orphan-var-throws"
         (and (string? r) (re-find #"no longer exports `get`" r))
         (pr-str r)))

;; --- generation 3 + 4: back to resource_counter, then the same bytes again ---
;; An export whose name the user had taken is interned over it, exactly as a
;; first require into that namespace would: requiring into a namespace is a
;; request for the export table's names.
(put-bytes! counter-bytes)
(cljw.wasm/require-component swap-path :as swp)
(check "gen3-component-publics-exact"
       (= #{"counter" "increment" "get"} (component-publics 'swp))
       (pr-str (component-publics 'swp)))
(check "gen3-user-helper-survives" (= :mine @(ns-resolve 'swp 'user-helper)) "user-helper lost")
(check "gen3-echo-unmapped" (nil? (ns-resolve 'swp 'echo-s32)) "echo-s32 still resolves")

(def gen3-get-var #'swp/get)
(cljw.wasm/require-component swap-path :as swp)
(check "gen4-var-identity-kept" (identical? gen3-get-var #'swp/get) "a kept export got a new Var")
(check "gen4-call-through-kept-var" (= 3 (swp/get (swp/counter 3))) "counter(3)->get")

;; --- the ns-directive path routes through the same worker -------------------
(eval (list 'ns 'reswap-app (list :require [swap-path :as 'rsw])))
(in-ns 'user)
(check "ns-directive-gen1" (= #{"counter" "get" "increment"} (component-publics 'rsw)) (pr-str (component-publics 'rsw)))
(put-bytes! echo-bytes)
(eval (list 'ns 'reswap-app (list :require [swap-path :as 'rsw])))
(in-ns 'user)
(check "ns-directive-gen2" (= #{"echo-bool" "echo-s32"} (component-publics 'rsw)) (pr-str (component-publics 'rsw)))

(println "DONE")
