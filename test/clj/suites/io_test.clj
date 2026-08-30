;; clojure.core IO-adjacent seq fns (clj parity, F-011).
(ns suites.io-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.java.io :as io]))

;; --- file-seq ---
;; Was missing entirely (`Unable to resolve symbol: 'file-seq'`), found while
;; building the nREPL dev loop, which wanted it to list suite files. Defined the
;; way the JVM does: a tree-seq over .isDirectory / .listFiles.
(deftest file-seq-walks-a-tree
  (testing "a directory yields itself plus its entries"
    (let [names (set (map #(.getName %) (file-seq (io/file "test/clj/suites"))))]
      (is (contains? names "suites"))              ; the root is included
      (is (contains? names "io_test.clj"))
      (is (contains? names "accessors_test.clj"))))
  (testing "a plain FILE yields exactly itself"
    (let [fs (file-seq (io/file "test/clj/suites/io_test.clj"))]
      (is (= 1 (count fs)))
      (is (= "io_test.clj" (.getName (first fs))))))
  (testing "it descends into subdirectories"
    ;; test/clj holds both files and the suites/ subdir, so a correct walk
    ;; reaches names that only exist one level down.
    (let [names (set (map #(.getName %) (file-seq (io/file "test/clj"))))]
      (is (contains? names "suites"))
      (is (contains? names "io_test.clj"))
      (is (contains? names "run_suites.clj")))))
