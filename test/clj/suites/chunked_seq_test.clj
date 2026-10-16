;; Chunk-preserving map / filter / keep + chunked reduce / count
;; (§9.2.S D-163 / ADR-0065).
;;
;; map/filter/keep over a chunked source (a range seq) emit a `chunked_cons`
;; in the JVM chunk-cons shape, so the per-element lazy-seq machinery is
;; amortised 32x; reduce and count drain a whole chunk per step.
;;
;; The chunk size is 32, so the counts below straddle the boundary on purpose:
;; 1 (partial), 32 (exact), 33 (one over), 65 (two chunks plus one).
;; Chunking must never change WHAT is produced, only how often the lazy
;; machinery runs, and it must not over-realise a lazy source.
;;
;; Migrated from test/e2e/phase14_chunked_seq.sh; each assertion keeps its
;; bash case name.
(ns suites.chunked-seq-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest counts-straddle-the-chunk-boundary
  (is (= 1 (count (map inc (range 1)))))                    ; cnt_map_1
  (is (= 32 (count (map inc (range 32)))))                  ; cnt_map_32
  (is (= 33 (count (map inc (range 33)))))                  ; cnt_map_33
  (is (= 65 (count (map inc (range 65)))))                  ; cnt_map_65
  (is (= 1000 (count (map inc (range 1000))))))             ; cnt_map_1000

(deftest filter-keep-and-remove-chunk-too
  (is (= 500 (count (filter even? (range 1000)))))                          ; cnt_filt_1000
  (is (= 32 (count (keep (fn* [x] (if (even? x) x nil)) (range 64)))))      ; cnt_keep
  (is (= 32 (count (remove even? (range 64))))))                            ; cnt_remove

(deftest reduce-drains-a-chunk-per-step
  (is (= 5050 (reduce + (map inc (range 100)))))                            ; red_map
  (is (= 2500 (reduce + 0 (map inc (filter even? (range 100)))))))          ; red_nested

(deftest indexed-access-and-equality-are-unchanged
  (is (= 51 (nth (map inc (range 100)) 50)))                ; nth_map
  (is (= 100 (last (map inc (range 100)))))                 ; last_map
  (is (true? (= (map inc (range 40)) (range 1 41)))))       ; eq_map_range

;; chunking must not over-realise: taking 5 from a million-element source, or
;; from an INFINITE one, must still terminate
(deftest chunking-does-not-defeat-laziness
  (is (= [1 2 3 4 5] (into [] (take 5 (map inc (range 1000000))))))  ; lazy_map_take
  (is (= [1 3 5 7 9] (into [] (take 5 (filter odd? (range))))))      ; lazy_filt_take
  (is (= 33 (count (into [] (map inc (range 33)))))))                ; into_map_33

;; a chunked_cons still PRINTS as an ordinary seq
(deftest a-chunked-cons-prints-as-a-seq
  (is (= "(0 1 2)" (str (seq (range 3)))))                  ; print_chunked_cons
  (is (= "(1 2 3 4)" (str (rest (range 5)))))               ; print_cc_rest
  (is (= "[(0 1 2)]" (pr-str [(seq (range 3))]))))          ; print_cc_nested
