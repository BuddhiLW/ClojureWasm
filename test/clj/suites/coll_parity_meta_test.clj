;; Collection metadata propagation parity (kanban 20260906170354-0c9eff13).
;; Checked against Clojure 1.12.4: `empty` keeps the collection's meta for
;; every persistent collection, PersistentList `conj` keeps it, a dissoc that
;; empties an array map keeps it, and sorted maps/sets are IObj.
(ns suites.coll-parity-meta-test
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
