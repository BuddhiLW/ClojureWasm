;; Set and map literals, clojure.set groups A through C and core helpers.
;; Migrated from phase6_clojure_set_*.sh, phase6_set_map_literal.sh and
;; phase6_exit_smoke.sh with the same expected values and order tolerance.
(ns suites.phase6-set-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.set :as cset]))

(defn- permutation?
  "Same rendering alternatives as the shell case patterns."
  [expected actual]
  (and (= (count expected) (count actual))
       (every? (set expected) actual)
       (= (count expected) (count (set actual)))))

(deftest p6-hash-set-and-relations
  (is (permutation? [1 2 3] (vec (hash-set 1 2 3))) "hash_set_three_ints")
  (is (= #{} (hash-set)) "hash_set_empty")
  (is (true? (cset/subset? (hash-set 1 2) (hash-set 1 2 3))) "subset_true")
  (is (false? (cset/subset? (hash-set 1 4) (hash-set 1 2 3))) "subset_false")
  (is (true? (cset/subset? (hash-set) (hash-set 1 2))) "subset_empty")
  (is (true? (cset/superset? (hash-set 1 2 3) (hash-set 1 2))) "superset_true")
  (is (false? (cset/superset? (hash-set 1) (hash-set 1 2))) "superset_false")
  (is (true? (cset/subset? (hash-set 1 2 3)
                           (cset/union (hash-set 1 2) (hash-set 2 3))))
      "union_via_subset")
  (is (true? (cset/subset? (cset/union (hash-set 1 2) (hash-set 2 3))
                           (hash-set 1 2 3)))
      "union_no_extras")
  (is (= #{} (cset/union (hash-set))) "union_single_empty")
  (is (= #{7} (cset/union (hash-set 7))) "union_single_one")
  (let [got (cset/intersection (hash-set 1 2 3) (hash-set 2 3 4))]
    (is (true? (cset/subset? got (hash-set 2 3))) "intersection_subset_of_expected")
    (is (true? (cset/subset? (hash-set 2 3) got)) "intersection_superset_of_expected"))
  (is (= #{} (cset/intersection (hash-set 1) (hash-set 9))) "intersection_disjoint")
  (let [got (cset/difference (hash-set 1 2 3) (hash-set 2))]
    (is (true? (cset/subset? got (hash-set 1 3))) "difference_subset_of_expected")
    (is (true? (cset/subset? (hash-set 1 3) got)) "difference_superset_of_expected"))
  (is (= #{} (cset/difference (hash-set 1 2) (hash-set 1 2 3))) "difference_to_empty"))

(deftest p6-map-constructor-rename-and-invert
  (is (= {:a 1} (hash-map :a 1)) "hash_map_one_entry")
  (is (= {} (hash-map)) "hash_map_empty")
  (is (= {:b 2 :A 1} (cset/rename-keys (hash-map :a 1 :b 2) (hash-map :a :A)))
      "rename_keys_simple")
  (is (= {:b 2 :a 1}
         (cset/rename-keys (cset/rename-keys (hash-map :a 1 :b 2) (hash-map :a :A))
                           (hash-map :A :a)))
      "rename_keys_round_trip")
  (is (= {:a 1} (cset/rename-keys (hash-map :a 1) (hash-map :missing :gone)))
      "rename_keys_absent_source")
  (is (= {:b 1} (cset/rename-keys (hash-map :a 1 :b 2) (hash-map :a :b)))
      "rename_keys_collision")
  (is (= {:x 9} (cset/rename-keys (hash-map :x 9) (hash-map))) "rename_keys_empty_rename")
  (is (= {:a 1 :b 2} (cset/map-invert (cset/map-invert (hash-map :a 1 :b 2))))
      "map_invert_round_trip")
  (is (= {} (cset/map-invert (hash-map))) "map_invert_empty")
  (is (= {:y :x} (cset/map-invert (hash-map :x :y))) "map_invert_keyword_pair"))

(deftest p6-core-helpers-and-set-group-c
  (is (= {:a 1 :c 3} (select-keys {:a 1 :b 2 :c 3} [:a :c])) "sk_basic")
  (is (= {:a 1} (select-keys {:a 1} [:a :missing])) "sk_missing")
  (is (= {} (select-keys {:a 1} [])) "sk_empty")
  (is (= {:a 1 :b 2} (merge {:a 1} {:b 2})) "merge_basic")
  (is (= {:a 2} (merge {:a 1} {:a 2})) "merge_right")
  (is (= {:a 1} (merge nil {:a 1})) "merge_nil_l")
  (is (= {:a 1} (merge {:a 1} nil)) "merge_nil_r")
  (is (= #{1 2 3} (set [1 2 3])) "set_of_list")
  (is (= #{1 2 3} (set [1 2 2 3 3])) "set_dedup")
  (is (= #{:a :b} (set (keys {:a 1 :b 2}))) "set_of_keys")
  (is (= #{2 4} (cset/select pos? #{-1 2 -3 4})) "select_pos")
  (is (= #{1 2 3} (cset/select pos? #{1 2 3})) "select_all")
  (is (= #{} (cset/select pos? #{-1 -2})) "select_none")
  (is (= #{{:a 1} {:a 3}} (cset/project #{{:a 1 :b 2} {:a 3 :b 4}} [:a]))
      "project_basic")
  (is (= 2 (count (cset/project #{{:a 1 :b 2} {:a 3 :b 9}} [:a]))) "project_dedup_vec")
  (is (= #{{:A 1} {:A 2}} (cset/rename #{{:a 1} {:a 2}} {:a :A})) "rename_basic")
  (is (= 3 (count (cset/index #{{:a 1 :b 10} {:a 2 :b 20} {:a 3 :b 30}} [:a])))
      "index_basic")
  (is (= #{} (cset/join #{} #{{:a 1}})) "join_empty"))

(deftest p6-set-and-map-literals
  (is (= #{1 2 3} #{1 2 3}) "set_three_ints")
  (is (= #{} #{}) "set_empty")
  (is (= 3 (count #{:a :b :c})) "set_count")
  (is (true? (contains? #{:a :b} :a)) "set_contains")
  (is (thrown-with-msg? Throwable #"Duplicate key: 1" (load-string "#{1 1 2}"))
      "set_duplicates")
  (is (= 3 (count (set [1 1 2 2 3]))) "set_dedup_fn")
  (is (true? (cset/subset? #{1 2} #{1 2 3})) "set_subset")
  (is (= {:a 1} {:a 1}) "map_one_entry")
  (is (= {} {}) "map_empty")
  (is (= 3 (count {:a 1 :b 2 :c 3})) "map_count")
  (is (= 1 (get {:a 1 :b 2} :a)) "map_get")
  (is (= 2 (count (keys {:a 1 :b 2}))) "map_keys")
  (is (= 3 (count (get {:s #{1 2 3}} :s))) "set_in_map")
  (is (= 2 (count #{{:a 1} {:b 2}})) "map_in_set")
  (is (= 3 (count (get {:v [1 2 3]} :v))) "vector_in_map")
  (is (= #{1 2 3} (cset/union #{1 2} #{2 3})) "union_literals")
  (is (= {:b 2 :A 1} (cset/rename-keys {:a 1 :b 2} {:a :A})) "rename_literal")
  (is (= {1 :a 2 :b} (cset/map-invert {:a 1 :b 2})) "invert_literal")
  (is (= 2 (count #{(+ 1 1) (+ 2 0) 3})) "set_evals_inside")
  (is (= 20 (get {(+ 0 1) (+ 10 10)} 1)) "map_evals_inside")
)

(deftest p6-exit-smoke-set-and-core
  (is (permutation? [1 2 3] (vec (cset/union #{1 2} #{2 3}))) "set_union")
  (is (= #{1 2} (cset/union (hash-set 1) (hash-set 2))) "baseline_set_union")
  (is (= 15 (reduce + 0 [1 2 3 4 5])) "core_reduce")
  (is (= '(2 3 4) (map inc [1 2 3])) "core_map_inc")
  (is (= '(1 2) (filter pos? [-1 0 1 2])) "core_filter_pos")
  (is (= "123" (re-find #"\d+" "abc123")) "regex_find")
  (is (= "hello" (re-matches #"[a-z]+" "hello")) "regex_matches")
  (is (re-matches #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                  (str (random-uuid)))
      "random_uuid_format"))
