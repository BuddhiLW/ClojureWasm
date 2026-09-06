;; test/e2e/phase14_arrays.sh
;;
;; ADR-0105 / D-287 — Java arrays. Type-erased uniform []Value over
;; cljw.internal/__array-make + aget/aset/alength/aclone; the clojure.core surface
;; (object-array / int-array / byte-array / make-array / to-array / aset-* /
;; amap / areduce) composed in core.clj. Per-constructor init defaults +
;; byte/short/char wrap give clj-faithful VALUES (F-011); element type erased
;; (AD-019); identity equality; simple class name (AD-003).

;; Migrated from test/e2e/phase14_arrays.sh. Original named assertions retain
;; their exact printed expectations.
(ns suites.arrays-test
  (:require [clojure.test :refer [deftest is]]))

(deftest arrays-cases
  (is (= ":x" (pr-str (let [a (object-array 3)] (aset a 1 :x) (aget a 1)))) "aset_aget")
  (is (= "4" (pr-str (alength (object-array 4)))) "alength")
  (is (= "[9 7]" (pr-str (let [a (int-array [7 7]) b (aclone a)] (aset a 0 9) [(aget a 0) (aget b 0)]))) "aclone_independent")
  (is (= "[nil nil]" (pr-str (vec (object-array 2)))) "object_array_nil")
  (is (= "[0 0]" (pr-str (vec (int-array 2)))) "int_array_zero")
  (is (= "[0.0 0.0]" (pr-str (vec (double-array 2)))) "double_array_zero")
  (is (= "[false false]" (pr-str (vec (boolean-array 2)))) "boolean_array_false")
  (is (= "[1 2 44]" (pr-str (vec (byte-array [1 2 300])))) "byte_array_wrap")
  (is (= "-56" (pr-str (let [a (byte-array 1)] (aset-byte a 0 200) (aget a 0)))) "aset_byte_wrap")
  (is (= "[:a :b :c]" (pr-str (vec (object-array [:a :b :c])))) "object_array_from_seq")
  (is (= "[1 2 3]" (pr-str (vec (seq (int-array [1 2 3]))))) "seq_over_array")
  (is (= "3" (pr-str (count (int-array [1 2 3])))) "count_array")
  (is (= "[2 3 4]" (pr-str (vec (map inc (int-array [1 2 3]))))) "map_over_array")
  (is (= "6" (pr-str (reduce + (int-array [1 2 3])))) "reduce_over_array")
  (is (= ":b" (pr-str (nth (object-array [:a :b]) 1))) "nth_array")
  (is (= ":none" (pr-str (nth (object-array [:a]) 9 :none))) "nth_array_default")
  (is (= "5" (pr-str (alength (make-array nil 5)))) "make_array_1d")
  (is (= "[2 3]" (pr-str (let [m (make-array nil 2 3)] [(alength m) (alength (aget m 0))]))) "make_array_2d")
  (is (= "[2 4 6]" (pr-str (vec (amap (int-array [1 2 3]) i r (* 2 (aget r i)))))) "amap")
  (is (= "6" (pr-str (areduce (int-array [1 2 3]) i r 0 (+ r (aget (int-array [1 2 3]) i))))) "areduce")
  (is (= "[1 2 3]" (pr-str (vec (to-array [1 2 3])))) "to_array")
  (is (= "[4 5]" (pr-str (vec (into-array [4 5])))) "into_array")
  (is (= "false" (pr-str (= (object-array 1) (object-array 1)))) "array_identity_neq")
  (is (= "true" (pr-str (let [a (object-array 1)] (= a a)))) "array_self_eq")
  (is (= "true" (pr-str (array? (object-array 0)))) "array_pred")
  (is (= "false" (pr-str (array? [1 2]))) "array_pred_neg")
  (is (= "array" (pr-str (class (object-array 0)))) "array_class_simple")
  (is (= "65" (pr-str (let [^"[B" b (byte-array 1)] (aset b 0 65) (aget b 0)))) "type_hint_advisory"))
