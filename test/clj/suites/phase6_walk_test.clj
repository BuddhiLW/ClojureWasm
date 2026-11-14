;; clojure.walk traversal, replacement, key conversion and demonstrations.
;; Migrated from phase6_clojure_walk_cycle1.sh, phase6_16_c_walk_pattern_a.sh
;; and phase6_exit_smoke.sh with the same values and printed-line order.
(ns suites.phase6-walk-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.set :as cset]
            [clojure.walk :as walk]))

(defn- inc-ints [x]
  (if (integer? x) (inc x) x))

(deftest p6-walk-spine
  (is (= [2 3 4] (walk/walk inc identity [1 2 3])) "walk_vector_inc")
  (is (= #{} (cset/difference (walk/walk inc identity (hash-set 1 2))
                              (hash-set 2 3)))
      "walk_set_inc")
  (is (= 4 (walk/walk inc dec 5)) "walk_scalar_outer_only")
  (is (= [2 [3 4] 5] (walk/postwalk inc-ints [1 [2 3] 4])) "postwalk_nested_vector")
  (is (= 8 (walk/postwalk inc-ints 7)) "postwalk_scalar")
  (is (= [] (walk/postwalk inc-ints [])) "postwalk_empty_vector")
  (is (= [2 [3 4] 5] (walk/prewalk inc-ints [1 [2 3] 4])) "prewalk_nested_vector")
  (is (= 8 (walk/prewalk inc-ints 7)) "prewalk_scalar")
  (is (= {:a 2 :b 3} (walk/postwalk inc-ints (hash-map :a 1 :b 2)))
      "postwalk_map_values")
  (is (= [2 3 4] (walk/walk inc identity [1 2 3])) "baseline_walk"))

(deftest p6-walk-pattern-a
  (is (= [1 2 3] (walk/prewalk (fn* [x] x) [1 2 3])) "prewalk_identity_vector")
  (is (= [2 [3 4]] (walk/postwalk inc-ints [1 [2 3]])) "postwalk_inc_nested")
  (is (= [11 [21 31]] (walk/prewalk inc-ints [10 [20 30]])) "prewalk_inc_nested")
  (is (= '(1 2 3) (walk/postwalk (fn* [x] x) '(1 2 3))) "postwalk_identity_list")
  (is (= [1 2 :c] (walk/postwalk-replace {:a 1 :b 2} [:a :b :c]))
      "postwalk_replace_basic")
  (is (= [10 [10 :y]] (walk/postwalk-replace {:x 10} [:x [:x :y]]))
      "postwalk_replace_nested")
  (is (= [99 :y [99]] (walk/prewalk-replace {:x 99} [:x :y [:x]]))
      "prewalk_replace_nested")
  (is (= [:a :b] (walk/postwalk-replace {} [:a :b])) "postwalk_replace_empty_smap"))

(deftest p6-walk-key-conversion
  (is (= {:a 1 :b 2} (walk/keywordize-keys {"a" 1 "b" 2})) "keywordize_keys_flat")
  (is (= {:already 1} (walk/keywordize-keys {:already 1}))
      "keywordize_keys_preserves_keyword")
  (is (= {"x" 1 "y" 2} (walk/stringify-keys {:x 1 :y 2})) "stringify_keys_flat")
  (is (= {:a 1} (walk/keywordize-keys (walk/stringify-keys {:a 1})))
      "roundtrip_keyword_string_keyword")
  (is (= {:a 1} (walk/keywordize-keys {"a" 1})) "walk_keywordize"))

(deftest p6-walk-print-and-demo
  (let [result (atom nil)
        out (with-out-str (reset! result (println "hi")))]
    (is (= "hi\n" out) "println_basic")
    (is (nil? @result) "println_basic_return"))
  (let [result (atom nil)
        out (with-out-str (reset! result (println 1 2 3)))]
    (is (= "1 2 3\n" out) "println_multi")
    (is (nil? @result) "println_multi_return"))
  (let [result (atom nil)
        out (with-out-str (reset! result (walk/prewalk-demo [1 2])))]
    (is (= [1 2] @result) "prewalk_demo_returns_form")
    (is (= "[1 2]\n1\n2\n" out) "prewalk_demo_traversal_order"))
  (let [result (atom nil)
        out (with-out-str (reset! result (walk/postwalk-demo [1 2])))]
    (is (= [1 2] @result) "postwalk_demo_returns_form")
    (is (= "1\n2\n[1 2]\n" out) "postwalk_demo_traversal_order"))
  (is (= [1 2 3] (walk/macroexpand-all [1 2 3])) "macroexpand_all_runs"))

(deftest p6-exit-smoke-walk
  (is (= [2 [3 4]] (walk/postwalk inc-ints [1 [2 3]])) "walk_postwalk_inc"))
