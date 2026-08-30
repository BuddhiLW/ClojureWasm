;; Map-entry accessor + associative-arg parity (clj parity, F-011).
;;
;; Run by `test/clj/run_suites.clj` — one cljw process for the whole file,
;; instead of one process per assertion the way the bash e2e tier works.
(ns suites.accessors-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- key / val require an actual map entry ---
;; cljw's map entries are a DISTINCT type, so `key`/`val` throw on a plain
;; vector / nil / list the way clj does (a 2-vector is not a Map$Entry).
(deftest key-val
  (testing "on a real map entry (from seq-ing a map)"
    (is (= :a (key (first {:a 1}))))
    (is (= 1  (val (first {:a 1}))))
    (is (= '(:a :b) (map key {:a 1 :b 2})))
    (is (= 3 (reduce (fn [acc e] (+ acc (val e))) 0 {:a 1 :b 2}))))
  (testing "a non-entry throws — plain vector / nil / list"
    (is (thrown? Throwable (key [:k :v])))
    (is (thrown? Throwable (val [:k :v])))
    (is (thrown? Throwable (key nil)))
    (is (thrown? Throwable (val nil)))
    (is (thrown? Throwable (key '(1 2))))))

;; --- EVERY map producer yields map entries, sorted ones included ---
;; The sorted walkers used to build plain 2-vectors, so `(key (first
;; (sorted-map …)))` threw while the hash-map path worked. AD-032 promises a
;; cljw MapEntry for these seq-views; this locks all four producers together.
(deftest map-entry-producers
  (testing "map-entry? holds across hash / sorted / java surfaces"
    (is (map-entry? (first {:a 1})))
    (is (map-entry? (first (sorted-map :a 1))))
    (is (map-entry? (first (seq (java.util.HashMap. {1 :a})))))
    (is (map-entry? (first (seq (java.util.TreeMap. {1 :a}))))))
  (testing "an entry is also a vector, as in clj"
    (is (vector? (first (sorted-map :a 1)))))
  (testing "rseq / subseq / rsubseq walkers too"
    (is (map-entry? (first (rseq (sorted-map :a 1 :b 2)))))
    (is (map-entry? (first (subseq (sorted-map 1 :a 2 :b 3 :c) >= 2))))
    (is (map-entry? (first (rsubseq (sorted-map 1 :a 2 :b 3 :c) <= 2)))))
  (testing "so key/val work over every one of them"
    (is (= '(:a :b) (map key (seq (sorted-map :b 2 :a 1)))))
    (is (= '(1 2) (map val (seq (sorted-map :b 2 :a 1)))))
    (is (= '(:b :a) (map key (rseq (sorted-map :a 1 :b 2)))))
    (is (= '(1 2 3) (map key (seq (java.util.TreeMap. {3 :c 1 :a 2 :b})))))
    (is (= '(:a :b :c) (map val (seq (java.util.TreeMap. {3 :c 1 :a 2 :b})))))))

;; --- select-keys: associative-or-nil, else throw ---
;; JVM RT/find casts a non-Associative, non-nil arg to Map, so a string / list
;; / number throws rather than silently answering {}.
(deftest select-keys-associative
  (testing "associative and nil arguments"
    (is (= {:a 1 :c 3} (select-keys {:a 1 :b 2 :c 3} [:a :c])))
    (is (= {} (select-keys nil [:a])))
    (is (= {0 10 2 30} (select-keys [10 20 30] [0 2])))
    (is (= {} (select-keys {:a 1} []))))
  (testing "a non-associative argument throws"
    (is (thrown? Throwable (select-keys "" [:a])))
    (is (thrown? Throwable (select-keys '(1 2) [0])))
    (is (thrown? Throwable (select-keys 5 [:a])))))

;; --- merge reduces with conj, so a 2-vector arg is added AS an entry ---
(deftest merge-conj-semantics
  (is (= {:a 9 :b 2} (merge {:a 1} {:b 2} {:a 9})))
  (is (= {:a 1 :b 2} (merge {:a 1} [:b 2])))
  (is (= {:a 1 :b 2} (merge {:a 1} (first {:b 2}))))
  (is (= {:a 1} (merge nil {:a 1})))
  (is (= {:a 1} (merge {:a 1} nil)))
  (is (nil? (merge))))
