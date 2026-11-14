;; Phase 7 catch hierarchy, protocols, interfaces, records, reify and vars.
;; Migrated from the corresponding phase7_* e2e scripts. Top-level forms run
;; through load-string in fresh scratch namespaces, just as the scripts ran
;; each case in a fresh cljw process. Every p7 scratch namespace is unique.
(ns suites.phase7-protocols-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.datafy]
            [clojure.string :as str]))

(def ^:private scratch-seq (atom 0))

(defn- ev [src]
  (let [n (symbol (str "p7.scratch" (swap! scratch-seq inc)))]
    (binding [*ns* (create-ns n)]
      (refer 'clojure.core)
      (load-string src))))

(deftest p7-catch-hierarchy
  (is (= "boom" (try (throw (ex-info "boom" {}))
                     (catch ExceptionInfo e (ex-message e))))
      "catch_exception_info_direct")
  (is (= "boom" (try (throw (ex-info "boom" {}))
                     (catch Throwable e (ex-message e))))
      "catch_throwable_matches_all")
  (is (= "boom" (try (throw (ex-info "boom" {}))
                     (catch Exception e (ex-message e))))
      "catch_exception_parent_walk")
  (is (= :ok (try (throw (ex-info "boom" {}))
                  (catch IOException e :wrong)
                  (catch ExceptionInfo e :ok)))
      "catch_sibling_skip")
  (is (= :caught (try (throw (ex-info "boom" {}))
                      (catch java.lang.RuntimeException e :caught)))
      "catch_fqcn_normalise")
  (is (thrown-with-msg? Throwable
        #"catch class 'FooBarException' is not a known exception type"
        (ev "(try (throw (ex-info \"x\" {})) (catch FooBarException e :wrong))"))
      "catch_unknown_class_raises"))

(deftest p7-definterface
  (is (true? (ev "(do (definterface IMarker) (deftype T [] IMarker) (instance? IMarker (T.)))"))
      "marker_instance")
  (is (false? (ev "(do (definterface IMarker) (deftype T [] IMarker) (instance? IMarker 5))"))
      "marker_neg")
  (is (= 42 (ev "(do (definterface IBox (getv [])) (deftype B [x] IBox (getv [this] x)) (.getv (B. 42)))"))
      "method_getv")
  (is (= 50 (ev "(do (definterface IBox (addv [n])) (deftype B [x] IBox (addv [this n] (+ x n))) (.addv (B. 42) 8))"))
      "method_arg")
  (is (true? (ev "(do (definterface IBox (getv [])) (deftype B [x] IBox (getv [this] x)) (instance? IBox (B. 1)))"))
      "method_inst")
  (is (= [:a :b]
         (ev "(do (definterface IA (av [])) (defprotocol IB (bv [this])) (deftype M [] IA (av [this] :a) IB (bv [this] :b)) [(.av (M.)) (bv (M.))])"))
      "mixed"))

(deftest p7-defmacro-private
  (is (false? (ev "(defmacro ^:private privmac [] 1) (contains? (ns-publics *ns*) 'privmac)"))
      "private_macro_not_in_publics")
  (is (true? (ev "(defmacro ^:private privmac [] 1) (boolean (:private (meta #'privmac)))"))
      "private_macro_meta")
  (is (true? (ev "(defmacro pubmac [] 1) (contains? (ns-publics *ns*) 'pubmac)"))
      "public_macro_in_publics")
  (is (true? (ev "(defmacro ^:private privmac [] 1) (contains? (ns-interns *ns*) 'privmac)"))
      "private_macro_in_interns"))

(def ^:private describe-host-source
  "(defprotocol D (descr [x]))
   (extend-protocol D
     clojure.lang.Namespace (descr [n] [:ns (ns-name n)])
     clojure.lang.IRef (descr [r] [:ref (deref r)])
     java.lang.Throwable (descr [t] [:err (ex-message t)]))")

(deftest p7-extend-host-type
  (is (= [:ns 'my.ns] (ev (str describe-host-source " (descr (create-ns 'my.ns))"))) "ns")
  (is (= [:ref 7] (ev (str describe-host-source " (descr (atom 7))"))) "atom")
  (is (= [:ref 9] (ev (str describe-host-source " (descr (ref 9))"))) "ref")
  (is (= [:err "boom"] (ev (str describe-host-source " (descr (ex-info \"boom\" {}))"))) "throw")
  (is (= :no-impl (ev (str describe-host-source " (try (descr 5) (catch Throwable e :no-impl))"))) "miss")
  (is (= 5 (do (require 'clojure.datafy) (clojure.datafy/datafy 5))) "datafy_scalar")
  (is (= [42] (clojure.datafy/datafy (atom 42))) "datafy_atom")
  (is (= 'zz.top (:name (clojure.datafy/datafy (create-ns 'zz.top)))) "datafy_ns"))

(deftest p7-extend-native-class-values
  (is (= 10 (ev "(defprotocol P (q [n])) (extend-type Long P (q [n] (* n 2))) (q 5)"))
      "extend_type_long")
  (is (= "hi bob" (ev "(defprotocol Greet (g [s])) (extend-type String Greet (g [s] (str \"hi \" s))) (g \"bob\")"))
      "extend_type_string")
  (is (= [:int :str]
         (ev "(defprotocol Desc (d [x])) (extend-protocol Desc Long (d [_] :int) String (d [_] :str)) [(d 7) (d \"x\")]"))
      "extend_protocol_two")
  (is (= Long (class 5)) "class_as_value_eq")
  (is (= 105 (ev "(defprotocol P (q [n])) (extend-type java.lang.Long P (q [n] (+ n 100))) (q 5)"))
      "extend_type_fqcn")
  (is (= 42 (ev "(def String 42) String")) "user_def_shadows_class")
  (is (isa? Long Number) "number_resolves")
  (is (instance? Number 5) "number_instance")
  (is (thrown-with-msg? Throwable #"Unable to resolve symbol: 'TotallyMadeUpClass'"
        (ev "TotallyMadeUpClass"))
      "unknown_class_still_unresolved")
  (is (= 10N (ev "(defprotocol P (q [n])) (extend-type BigInt P (q [n] (* n 2))) (q 5N)"))
      "extend_type_bigint")
  (is (instance? clojure.lang.BigInt 1N) "instance_bigint")
  (is (instance? clojure.lang.Ratio 1/2) "instance_ratio")
  (is (instance? java.math.BigDecimal 1M) "instance_bigdec")
  (is (= Pattern (class #"x")) "class_regex_pattern"))

(deftest p7-instance-q
  (is (instance? String "abc") "native_string")
  (is (instance? Long 42) "native_long")
  (is (false? (instance? String 42)) "native_mismatch")
  (is (instance? Number 42) "number_integer")
  (is (instance? Number 3.14) "number_float")
  (is (instance? IFn (fn* [x] x)) "ifn_fn_val")
  (is (instance? Throwable (ex-info "x" {})) "throwable_ex_info")
  (is (false? (instance? Throwable nil)) "throwable_nil_false")
  (is (false? (instance? Throwable 42)) "throwable_int_false")
  (is (instance? Exception (ex-info "x" {})) "exception_parent_walk")
  (is (instance? java.lang.Long 42) "fqcn_long")
  (is (thrown-with-msg? Throwable #"Unable to resolve symbol: 'NoSuchClassXyz'"
        (ev "(instance? NoSuchClassXyz 42)"))
      "unknown_class_raises")
  (is (= :s (condp instance? "x" Number :n String :s :o)) "condp_instance")
  (is (= [true false true false] (mapv (partial instance? Number) [1 :a 2.0 "x"]))
      "partial_instance_map")
  (is (instance? clojure.lang.IPersistentVector [1 2]) "interface_marker_value")
  (is (true? ((fn [c v] (instance? c v)) Long 42)) "class_as_fn_arg")
  (is (true? (ev "(ns t (:import (java.util Map$Entry))) (instance? Map$Entry (first {:a 1}))"))
      "imported_map_entry"))

(defprotocol P7Shift (p7-shift-by [this n]))
(defrecord P7ShiftBox [x] P7Shift
  (p7-shift-by [this n] (+ (get this :x) n)))

(deftest p7-method-dispatch
  (is (= 15 (.p7-shift-by (->P7ShiftBox 10) 5)) "defrecord_dot_method_dispatch")
  (is (= 21 (.p7-shift-by (reify P7Shift (p7-shift-by [this n] (* n 3))) 7))
      "reify_dot_method_dispatch")
  (let [point (ev "(defrecord Point [x y]) (->Point 99 100)")]
    (is (= 99 (.x point)) "defrecord_arity2_stays_field_read"))
  (is (thrown-with-msg? Throwable #"unknown-method|satisfies|protocol_no_satisfies"
        (ev "(defrecord Box [x]) (.unknown-method (->Box 1) 2)"))
      "method_unknown_raises")
  (is (= 1023 (let [outer 1000]
                (.p7-shift-by (reify P7Shift (p7-shift-by [this n] (+ outer n))) 23)))
      "reify_dot_method_closure_capture"))

(deftest p7-multimethod
  (testing "exact dispatch, default, preference and method parameters"
    (is (= [:pi :sq]
           (ev "(defmulti area (fn* [s] (get s :type))) (defmethod area :circle [_] :pi) (defmethod area :square [_] :sq) [(area {:type :circle}) (area {:type :square})]"))
        "defmulti_circle / defmulti_square")
    (is (= :fallback (ev "(defmulti g (fn* [s] (get s :k))) (defmethod g :a [_] :a-result) (defmethod g :default [_] :fallback) (g {:k :missing})"))
        "defmulti_default_fallback")
    (is (= :x-result (ev "(defmulti h (fn* [s] (get s :k))) (defmethod h :x [_] :x-result) (defmethod h :y [_] :y-result) (prefer-method h :x :y) (h {:k :x})"))
        "prefer_method_compiles")
    (is (= 42 (ev "(defmulti describe (fn* [s] (get s :k))) (defmethod describe :n [s] (get s :v)) (describe {:k :n :v 42})"))
        "defmethod_body_uses_param")
    (is (= :circ (ev "(defmulti area :shape) (defmethod area :circle [_] :circ) (defmulti area :shape) (area {:shape :circle})"))
        "defmulti_reeval_noop")
    (is (= :fb (ev "(defmulti k :t :default :other) (defmethod k :other [_] :fb) (k {:t :unknown})"))
        "defmulti_default_option")))

(deftest p7-polymorphic-extend
  (is (= 99 (ev "(defrecord Point [x y]) (extend-type Point IPersistentCollection (-count [_] 99)) (count (->Point 3 4))"))
      "defrecord_count_user_override_wins")
  (is (= 2 (ev "(defrecord Plain [a b]) (count (->Plain 3 4))")) "defrecord_count_field_count_preserved")
  (is (thrown-with-msg? Throwable #"satisfy|no method|IPersistentCollection" (count 42))
      "long_count_no_extend_raises_diagnostic")
  (is (= 5 (ev "(def Long (cljw.internal/__native-type :integer)) (extend-type Long IPersistentCollection (-count [n] 5)) (count 42)"))
      "long_count_via_outer_else_slow_path")
  (is (thrown-with-msg? Throwable #"satisfy|Seqable|no method" (seq 42))
      "long_seq_no_extend_raises_diagnostic")
  (is (= '(1 2) (ev "(defrecord Pair [a b]) (extend-type Pair Seqable (-seq [_] '(1 2))) (seq (->Pair 1 2))"))
      "defrecord_seq_via_extend_type")
  (try
    (is (= '(:a :b) (ev "(def Long (cljw.internal/__native-type :integer)) (extend-type Long Seqable (-seq [_] '(:a :b))) (seq 42)"))
        "long_seq_via_outer_else_slow_path")
    (finally
      ;; Native descriptors are process-global, unlike fresh scratch namespaces.
      ;; Restore an unextended integer so later sequence suites still throw.
      (cljw.internal/__extend-type!
        (cljw.internal/__native-type :integer) Seqable
        [["-seq" (fn [_] (throw (ex-info "No implementation of -seq for Long" {})))]])))
  (is (= 99 (ev "(defrecord Bag [contents]) (extend-type Bag IPersistentCollection (-cons [_ x] x)) (conj (->Bag '()) 99)"))
      "defrecord_conj_via_extend_type")
  (is (thrown-with-msg? Throwable #"satisfy|IPersistentCollection|no method" (conj 42 1))
      "long_conj_no_extend_raises_diagnostic")
  (is (= 99 (ev "(defrecord Box [v]) (extend-type Box IReduce (-reduce [_ _] 99)) (reduce + (->Box 1))"))
      "defrecord_reduce_via_ireduce")
  (is (= 60 (ev "(defrecord Pair2 [a b]) (extend-type Pair2 Seqable (-seq [_] '(10 20 30))) (reduce + 0 (->Pair2 1 2))"))
      "defrecord_reduce_fallback_to_seq_walk")
  (is (= [:one :two] (ev "(defprotocol Greet (hi [x] [x y])) (defrecord G [n]) (extend-protocol Greet G (hi ([_] :one) ([_ _] :two))) [(hi (->G 1)) (hi (->G 1) 9)]"))
      "extend_protocol_grouped_multi_arity")
  (is (= [:p :q] (ev "(defprotocol Greet2 (ho [x] [x y])) (defrecord G2 [n]) (extend-type G2 Greet2 (ho ([_] :p) ([_ _] :q))) [(ho (->G2 1)) (ho (->G2 1) 9)]"))
      "extend_type_grouped_multi_arity")
  (is (= [:r :s] (ev "(defprotocol Greet3 (hey [x] [x y])) (defrecord G3 [n]) (extend-protocol Greet3 G3 (hey [_] :r) (hey [_ _] :s)) [(hey (->G3 1)) (hey (->G3 1) 9)]"))
      "extend_protocol_repeated_multi_arity")
  (is (= [:second true]
         (ev "(defprotocol ReExtP (re-ext-pf [x])) (extend-type Long ReExtP (re-ext-pf [x] :first)) (extend-type Long ReExtP (re-ext-pf [x] :second)) [(re-ext-pf 1) (satisfies? ReExtP 1)]"))
      "reextend_later_wins"))

(deftest p7-protocol
  (is (false? (ev "(defprotocol IPing (ping [this])) (cljw.internal/__satisfies? IPing 42)"))
      "defprotocol_satisfies_false_on_integer")
  (is (false? (ev "(defprotocol IPair (first-of [p]) (second-of [p])) (cljw.internal/__satisfies? IPair \"hello\")"))
      "defprotocol_multi_method_satisfies_false")
  (is (= 'Empty (ev "(defprotocol Empty)")) "defprotocol_zero_method_marker_returns_name")
  (is (true? (ev "(defprotocol Mark) (deftype T [a] Mark) (vector? [(->T 1)])"))
      "defprotocol_zero_method_marker")
  (is (str/includes? (str (ev "(defprotocol IPing (ping [this])) ping")) "#<IPing/ping>")
      "defprotocol_per_method_var_binding")
  (is (= 120 (ev "(defn fact [n] (if (= n 0) 1 (* n (fact (- n 1))))) (fact 5)"))
      "recursive_defn_factorial")
  (let [prefix "(defprotocol IInc (inc-one [x])) (def Long (cljw.internal/__native-type :integer)) (extend-type Long IInc (inc-one [x] (+ x 1)))"]
    (is (= 42 (ev (str prefix " (inc-one 41)"))) "extend_type_long_native_dispatch")
    (is (true? (ev (str prefix " (cljw.internal/__satisfies? IInc 7)"))) "extend_type_satisfies_native_receiver")
    (is (true? (ev (str prefix " (satisfies? IInc 7)"))) "satisfies_wrapper_true_native_receiver")
    (is (true? (ev (str prefix " (extends? IInc Long)"))) "extends_wrapper_true_for_extended_type")
    (is (false? (ev (str prefix " (defprotocol IPing (ping [this])) (extends? IPing Long)")))
        "extends_wrapper_false_for_unextended_protocol"))
  (is (false? (ev "(defprotocol IPing (ping [this])) (satisfies? IPing 42)"))
      "satisfies_wrapper_false_on_integer"))

(deftest p7-record-field-scope
  (is (= 10 (ev "(defprotocol P (m [this])) (defrecord R [v] P (m [this] (* v 2))) (m (->R 5))"))
      "defrecord_bare_field")
  (is (= 12 (ev "(defprotocol P (m [this])) (deftype T [v] P (m [this] (* v 3))) (m (->T 4))"))
      "deftype_bare_field")
  (is (= 99 (ev "(defprotocol P (m [this v])) (defrecord R [v] P (m [this v] v)) (m (->R 1) 99)"))
      "param_shadows_field")
  (is (= 15 (ev "(defprotocol P (m [this x])) (defrecord R [v] P (m [this x] (+ v x))) (m (->R 10) 5)"))
      "unshadowed_field_with_param")
  (is (= [3 4 7] (ev "(defprotocol IPt (sx [t]) (sy [t]) (sm [t])) (defrecord Pt [a b] IPt (sx [_] a) (sy [_] b) (sm [_] (+ a b))) [(sx (->Pt 3 4)) (sy (->Pt 3 4)) (sm (->Pt 3 4))]"))
      "multi_field_bare")
  (is (= 42 (ev "(defprotocol P (m [this])) (deftype T [v] P (m [_] (inc v))) (m (->T 41))"))
      "discard_instance_bare_field")
  (is (= 36 (ev "(defprotocol Shape (area [s])) (defrecord Sq [side] Shape (area [s] (* (:side s) side))) (area (->Sq 6))"))
      "explicit_and_bare_mix"))

(deftest p7-reify
  (is (some? (ev "(defprotocol P (m [this])) (reify P (m [this] 42))"))
      "reify_basic_construction")
  (is (some? (reify)) "reify_empty_form_constructs")
  (is (true? (ev "(defprotocol P (m [this])) (some? (reify P))"))
      "reify_empty_section_constructs")
  (is (thrown-with-msg? Throwable #"reify section" (ev "(reify (m [_] 1))"))
      "reify_section_invalid_diagnostic")
  (is (thrown-with-msg? Throwable #"reify method" (ev "(defprotocol P (m [this])) (reify P (m))"))
      "reify_method_invalid_diagnostic")
  (is (= 42 (ev "(defprotocol P (m [x])) (m (reify P (m [this] 42)))"))
      "reify_happy_path_dispatch")
  (is (= 107 (ev "(defprotocol P (m [x])) (let* [outer 100] (m (reify P (m [this] (+ outer 7)))))"))
      "reify_closure_capture")
  (is (true? (ev "(defprotocol P (m [x])) (cljw.internal/__satisfies? P (reify P (m [this] 42)))"))
      "reify_satisfies_true"))

(deftest p7-symbol-of-var
  (is (= 'user/zzz
         (binding [*ns* (create-ns 'user)]
           (refer 'clojure.core)
           (load-string "(def zzz 1) (symbol #'zzz)")))
      "symbol-of-user-var")
  (is (true? (binding [*ns* (create-ns 'user)]
               (refer 'clojure.core)
               (load-string "(def zzz 1) (= (symbol #'zzz) 'user/zzz)")))
      "symbol-of-var-eq")
  (is (= 'aa/q (ev "(ns aa) (def q 1) (ns bb) (symbol #'aa/q)"))
      "symbol-of-var-other-ns"))

(deftest p7-exit-smoke-composition
  (is (= "hi, alice! | hello, world!"
         (ev "(defprotocol IGreet (greet [this who])) (defrecord Greeter [tone] IGreet (greet [self who] (str (.tone self) \", \" who \"!\"))) (str (.greet (->Greeter \"hi\") \"alice\") \" | \" (.greet (->Greeter \"hello\") \"world\"))"))
      "defprotocol_extend_methodcall")
  (is (= "12 | 25 | :unknown"
         (ev "(defmulti area (fn* [s] (get s :shape))) (defmethod area :circle [s] (* 3 (* (get s :r) (get s :r)))) (defmethod area :square [s] (* (get s :side) (get s :side))) (defmethod area :default [_] :unknown) (str (area {:shape :circle :r 2}) \" | \" (area {:shape :square :side 5}) \" | \" (area {:shape :triangle}))"))
      "defmulti_defmethod_dispatch")
  (is (= "107 | 0 | 42 | 15"
         (ev "(defprotocol IShift (shift-by [this n])) (def shifter (reify IShift (shift-by [_ n] (+ n 100)))) (def f (fn* ([] 0) ([x] x) ([x y & rest] (apply + x y rest)))) (str (.shift-by shifter 7) \" | \" (f) \" | \" (f 42) \" | \" (apply f 1 2 '(3 4 5)))"))
      "reify_multi_arity_apply")
  (is (= "42 | [[1 [2 3] 4] 1 [2 3] 2 3 4]"
         (ev "(require '[clojure.zip]) (defprotocol IScale (scale [this k])) (defrecord Wrap [v] IScale (scale [self k] (* (.v self) k))) (def w (->Wrap 21)) (try (if (instance? Wrap w) (let* [z (clojure.zip/vector-zip [1 [2 3] 4]) walked (loop* [loc z acc []] (if (clojure.zip/end? loc) acc (recur (clojure.zip/next loc) (conj acc (clojure.zip/node loc)))))] (str (.scale w 2) \" | \" walked)) (throw (ex-info \"wrong\" {}))) (catch RuntimeException e (ex-message e)))"))
      "phase7_composed"))
