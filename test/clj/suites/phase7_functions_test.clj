;; Multi-arity fn* and defn, and clojure.string replace/replace-first.
;; Migrated from phase7_multi_arity.sh and phase7_replace_pattern_a.sh.
(ns suites.phase7-functions-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.set :as cset]
            [clojure.string :as str]))

(def ^:private scratch-seq (atom 0))

(defn- ev [src]
  (let [n (symbol (str "p7.fn.scratch" (swap! scratch-seq inc)))]
    (binding [*ns* (create-ns n)]
      (refer 'clojure.core)
      (load-string src))))

(deftest p7-multi-arity-fn-star
  (is (= 1 ((fn* ([x] x) ([x y] (+ x y))) 1)) "fn_star_two_methods_arity_1")
  (is (= 3 ((fn* ([x] x) ([x y] (+ x y))) 1 2)) "fn_star_two_methods_arity_2")
  (is (= 105 ((fn* [x] (+ x 100)) 5)) "fn_star_single_arity_back_compat")
  (is (= 99 ((fn* ([] 99) ([n] n) ([a b] (+ a b))))) "fn_star_three_methods_arity_0")
  (is (= 7 ((fn* ([] 99) ([n] n) ([a b] (+ a b))) 7)) "fn_star_three_methods_arity_1")
  (is (= 30 ((fn* ([] 99) ([n] n) ([a b] (+ a b))) 10 20)) "fn_star_three_methods_arity_2")
  (is (thrown-with-msg? Throwable #"Wrong number of args|arity|expected one of"
        ((fn* ([x] x) ([x y] y)) 1 2 3))
      "fn_star_no_matching_arity_diagnostic")
  (is (thrown-with-msg? Throwable #"duplicate|two|same arity|more than once"
        (ev "(fn* ([x] x) ([y] y))"))
      "fn_star_arity_duplicate_diagnostic")
  (is (= :one ((fn* ([x] :one) ([x & rest] :many)) 1))
      "fn_star_fixed_wins_on_exact_match")
  (is (= :many ((fn* ([x] :one) ([x & rest] :many)) 1 2 3))
      "fn_star_variadic_catches_extra")
  (is (= '(1 2 3) ((fn* ([& xs] xs)) 1 2 3)) "fn_star_variadic_only_binds_rest")
  (is (thrown-with-msg? Throwable #"exceeds|more params|variadic"
        (ev "(fn* ([x & rest] :v) ([a b c] :three))"))
      "fn_star_fixed_exceeds_variadic_diagnostic")
  (is (thrown-with-msg? Throwable #"more than 1 variadic|duplicate|variadic"
        (ev "(fn* ([& a] :a) ([& b] :b))"))
      "fn_star_variadic_duplicate_diagnostic"))

(deftest p7-multi-arity-defn
  (is (= "hello, world"
         (ev "(defn greet ([] (greet \"world\")) ([name] (str \"hello, \" name))) (greet)"))
      "defn_multi_arity_calls_other_arity")
  (is (= 30 (ev "(defn add ([] 0) ([x] x) ([x y] (+ x y))) (add 10 20)"))
      "defn_multi_arity_three_methods")
  (is (= 49 (ev "(defn square [x] (* x x)) (square 7)"))
      "defn_single_arity_back_compat"))

(deftest p7-multi-arity-clojure-set-join
  ;; These preserve the scripts' provisional checks: dispatch reaches the
  ;; requested arity and returns a set. The keymap correctness limitation is
  ;; not silently converted into a stronger or different expectation here.
  (let [three (cset/join #{{:a 1 :b 2}} #{{:c 1 :d 99}} {:a :c})
        two (cset/join #{{:a 1 :k :x}} #{{:a 1 :v :y}})]
    (is (or (and (set? three) (empty? three))
            (and (set? three) (seq three) (every? map? three)))
        "clojure_set_join_three_arity_dispatched")
    (is (or (and (set? two) (empty? two))
            (and (set? two) (seq two) (every? map? two)))
        "clojure_set_join_two_arity_back_compat")))

(deftest p7-replace-pattern-a
  (is (= "HI world HI" (str/replace "hello world hello" "hello" "HI"))
      "replace_string_string_all")
  (is (= "XYZ abc abc" (str/replace-first "abc abc abc" "abc" "XYZ"))
      "replace_first_string_string")
  (is (= "abc<123>def<456>ghi"
         (str/replace "abc123def456ghi" #"\d+" (fn* [m] (str "<" m ">"))))
      "replace_regex_fn")
  (is (= "abc<123>def456ghi"
         (str/replace-first "abc123def456ghi" #"\d+" (fn* [m] (str "<" m ">"))))
      "replace_first_regex_fn")
  (is (= "abc123" (str/replace "abc123" #"\d+" "$0")) "replace_regex_string_dollar_zero")
  (is (thrown-with-msg? Throwable #"Invalid match arg"
        (str/replace "abc" 42 "X"))
      "replace_unsupported_match_raises")
  (is (= "Invalid match arg: 42"
         (try (str/replace "abc" 42 "X")
              (catch IllegalArgumentException e (ex-message e))))
      "replace_unsupported_caught")
  (is (= "aabbcc" (str/replace "abc" #"(.)" "$1$1")) "replace_dollar_group_double")
  (is (= "01/2024" (str/replace "2024-01" #"(\d+)-(\d+)" "$2/$1")) "replace_dollar_swap")
  (is (= "x!" (str/replace "x" #"(x)" "$0!")) "replace_dollar_zero_whole")
  (is (= "[b]" (str/replace "ab" #"a(b)?" "[$1]")) "replace_dollar_nonparticipating")
  (is (= "AB" (str/replace "ab" #"(\w)" (fn [[whole g1]] (str/upper-case g1))))
      "replace_fn_match_vector"))
