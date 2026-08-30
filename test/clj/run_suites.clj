;; test/clj/run_suites.clj — the cljw-NATIVE test runner (Layer 5b).
;;
;; WHY THIS EXISTS. The bash e2e tier (`test/e2e/*.sh`) pays one cljw PROCESS
;; SPAWN per assertion: 425 scripts issue 3,016 `cljw -e '…'` invocations, and
;; a spawn costs ~21 ms, so ~63 s of a gate run is process startup that proves
;; nothing. A clojure.test suite run BY cljw pays that once for the whole file.
;; Measured 2026-08-29 on the same coverage (key/val + select-keys):
;; two bash scripts (18 spawns) = 401 ms; the equivalent suite (21 assertions,
;; 1 process) = 47 ms — 8.5x, and the suite asserts MORE.
;;
;; It is also the fast inner loop: over an nREPL the deftests re-run on
;; redefine with NO rebuild, which the bash tier can never do.
;;
;; WHAT STAYS IN BASH. Layer 2 is the CLI surface — process exit codes, stderr
;; rendering, argv handling. A suite running INSIDE cljw cannot assert its own
;; exit code, so those stay `test/e2e/*.sh`. Everything that is really "evaluate
;; an expression, check the value (or that it throws)" belongs here.
;;
;; DISCOVERY, NOT REGISTRATION. Suites are found by listing `test/clj/suites/`,
;; so a new suite file runs the moment it exists. An explicit suite list would
;; reproduce the coverage-lie that `scripts/check_e2e_reach.sh` exists to catch
;; (a test written but never wired up gates nothing). A file that FAILS to load
;; is reported and fails the run — it is never silently skipped.
;;
;; Usage:  cljw -cp test/clj test/clj/run_suites.clj
(require '[clojure.test :as test]
         '[clojure.string :as str]
         '[clojure.java.io :as io])

(def ^:private suite-dir "test/clj/suites")

(defn- suite-files
  "The *_test.clj files under suite-dir, name-sorted for a stable report."
  []
  (let [d (io/file suite-dir)]
    (if (.isDirectory d)
      (sort (filter #(str/ends-with? % "_test.clj")
                    (map #(.getName %) (.listFiles d))))
      [])))

(defn- ns-of
  "suites/foo_bar_test.clj -> suites.foo-bar-test (Clojure's file<->ns munging)."
  [filename]
  (symbol (str "suites." (str/replace (str/replace filename #"\.clj$" "") "_" "-"))))

(let [files (suite-files)
      ;; Load every suite first, keeping the failures instead of dying on the
      ;; first one — a broken suite must be REPORTED, not hide the other results.
      loaded (reduce (fn [acc f]
                       (let [n (ns-of f)]
                         (try (require n)
                              (update acc :ok conj n)
                              (catch Throwable t
                                (update acc :failed conj [f (str t)])))))
                     {:ok [] :failed []}
                     files)
      {:keys [ok failed]} loaded]
  (when (seq failed)
    (println "\nSUITES THAT FAILED TO LOAD:")
    (doseq [[f err] failed] (println (str "  " f " -> " err))))
  (when (empty? files)
    (println (str "\nNo suites found under " suite-dir "/")))
  (let [r (when (seq ok) (apply test/run-tests ok))
        bad (+ (long (or (:fail r) 0)) (long (or (:error r) 0)))]
    (println (str "\nsuites: " (count ok) " loaded, " (count failed) " failed to load"))
    (System/exit (if (and (zero? bad) (empty? failed)) 0 1))))
