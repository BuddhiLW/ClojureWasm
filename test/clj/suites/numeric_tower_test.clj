;; quot / rem / mod across the full numeric tower (Long / BigInt / Ratio /
;; Float) + int / long coercion of BigInt / Ratio / BigDecimal.
;;
;; Migrated from test/e2e/phase14_quot_rem_mod_tower.sh — the bash tier
;; compared the PRINTED form of each expression, so every value case here
;; asserts `pr-str` rather than `=`: `(= 3 3N)` is true in the numeric tower,
;; so a bare `=` would not catch a Long leaking where a BigInt is required
;; (the whole point of `quot_bigint` / `quot_ratio`). `##NaN` also compares
;; false to itself, so only the printed form pins it.
;;
;; Grounded against JVM Clojure (clj oracle): quot of a ratio/bigint operand
;; is a BigInt (prints N); rem / mod of a ratio stay a Ratio; divide-by-zero
;; throws for every category incl. float (unlike `/`, which yields IEEE Inf
;; on the float path). Closes D-169 / D-170.
(ns suites.numeric-tower-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- quot across the tower ---
(deftest quot-tower
  (testing "integer / bigint / mixed"
    (is (= "3"  (pr-str (quot 10 3))))            ; quot_long
    (is (= "3N" (pr-str (quot 10N 3N))))          ; quot_bigint
    (is (= "3N" (pr-str (quot 10 3N)))))          ; quot_mixed
  (testing "float and ratio operands"
    (is (= "3.0" (pr-str (quot 10.0 3))))         ; quot_float
    (is (= "4N"  (pr-str (quot 17/2 2))))         ; quot_ratio
    (is (= "3.0" (pr-str (quot 10.5 3)))))        ; quot_floor
  (testing "truncation toward zero on either sign"
    (is (= "-2" (pr-str (quot -7 3))))            ; quot_neg
    (is (= "-2" (pr-str (quot 7 -3))))))          ; quot_neg_div

;; --- rem across the tower (sign of dividend) ---
(deftest rem-tower
  (testing "integer / bigint"
    (is (= "1"  (pr-str (rem 10 3))))             ; rem_long
    (is (= "1N" (pr-str (rem 10N 3N)))))          ; rem_bigint
  (testing "float and ratio operands — a ratio rem stays a Ratio"
    (is (= "1.0" (pr-str (rem 10.0 3))))          ; rem_float
    (is (= "1/2" (pr-str (rem 17/2 2))))          ; rem_ratio
    (is (= "1.5" (pr-str (rem 10.5 3)))))         ; rem_float_frac
  (testing "the result takes the sign of the DIVIDEND"
    (is (= "-1" (pr-str (rem -7 3))))             ; rem_neg
    (is (= "1"  (pr-str (rem 7 -3))))))           ; rem_neg_div

;; --- mod across the tower (sign of divisor) ---
(deftest mod-tower
  (testing "integer / bigint"
    (is (= "1"  (pr-str (mod 10 3))))             ; mod_long
    (is (= "1N" (pr-str (mod 10N 3N)))))          ; mod_bigint
  (testing "float and ratio operands — a ratio mod stays a Ratio"
    (is (= "1.0" (pr-str (mod 10.0 3))))          ; mod_float
    (is (= "1/2" (pr-str (mod 17/2 2))))          ; mod_ratio
    (is (= "1.5" (pr-str (mod 10.5 3)))))         ; mod_float_frac
  (testing "the result takes the sign of the DIVISOR"
    (is (= "2"  (pr-str (mod -7 3))))             ; mod_neg
    (is (= "-2" (pr-str (mod 7 -3))))))           ; mod_neg_div

;; --- non-finite operands ---
;; cljw's single-f64 tower (F-005) returns NaN uniformly for quot/rem/mod
;; (AD-018). JVM Clojure THROWS NumberFormatException here (its double
;; remainder routes a NaN quotient through new BigDecimal(NaN)); cljw does not
;; reproduce that fallback. mod must NOT panic (was numSign's std.math.order
;; unreachable). +/-Inf DIVIDEND: clj throws (non-finite quotient); cljw
;; returns the non-finite result. An Inf DIVISOR over a finite dividend agrees
;; (0 quotient -> NaN both).
(deftest non-finite-operands
  (testing "a NaN operand propagates rather than throwing or panicking"
    (is (= "##NaN" (pr-str (quot ##NaN 3))))      ; quot_nan
    (is (= "##NaN" (pr-str (rem ##NaN 3))))       ; rem_nan
    (is (= "##NaN" (pr-str (mod ##NaN 3))))       ; mod_nan_d
    (is (= "##NaN" (pr-str (mod 3 ##NaN)))))      ; mod_nan_v
  (testing "an infinite dividend"
    (is (= "##Inf"  (pr-str (quot ##Inf 3))))     ; quot_inf
    (is (= "##NaN"  (pr-str (rem ##Inf 3))))      ; rem_inf
    (is (= "##NaN"  (pr-str (mod ##Inf 3))))      ; mod_inf
    (is (= "##-Inf" (pr-str (quot ##-Inf 3))))))  ; quot_ninf

;; --- divide-by-zero throws for every category (incl. float — unlike `/`) ---
(deftest divide-by-zero
  (is (thrown-with-msg? Throwable #"Divide by zero" (quot 3N 0)))   ; quot_zero
  (is (thrown-with-msg? Throwable #"Divide by zero" (rem 10 0)))    ; rem_zero
  (is (thrown-with-msg? Throwable #"Divide by zero" (mod 10 0)))    ; mod_zero
  (is (thrown-with-msg? Throwable #"Divide by zero" (quot 10.0 0)))); quot_fzero

;; --- int / long coercion across the tower ---
;; Both truncate toward zero, and both narrow to a Long-printing value.
(deftest int-long-coercion
  (testing "int"
    (is (= "5"  (pr-str (int 5N))))               ; int_bigint
    (is (= "3"  (pr-str (int 7/2))))              ; int_ratio
    (is (= "-3" (pr-str (int -7/2))))             ; int_ratio_neg
    (is (= "3"  (pr-str (int 3.9))))              ; int_float
    (is (= "10" (pr-str (int 10.5M)))))           ; int_bigdec
  (testing "long"
    (is (= "5" (pr-str (long 5N))))               ; long_bigint
    (is (= "3" (pr-str (long 7/2))))))            ; long_ratio
