;; Collection metadata propagation parity (kanban 20260906170354-0c9eff13).
;; Checked against Clojure 1.12.4: `empty` keeps the collection's meta for
;; every persistent collection, PersistentList `conj` keeps it, a dissoc that
;; empties an array map keeps it, and sorted maps/sets are IObj.
(ns suites.coll-parity-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest empty-keeps-meta
  (is (= {:m 1} (meta (empty (with-meta [1] {:m 1})))))
  (is (= {:m 1} (meta (empty (with-meta (subvec [1 2 3] 1) {:m 1})))))
  (is (= {:m 1} (meta (empty (with-meta {:a 1} {:m 1})))))
  (is (= {:m 1} (meta (empty (with-meta #{1} {:m 1})))))
  (is (= {:m 1} (meta (empty (with-meta '(1) {:m 1})))))
  (is (= {:m 1} (meta (empty (with-meta (sorted-map 1 2) {:m 1})))))
  (is (= {:m 1} (meta (empty (with-meta (sorted-set 1) {:m 1})))))
  (testing "a generic seq empties to a meta-less ()"
    (is (nil? (meta (empty (with-meta (lazy-seq [1]) {:m 1})))))))

(deftest sorted-colls-are-iobj
  (is (= {:m 1} (meta (with-meta (sorted-map 1 2) {:m 1}))))
  (is (= {:m 1} (meta (with-meta (sorted-set 1) {:m 1}))))
  (is (= {1 2} (with-meta (sorted-map 1 2) {:m 1})))
  (is (= {:m 1} (meta (assoc (with-meta (sorted-map 1 2) {:m 1}) 3 4))))
  (is (= {:m 1} (meta (conj (with-meta (sorted-set 1) {:m 1}) 2)))))

(deftest conj-and-dissoc-keep-meta
  (is (= {:m 1} (meta (conj (with-meta '(1) {:m 1}) 2))))
  (is (= '(2 1) (conj (with-meta '(1) {:m 1}) 2)))
  (is (= {:m 1} (meta (dissoc (with-meta {:a 1} {:m 1}) :a))))
  (is (= {:m 1} (meta (conj (with-meta [1] {:m 1}) 2))))
  (is (= {:m 1} (meta (conj (with-meta #{} {:m 1}) 1)))))

(deftest indexed-contains-and-get
  (testing "contains? on a String truncates a Number key; a non-number throws"
    (is (true? (contains? "abc" 1.5)))
    (is (true? (contains? "abc" 1N)))
    (is (false? (contains? "abc" 5.0)))
    (is (thrown? IllegalArgumentException (contains? "abc" :a)))
    (is (thrown? IllegalArgumentException (contains? "abc" nil))))
  (testing "get on a Java array indexes it"
    (is (= 2 (get (int-array [1 2]) 1)))
    (is (= 1 (get (object-array [1 2]) 0)))
    (is (= :nf (get (int-array [1 2]) 5 :nf)))
    (is (nil? (get (int-array [1 2]) -1)))
    (is (nil? (get (int-array [1 2]) :a)))))

(deftest sorted-seqs-are-not-lists
  (is (false? (list? (seq (sorted-map 1 2)))))
  (is (false? (list? (seq (sorted-set 1 2)))))
  (is (false? (list? (rseq (sorted-set 1 2)))))
  (is (false? (list? (rest (sorted-set 1 2 3)))))
  (is (false? (list? (keys (sorted-map 1 2)))))
  (is (false? (list? (subseq (sorted-set 1 2 3) > 1))))
  (is (true? (seq? (seq (sorted-set 1)))))
  (is (= '(0 1 2) (conj (seq (sorted-set 1 2)) 0)))
  (is (= '(3 2 1) (rseq (sorted-set 1 2 3)))))

(deftest keys-vals-on-non-map-seqables
  (is (nil? (keys #{})))
  (is (nil? (keys "")))
  (is (nil? (vals "")))
  (is (nil? (keys (sorted-set))))
  (is (nil? (vals [])))
  (is (thrown? ClassCastException (vec (keys #{1}))))
  (is (thrown? ClassCastException (vec (keys [1])))))
