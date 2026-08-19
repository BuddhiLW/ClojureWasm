;; SPDX-License-Identifier: EPL-2.0
;; Copyright (c) the ClojureWasm authors. Licensed under EPL-2.0.
;; Independently reimplements the clojure.test API (originally Stuart Sierra and contributors; Clojure, EPL-1.0)
;; for ClojureWasm; no upstream source text is reproduced.

;; clojure.test — assertion + test-runner surface (D-227, ADR-0083-unblocked).
;;
;; Loaded by `bootstrap.zig::loadCore` after core.clj (so defmacro / syntax-quote
;; / defmulti / atom / *ns* / ns-name / clojure.walk are all available). The
;; (in-ns) header is mandatory — the loader carries no namespace knowledge.
;;
;; Design (per the D-227 Devil's-advocate fork): a PER-NAMESPACE test registry
;; keyed by the test ns symbol (so `(run-tests 'foo.test)` — the call external
;; runners make — works), `is` as a macro routing through an `assert-expr`
;; multimethod (`=` / `thrown?` / default), a `report` multimethod keyed on
;; `:type`, and `*report-counters*` as a dynamic var holding an atom.
;;
;; cljw adaptations (no JVM): the FAIL/ERROR ` (file:line)` suffix reads the
;; deftest VAR's :file/:line meta (D-563b) where clj reads the failing
;; assertion's stack frame (deftest-line vs is-line — the narrowed AD-041);
;; `report :error` cannot print a JVM cause trace (also AD-041). Deferred:
;; per-var lifecycle events (begin/end-test-var, end-test-ns), with-test.

(ns clojure.test
  (:refer-clojure)
  (:require [clojure.string]
            [clojure.walk]))

;; ---------------------------------------------------------------------------
;; State: report counters (dynamic, an atom) + the per-ns registry.
;; ---------------------------------------------------------------------------
(def ^:dynamic *report-counters* nil)
(def *initial-report-counters* {:test 0 :pass 0 :fail 0 :error 0})
(def ^:dynamic *testing-contexts* (list))
;; The Var(s) of the test currently running (test-var binds it) — lets a
;; reporter name the failing test. clj-compat surface (D-273/D-232).
(def ^:dynamic *testing-vars* (list))
;; Stack-trace depth a reporter may pass to clojure.stacktrace (nil = full).
(def ^:dynamic *stack-trace-depth* nil)

;; Where report output goes. clj binds this to the load-time *out*; `with-test-out`
;; rebinds *out* to it so `(binding [*test-out* w] (run-tests))` redirects output.
;; cljw's *out* works (with-out-str), so this is re-enabled (was a no-JVM deferral).
(def ^:dynamic *test-out* *out*)

;; ns-name-symbol -> vector of test Vars (deftest appends; run-tests reads).
(def *test-registry* (atom {}))

;; clj hangs these off the ns's metadata; cljw namespaces carry no user
;; metadata, so the registry mirrors *test-registry* and is keyed the same way.
(def *fixture-registry*
  "Atom of ns-name-symbol -> {:once [fixture-fn …] :each [fixture-fn …]}."
  (atom {}))

;; ---------------------------------------------------------------------------
;; report multimethod (keyed on :type) + do-report. `^:dynamic` so an
;; alternate reporter (e.g. clojure.test.tap) can `(binding [report …] …)`.
;; ---------------------------------------------------------------------------
(defmulti ^:dynamic report :type)

(defn inc-report [k]
  (when *report-counters*
    (swap! *report-counters* update k (fn [n] (inc (or n 0))))))

;; clj-compat alias: clojure.test/inc-report-counter is the public name a
;; reporter calls; cljw's internal counter bump is `inc-report`.
(def inc-report-counter inc-report)

;; clj-compat: run body with *out* bound to *test-out* (so a reporter's output
;; is redirectable by binding *test-out*).
(defmacro with-test-out [& body]
  `(binding [*out* *test-out*] ~@body))

;; A string naming the test(s) currently running, for a reporter's pass/fail
;; line: "(my-test) (file.clj:12)". The suffix reads the deftest VAR's
;; :file/:line source meta (D-563b); clj derives it from the failing
;; ASSERTION's stack frame instead, so clj points at the `is` line where
;; cljw points at the deftest line — the narrowed AD-041 residual (no JVM
;; stack frames to read).
(defn testing-vars-str [_m]
  (let [names (str "(" (clojure.string/join " " (reverse (map #(:name (meta %)) *testing-vars*))) ")")
        vm (meta (first *testing-vars*))
        file (:file vm)
        line (:line vm)]
    (if (and file line)
      (str names " (" (last (clojure.string/split (str file) #"/")) ":" line ")")
      names)))

;; A string of the active `testing` context strings (outermost first).
(defn testing-contexts-str []
  (clojure.string/join " " (reverse *testing-contexts*)))

(defn print-contexts []
  (when (seq *testing-contexts*)
    (println (testing-contexts-str))))

(defmethod report :pass [m] (with-test-out (inc-report :pass)))

(defmethod report :fail [m]
  (with-test-out
    (inc-report :fail)
    (println)
    (println "FAIL in" (testing-vars-str m))
    (print-contexts)
    (when (:message m) (println (:message m)))
    (println "expected:" (pr-str (:expected m)))
    (println "  actual:" (pr-str (:actual m)))))

(defmethod report :error [m]
  (with-test-out
    (inc-report :error)
    (println)
    (println "ERROR in" (testing-vars-str m))
    (print-contexts)
    (when (:message m) (println (:message m)))
    (println "expected:" (pr-str (:expected m)))
    (println "  actual:" (pr-str (:actual m)))))

(defmethod report :begin-test-ns [m]
  (with-test-out
    (println)
    (println "Testing" (:ns m))))

;; The per-var / end-of-namespace events exist for reporters that bracket a
;; test or a namespace. They print nothing here — but they must be DECLARED,
;; because `:default` prints the event map, and an event with no method would
;; otherwise turn every run into a wall of report maps.
(defmethod report :end-test-ns [m] nil)
(defmethod report :begin-test-var [m] nil)
(defmethod report :end-test-var [m] nil)

(defmethod report :summary [m]
  (with-test-out
    (println)
    (println "Ran" (:test m) "tests containing"
             (+ (:pass m) (:fail m) (:error m)) "assertions.")
    (println (:fail m) "failures," (:error m) "errors.")))

;; An event nobody handles is PRINTED, not swallowed (clj parity). A reporter
;; that emits an unknown `:type` should be visible, not silently dropped.
(defmethod report :default [m] (with-test-out (prn m)))

(defn do-report [m] (report m))

(defn file-position
  "Returns a vector [filename line-number] for the nth call up the stack.
  Deprecated in clj 1.2 (its info now lives on the result map's :file/:line).
  cljw carries no source location on Vars (AD-041) and no JVM stack-frame
  file/line, so this honestly returns [\"NO_SOURCE_FILE\" 0] — kept so code that
  calls it (clojure.test.junit) loads + runs."
  [_n]
  ["NO_SOURCE_FILE" 0])

;; ---------------------------------------------------------------------------
;; assert-expr multimethod — keyed on (first form), called at macroexpand time
;; by `is`. Returns the code that evaluates the assertion + reports.
;; ---------------------------------------------------------------------------
(defmulti assert-expr
  (fn [msg form]
    (cond (nil? form) :always-fail
          (seq? form) (first form)
          :else :default)))

;; clj-compat: the Var, or nil when it is unbound — so `function?` can ask
;; "is this a fn?" about a `declare`d-but-not-yet-defined var without throwing.
(defn get-possibly-unbound-var [v]
  (try (deref v) (catch Throwable _ nil)))

;; clj-compat: is `x` a symbol naming a (non-macro) function — or a function
;; value itself? Drives the :default split below — a predicate call gets the
;; (not …) actual treatment, anything else (a value, a macro form) just reports
;; the evaluated value.
(defn function? [x]
  (if (symbol? x)
    (when-let [v (resolve x)]
      (and (not (:macro (meta v)))
           (fn? (get-possibly-unbound-var v))))
    (fn? x)))

;; clj-compat building blocks. A custom `assert-expr` method composes these
;; rather than re-deriving the report shape; they are public in clj for exactly
;; that reason.

(defn assert-predicate
  "The assertion form for `(is (pred args…))`: on fail, actual shows the
  EVALUATED arguments wrapped in (not …), e.g. (not (= 1 2)); on pass, the
  evaluated form. Returns the predicate's result."
  [msg form]
  (let [pred (first form)]
    `(let [args# (list ~@(rest form))
           result# (apply ~pred args#)]
       (if result#
         (do-report {:type :pass :message ~msg :expected (quote ~form) :actual (cons (quote ~pred) args#)})
         (do-report {:type :fail :message ~msg :expected (quote ~form) :actual (list (quote ~'not) (cons (quote ~pred) args#))}))
       result#)))

(defn assert-any
  "The assertion form for any other expression: report the evaluated value."
  [msg form]
  `(let [value# ~form]
     (if value#
       (do-report {:type :pass :message ~msg :expected (quote ~form) :actual value#})
       (do-report {:type :fail :message ~msg :expected (quote ~form) :actual value#}))
     value#))

;; Generic. A predicate form like (pos? -1) reports actual (not (pos? -1));
;; anything else (a bare value, a macro form) reports the evaluated value.
(defmethod assert-expr :default [msg form]
  (if (and (sequential? form) (function? (first form)))
    (assert-predicate msg form)
    (assert-any msg form)))

;; `(is nil)` — no expression to evaluate, so there is nothing to report but
;; the failure itself.
(defmethod assert-expr :always-fail [msg form]
  `(do-report {:type :fail :message ~msg}))

;; (is (instance? Class x)) — on fail, actual is the object's CLASS, which is
;; the one thing the reader of the failure wants and the raw value does not say.
(defmethod assert-expr (quote instance?) [msg form]
  `(let [klass# ~(nth form 1)
         object# ~(nth form 2)]
     (let [result# (instance? klass# object#)]
       (if result#
         (do-report {:type :pass :message ~msg :expected (quote ~form) :actual (class object#)})
         (do-report {:type :fail :message ~msg :expected (quote ~form) :actual (class object#)}))
       result#)))

;; (is (= expected actual …)) — on fail, actual shows the evaluated form wrapped
;; in (not …), e.g. (not (= 1 2)); on pass, the evaluated form (= 1 1). The pred
;; symbol is taken from the user's form so it renders bare (= …), not qualified.
(defmethod assert-expr (quote =) [msg form]
  (let [pred (first form)]
    `(let [args# (list ~@(rest form))
           result# (apply = args#)]
       (if result#
         (do-report {:type :pass :message ~msg :expected (quote ~form) :actual (cons (quote ~pred) args#)})
         (do-report {:type :fail :message ~msg :expected (quote ~form) :actual (list (quote ~'not) (cons (quote ~pred) args#))}))
       result#)))

;; (is (thrown? Class body…)) — passes iff body throws an instance of Class;
;; returns the caught exception.
(defmethod assert-expr (quote thrown?) [msg form]
  (let [klass (second form)
        body (nthnext form 2)]
    `(try ~@body
          (do-report {:type :fail :message ~msg :expected (quote ~form) :actual nil})
          (catch ~klass e#
            (do-report {:type :pass :message ~msg :expected (quote ~form) :actual e#})
            e#))))

;; (is (thrown-with-msg? Class regex body…)) — like thrown?, but also requires
;; the thrown exception's message to match `regex` (re-find).
(defmethod assert-expr (quote thrown-with-msg?) [msg form]
  (let [klass (nth form 1)
        re (nth form 2)
        body (nthnext form 3)]
    `(try ~@body
          (do-report {:type :fail :message ~msg :expected (quote ~form) :actual nil})
          (catch ~klass e#
            (if (re-find ~re (ex-message e#))
              (do-report {:type :pass :message ~msg :expected (quote ~form) :actual e#})
              (do-report {:type :fail :message ~msg :expected (quote ~form) :actual e#}))
            e#))))

;; ---------------------------------------------------------------------------
;; is / are / testing.
;; ---------------------------------------------------------------------------
(defmacro try-expr [msg form]
  `(try ~(assert-expr msg form)
        (catch Throwable t#
          (do-report {:type :error :message ~msg :expected (quote ~form) :actual t#})
          nil)))

(defmacro is [form & more]
  `(try-expr ~(first more) ~form))

;; (are [a b] (= a b) 1 1, 2 2) — expands to one (is …) per argv-sized group,
;; substituting the argv symbols with each group's values (no clojure.template
;; dependency; direct postwalk substitution).
;;
;; A trailing partial group is an ERROR, not a group to drop: `partition` alone
;; would silently discard `(are [x y] (= x y) 1 1 2)`'s stray `2` and report a
;; clean pass, so the assertion the author wrote would simply not exist.
(defmacro are [argv expr & args]
  (when-not (or (and (empty? argv) (empty? args))
                (and (seq argv) (zero? (mod (count args) (count argv)))))
    (throw (ex-info "The number of args doesn't match are's argv." {:argv argv})))
  (cons (quote do)
        (map (fn [vals]
               (clojure.walk/postwalk-replace (zipmap argv vals)
                                               (list (quote clojure.test/is) expr)))
             (partition (count argv) args))))

(defmacro testing [s & body]
  `(binding [*testing-contexts* (cons ~s *testing-contexts*)]
     ~@body))

;; ---------------------------------------------------------------------------
;; deftest + the registry + run-tests.
;;
;; The var model is clj's: the test body lives in the var's `:test` METADATA,
;; and the var's value is a thunk that routes back through `test-var`. That
;; single fact is what makes `(my-test)` behave like a test run rather than a
;; bare body call, what lets `with-test` / `set-test` / `alter-meta!` attach a
;; test to a var they did not define, and what makes cljw legible to any runner
;; that enumerates `ns-interns` looking for `:test`.
;;
;; `*test-registry*` survives alongside it as an ORDER index, not a second
;; source of truth: `:test` metadata decides what IS a test, the registry only
;; remembers the order the tests were defined in (clj's `ns-interns` walk is
;; hash-ordered, and a compliance run is far easier to read in source order).
;; Registration is idempotent, so re-evaluating a namespace cannot make one
;; test report as two.
;; ---------------------------------------------------------------------------

(def ^:dynamic *load-tests*
  "When false, `deftest` / `deftest-` / `set-test` / `with-test` define their
  subject without its test, so a production load carries no test bodies."
  true)

(defn register-test!
  "Record `v` as a test of namespace `ns-sym`, preserving definition order.
  Idempotent: a var already registered is not appended twice."
  [ns-sym v]
  (swap! *test-registry* update ns-sym
         (fn [vs]
           (let [vs (or vs [])
                 nm (:name (meta v))]
             (if (some (fn [x] (= nm (:name (meta x)))) vs)
               vs
               (conj vs v)))))
  v)

(defmacro deftest [name & body]
  (when *load-tests*
    `(do
       (def ~(vary-meta name assoc :test `(fn [] ~@body))
         (fn [] (test-var (var ~name))))
       (register-test! (ns-name *ns*) (var ~name))
       (var ~name))))

(defmacro deftest-
  "Like `deftest`, but the var is private."
  [name & body]
  (when *load-tests*
    `(deftest ~(vary-meta name assoc :private true) ~@body)))

(defmacro with-test
  "Attach `body` as the test of whatever var `definition` defines."
  [definition & body]
  (if *load-tests*
    `(let [v# ~definition]
       (alter-meta! v# assoc :test (fn [] ~@body))
       (register-test! (ns-name *ns*) v#)
       v#)
    definition))

(defmacro set-test
  "Attach `body` as the test of the already-defined var `name`."
  [name & body]
  (when *load-tests*
    `(do
       (alter-meta! (var ~name) assoc :test (fn [] ~@body))
       (register-test! (ns-name *ns*) (var ~name))
       (var ~name))))

;; ---------------------------------------------------------------------------
;; Fixtures. A fixture is a function of one 0-arg thunk: it does its setup,
;; calls the thunk, and does its teardown. `:once` wraps a whole namespace's
;; run, `:each` wraps every individual test.
;; ---------------------------------------------------------------------------
(defn default-fixture
  "The identity fixture — calls `f` and nothing else."
  [f]
  (f))

(defn compose-fixtures
  "One fixture running `f1` outside `f2`."
  [f1 f2]
  (fn [g] (f1 (fn [] (f2 g)))))

(defn join-fixtures
  "The fixtures composed into a single fixture, applied left to right."
  [fixtures]
  (reduce compose-fixtures default-fixture fixtures))

(defn use-fixtures
  "Register `fns` as the `:once` (per namespace) or `:each` (per test) fixtures
  for the current namespace. Called at load time, like clj's.

  REPLACES the previously registered fixtures of that kind rather than adding
  to them — otherwise reloading a namespace would run its fixtures once more
  per reload, which is how a leaky fixture turns into a mystery."
  [fixture-type & fns]
  (when-not (contains? #{:each :once} fixture-type)
    (throw (ex-info (str "Unknown fixture type: " fixture-type) {:fixture-type fixture-type})))
  (swap! *fixture-registry* update (ns-name *ns*)
         (fn [m] (assoc (or m {}) fixture-type (vec fns))))
  nil)

(defn- fixtures-for [ns-sym kind]
  (join-fixtures (get (get (deref *fixture-registry*) ns-sym) kind)))

(defn test-var
  "Run the test attached to var `v` — the fn in its `:test` metadata — with
  `*testing-vars*` bound so a failure can name it. A var with no `:test` is
  not a test and is skipped. Counts the test itself, so a direct
  `(test-var #'t)` is counted exactly like one reached through `run-tests`."
  [v]
  (when-let [t (and v (:test (meta v)))]
    (binding [*testing-vars* (conj *testing-vars* v)]
      ;; Emit the per-var report events (clj parity) so a reporter that wraps
      ;; each test — clojure.test.junit's <testcase>, custom reporters — fires.
      (do-report {:type :begin-test-var :var v})
      (inc-report :test)
      ;; clj parity: an exception thrown OUTSIDE an `is` is that test's error,
      ;; not the run's. Without this catch a single bad test aborts every
      ;; remaining test in the run.
      (try
        (t)
        (catch Throwable e
          (do-report {:type :error
                      :message "Uncaught exception, not in assertion."
                      :expected nil
                      :actual e})))
      (do-report {:type :end-test-var :var v}))))

(defn- ns-sym-of
  "The namespace symbol for a symbol / string / namespace object, raising when
  it names no loaded namespace — a run against a namespace that is not there
  reports zero tests, and a zero that means 'absent' must not read as a pass."
  [ns]
  (let [sym (cond (symbol? ns) ns
                  (string? ns) (symbol ns)
                  :else (ns-name ns))]
    (when-not (find-ns sym)
      (throw (ex-info (str "No such namespace: " sym) {:ns sym})))
    sym))

(defn- tests-in-ns
  "Every test var of `ns-sym`, in definition order. `:test` metadata decides
  membership; the registry supplies the order, and any var that acquired its
  test another way (set-test, alter-meta!) follows, name-sorted."
  [ns-sym]
  (let [ordered (filter (fn [v] (:test (meta v)))
                        (get (deref *test-registry*) ns-sym []))
        seen (set (map (fn [v] (:name (meta v))) ordered))]
    (concat ordered
            (->> (vals (ns-interns ns-sym))
                 (filter (fn [v] (:test (meta v))))
                 (remove (fn [v] (contains? seen (:name (meta v)))))
                 (sort-by (fn [v] (str (:name (meta v)))))))))

(defn- test-vars-of-ns
  "Run `vars`, all of namespace `ns-sym`, inside that namespace's fixtures:
  the `:once` fixture wraps the whole group, the `:each` fixtures wrap every
  test individually."
  [ns-sym vars]
  (let [each-fixture (fixtures-for ns-sym :each)]
    ((fixtures-for ns-sym :once)
     (fn []
       (doseq [v vars]
         (each-fixture (fn [] (test-var v))))))))

(defn- var-ns-sym
  "The namespace symbol a var belongs to, from its `:ns` metadata (a namespace
  object or a symbol, depending on who set it)."
  [v]
  (when-let [n (:ns (meta v))]
    (if (symbol? n) n (ns-name n))))

(defn test-vars
  "Run `vars` — those of them that carry a `:test` — grouped by namespace so
  each group runs inside its own fixtures. Binds report counters when the
  caller has none."
  [vars]
  (binding [*report-counters* (or *report-counters* (atom *initial-report-counters*))]
    (doseq [[ns-sym vs] (group-by var-ns-sym vars)]
      (test-vars-of-ns ns-sym vs))
    (deref *report-counters*)))

(defn test-all-vars
  "Run every test var interned in `ns`."
  [ns]
  (let [ns-sym (ns-sym-of ns)]
    (binding [*report-counters* (or *report-counters* (atom *initial-report-counters*))]
      (test-vars-of-ns ns-sym (tests-in-ns ns-sym))
      (deref *report-counters*))))

(defn test-ns
  "Run every test of one namespace, bracketed by the :begin-test-ns /
  :end-test-ns report events and wrapped in the namespace's fixtures. Accepts a
  namespace symbol, a string, or a namespace object. Binds report counters when
  the caller has none, so it is callable on its own; returns the counters map.
  Prints NO summary — that is `run-tests`' job, which is what lets an external
  runner call this per namespace and keep one total.

  A namespace defining `test-ns-hook` has that called instead of the tests,
  and is then responsible for running them itself (clj parity)."
  [ns]
  (let [ns-sym (ns-sym-of ns)]
    (binding [*report-counters* (or *report-counters* (atom *initial-report-counters*))]
      (do-report {:type :begin-test-ns :ns ns-sym})
      (if-let [hook (ns-resolve ns-sym (quote test-ns-hook))]
        ((deref hook))
        (test-vars-of-ns ns-sym (tests-in-ns ns-sym)))
      ;; clj parity: emit :end-test-ns so a reporter that brackets a namespace
      ;; (junit's </testsuite>, custom reporters) fires.
      (do-report {:type :end-test-ns :ns ns-sym})
      (deref *report-counters*))))

(defn run-tests
  "Run the tests of each named namespace (default: the current one) and report
  a summary. A namespace may be named by symbol, string, or namespace object —
  `(run-tests *ns*)` is the call clj's own 0-arity makes."
  [& nses]
  (let [targets (if (seq nses) nses (list (ns-name *ns*)))]
    (binding [*report-counters* (atom *initial-report-counters*)]
      (doseq [ns targets]
        (test-ns ns))
      (let [summary (assoc (deref *report-counters*) :type :summary)]
        (do-report summary)
        summary))))

(defn run-all-tests []
  (apply run-tests (keys (deref *test-registry*))))

(defn run-test-var
  "Run the test of one var and report a summary."
  [v]
  (binding [*report-counters* (atom *initial-report-counters*)]
    (test-vars [v])
    (let [summary (assoc (deref *report-counters*) :type :summary)]
      (do-report summary)
      summary)))

(defmacro run-test
  "Run the test named by `test-symbol` and report a summary."
  [test-symbol]
  `(run-test-var (var ~test-symbol)))

(defn successful?
  "True when `summary` — a map as returned by `run-tests` — records neither a
  failure nor an error. The verdict a runner turns into an exit code."
  [summary]
  (and (zero? (:fail summary 0))
       (zero? (:error summary 0))))
