;; Adapt the native plugin's zk namespace to a zero-host-function-import
;; component, then load the shared program. Run from the repository root.
(ns zk
  (:require [clojure.string :as str]))

(def ^:private component
  "test/e2e/fixtures/wasm/zk_groth16.component.wasm")
(def ^:private iface "hive:zk-groth16/tools@0.1.0#")
(def ^:private h (wasm/load-component component))

(defn- call [f & args]
  (apply wasm/component-call h (str iface f) args))

;; WIT result<T, string> becomes [:ok value] or [:err message]. The native
;; plugin returns the bare value, so unwrap at the adapter boundary.
(defn- ok [r]
  (if (and (vector? r) (= :ok (first r)))
    (second r)
    (throw (ex-info (str "zk guest returned " (pr-str r)) {:result r}))))

(defn compute [x] (call "compute" x))
(defn prove [x seed] (ok (call "prove" x seed)))
(defn verify [proof y seed] (ok (call "verify" proof y seed)))

(defn- authority-probe [which denied]
  (try (call "probe-one" which)
       (catch Throwable t
         (if (str/includes? (.getMessage t) "trap")
           denied
           (throw t)))))

(defn ambient []
  ;; Rust's wasm32-unknown-unknown std may return zero or trap on env iteration.
  ;; Re-throw non-trap failures rather than reporting missing exports as denial.
  (into [(authority-probe 0 "env-vars=TRAP (0 host variables exposed)")]
        (conj (vec (ok (call "probe-ambient")))
              (authority-probe 5 "wall-clock=TRAP (no clock authority)"))))

(in-ns 'user)
(load-file "docs/examples/zk-dual-runtime/src/demo.cljc")
