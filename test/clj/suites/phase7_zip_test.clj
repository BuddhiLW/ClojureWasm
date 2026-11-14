;; clojure.zip constructors, navigation, traversal and mutation.
;; Migrated from phase7_zip_cycle{1,2,3,4}.sh with the same expected values.
(ns suites.phase7-zip-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.zip :as z]))

(deftest p7-zip-constructors-and-accessors
  (is (= [1 2 3] (z/node (z/vector-zip [1 2 3]))) "vector_zip_node")
  (is (= '(1 2 3) (z/node (z/seq-zip '(1 2 3)))) "seq_zip_node")
  (is (= {:tag :a :content [1 2]} (z/node (z/xml-zip {:tag :a :content [1 2]})))
      "xml_zip_node")
  (is (z/branch? (z/vector-zip [1 2 3])) "vector_zip_branch")
  (is (= '(1 2 3) (z/children (z/vector-zip [1 2 3]))) "vector_zip_children")
  (is (= [4 5 6] (z/make-node (z/vector-zip [1 2 3]) :ignored [4 5 6])) "make_node_vector")
  (is (z/zip-loc? (z/vector-zip [1 2 3])) "zip_loc_true")
  (is (false? (z/zip-loc? 42)) "zip_loc_false")
  (is (z/vector-zip? (z/vector-zip [1 2 3])) "vector_zip_pred_true")
  (is (false? (z/vector-zip? (z/seq-zip '(1)))) "vector_zip_pred_false")
  (is (z/seq-zip? (z/seq-zip '(1))) "seq_zip_pred_true")
  (is (z/xml-zip? (z/xml-zip {:tag :a})) "xml_zip_pred_true")
  (is (instance? ZipLoc (z/vector-zip [1 2 3])) "instance_zip_loc"))

(deftest p7-zip-navigation
  (is (= 10 (z/node (z/down (z/vector-zip [10 20 30])))) "down_node")
  (is (nil? (z/down (z/vector-zip 42))) "down_leaf_nil")
  (is (= 20 (z/node (z/right (z/down (z/vector-zip [10 20 30]))))) "right_node")
  (is (= 10 (z/node (z/left (z/right (z/down (z/vector-zip [10 20 30])))))) "left_node")
  (is (nil? (z/right (z/right (z/right (z/down (z/vector-zip [1 2 3]))))))
      "right_past_end_nil")
  (is (= [10 20 30] (z/node (z/up (z/down (z/vector-zip [10 20 30]))))) "up_to_root")
  (is (nil? (z/up (z/vector-zip [10 20 30]))) "up_at_root_nil")
  (is (= [10 20 30] (z/root (z/right (z/down (z/vector-zip [10 20 30]))))) "root_value")
  (is (= 10 (z/node (z/leftmost (z/right (z/right (z/down (z/vector-zip [10 20 30])))))))
      "leftmost")
  (is (= 30 (z/node (z/rightmost (z/down (z/vector-zip [10 20 30]))))) "rightmost")
  (is (= '(10 20) (z/lefts (z/right (z/right (z/down (z/vector-zip [10 20 30 40]))))))
      "lefts_field")
  (is (= '(30 40) (z/rights (z/right (z/down (z/vector-zip [10 20 30 40])))))
      "rights_field")
  (is (= [[10 [20 30] 40] [20 30]]
         (z/path (z/down (z/right (z/down (z/vector-zip [10 [20 30] 40]))))))
      "path_chain"))

(deftest p7-zip-traversal
  (is (false? (z/end? (z/vector-zip [1 2 3]))) "end_fresh_false")
  (is (= 1 (z/node (z/next (z/vector-zip [1 2 3])))) "next_first_child")
  (is (= [[1 [2 3] 4] 1 [2 3] 2 3 4]
         (loop* [loc (z/vector-zip [1 [2 3] 4]) acc []]
           (if (z/end? loc)
             acc
             (recur (z/next loc) (conj acc (z/node loc))))))
      "dfs_full_walk")
  (is (true? (loop* [loc (z/vector-zip [1])]
               (if (z/end? loc)
                 (z/end? (z/next loc))
                 (recur (z/next loc)))))
      "next_past_end_fixed")
  (is (= 3 (z/node (z/prev (z/right (z/right (z/down (z/vector-zip [1 [2 3] 4])))))))
      "prev_to_rightmost_descendant")
  (is (= [1 2 3] (z/node (z/prev (z/down (z/vector-zip [1 2 3]))))) "prev_to_parent"))

(deftest p7-zip-mutation
  (is (= [99 2 3] (z/root (z/replace (z/down (z/vector-zip [1 2 3])) 99)))
      "replace_first_child")
  (is (= [11 2 3] (z/root (z/edit (z/down (z/vector-zip [1 2 3])) + 10)))
      "edit_with_arg")
  (is (= [111 2 3] (z/root (z/edit (z/down (z/vector-zip [1 2 3])) + 10 100)))
      "edit_with_two_args")
  (is (= [0 1 2 3] (z/root (z/insert-child (z/vector-zip [1 2 3]) 0)))
      "insert_child_prepend")
  (is (= [1 2 3 4] (z/root (z/append-child (z/vector-zip [1 2 3]) 4)))
      "append_child")
  (is (= [1 99 2 3] (z/root (z/insert-right (z/down (z/vector-zip [1 2 3])) 99)))
      "insert_right")
  (is (= [1 99 2 3]
         (z/root (z/insert-left (z/right (z/down (z/vector-zip [1 2 3]))) 99)))
      "insert_left")
  (is (thrown-with-msg? Exception #"insert-right at root has no parent"
        (z/insert-right (z/vector-zip [1 2 3]) 99))
      "insert_right_root_raises")
  (is (= [2 3] (z/root (z/remove (z/down (z/vector-zip [1 2 3]))))) "remove_first_child")
  (is (= [1 3] (z/root (z/remove (z/right (z/down (z/vector-zip [1 2 3]))))))
      "remove_middle_child")
  (is (= [10 [20 30] 40]
         (loop* [loc (z/vector-zip [1 [2 3] 4])]
           (if (z/end? loc)
             (z/root loc)
             (let* [n (z/node loc)]
               (if (z/branch? loc)
                 (recur (z/next loc))
                 (recur (z/next (z/replace loc (* n 10)))))))))
      "walk_and_edit_leaves"))
