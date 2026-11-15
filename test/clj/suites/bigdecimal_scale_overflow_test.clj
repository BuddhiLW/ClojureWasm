;; CLJW-BIGDEC-SCALE-OVERFLOW. Expected messages and scales were checked
;; against OpenJDK 27 (java.math.BigDecimal), not inferred from the names.
(ns suites.bigdecimal-scale-overflow-test
  (:require [clojure.test :refer [deftest is testing]]))

(defn arithmetic-message [f]
  (try (f) :did-not-throw
       (catch ArithmeticException e (.getMessage e))))

(defn at-scale [unscaled scale]
  (BigDecimal/valueOf unscaled scale))

(deftest repeated-squaring-with-precision-is-catchable
  (is (= "Overflow"
         (try
           (with-precision 40
             (loop [z 3M i 0]
               (if (= i 34) (.scale z) (recur (* z z) (inc i)))))
           (catch ArithmeticException e (.getMessage e)))))
  (is (= -512305007
         (with-precision 40
           (loop [z 3M i 0]
             (if (= i 30) (.scale z) (recur (* z z) (inc i))))))))

(deftest multiplication-checks-both-directions-before-narrowing
  (let [lo (at-scale 1 Integer/MIN_VALUE)
        hi (at-scale 1 Integer/MAX_VALUE)]
    (is (= "Overflow" (arithmetic-message #(.multiply lo (at-scale 1 -1)))))
    (is (= "Underflow" (arithmetic-message #(.multiply hi 0.1M))))
    (is (= "Underflow" (arithmetic-message #(* hi 0.1M))))
    (testing "JVM multiply checks the receiver, not whether the product is zero"
      (is (= "Underflow" (arithmetic-message #(.multiply hi 0.0M))))
      (is (= Integer/MAX_VALUE (.scale (.multiply (at-scale 0 Integer/MAX_VALUE) 0.1M)))))))

(deftest shifts-check-boundaries-without-materializing-the-value
  (let [lo (at-scale 1 Integer/MIN_VALUE)
        hi (at-scale 1 Integer/MAX_VALUE)]
    (is (= "Overflow" (arithmetic-message #(.scaleByPowerOfTen lo 1))))
    (is (= "Underflow" (arithmetic-message #(.scaleByPowerOfTen hi -1))))
    (is (= "Overflow" (arithmetic-message #(.movePointRight lo 1))))
    (is (= "Underflow" (arithmetic-message #(.movePointLeft lo 0))))
    (is (= "Underflow" (arithmetic-message #(.movePointLeft hi 1))))
    (is (= Integer/MAX_VALUE (.scale (.scaleByPowerOfTen hi 0))))
    (is (= Integer/MIN_VALUE (.scale (.scaleByPowerOfTen lo 0))))
    (is (= Integer/MAX_VALUE (.scale (.movePointLeft hi 0)))))
  (testing "zero saturates at the scale limits"
    (let [zlo (at-scale 0 Integer/MIN_VALUE)
          zhi (at-scale 0 Integer/MAX_VALUE)]
      (is (= Integer/MIN_VALUE (.scale (.scaleByPowerOfTen zlo 1))))
      (is (= Integer/MAX_VALUE (.scale (.scaleByPowerOfTen zhi -1))))
      (is (= Integer/MAX_VALUE (.scale (.movePointLeft zhi 1))))
      (is (= 0 (.scale (.movePointRight zlo 1)))))))

(deftest setscale-and-alignment-check-the-scale-difference
  (let [lo (at-scale 1 Integer/MIN_VALUE)
        hi (at-scale 1 Integer/MAX_VALUE)]
    (is (= "BigInteger would overflow supported range"
           (arithmetic-message #(.setScale 1M Integer/MAX_VALUE))))
    (is (= "Underflow" (arithmetic-message #(.setScale lo Integer/MAX_VALUE))))
    (is (= "Underflow" (arithmetic-message #(.setScale hi Integer/MIN_VALUE BigDecimal/ROUND_DOWN))))
    (is (= "Underflow" (arithmetic-message #(.add hi lo))))
    (is (= "Underflow" (arithmetic-message #(.subtract hi lo))))
    (is (= "Underflow" (arithmetic-message #(+ hi lo))))
    (is (= "Underflow" (arithmetic-message #(- hi lo))))))

(deftest stripping-rounding-and-powers-check-derived-scales
  (let [tenlo (at-scale 10 Integer/MIN_VALUE)
        lo (at-scale 1 Integer/MIN_VALUE)
        hi (at-scale 1 Integer/MAX_VALUE)]
    (testing "construction accepts trailing zeros at MIN_VALUE; stripping does not"
      (is (= Integer/MIN_VALUE (.scale tenlo)))
      (is (= "10" (str (.unscaledValue tenlo))))
      (is (= "Overflow" (arithmetic-message #(.stripTrailingZeros tenlo)))))
    (testing "precision rounding uses JVM checkScaleNonZero's narrowed sign"
      (is (= "Underflow" (arithmetic-message #(.round tenlo (java.math.MathContext. 1)))))
      (is (= "Underflow" (arithmetic-message #(.round (at-scale 99 (inc Integer/MIN_VALUE))
                                                     (java.math.MathContext. 1))))))
    (is (= "Overflow" (arithmetic-message #(.pow lo 2))))
    (is (= "Underflow" (arithmetic-message #(.pow hi 2))))
    (is (= "Invalid operation" (arithmetic-message #(.pow 1M -1))))
    (is (= "Invalid operation" (arithmetic-message #(.pow 1M 1000000000))))))

(deftest precision-division-checks-the-final-scale
  (let [lo (at-scale 1 Integer/MIN_VALUE)
        hi (at-scale 1 Integer/MAX_VALUE)]
    (is (= -2147483647 (.scale (.divide lo 2M (java.math.MathContext. 1)))))
    (is (= "Overflow" (arithmetic-message #(.divide hi 3M (java.math.MathContext. 2)))))
    (is (= "Overflow" (arithmetic-message #(with-precision 2 (/ hi 3M)))))))

(deftest precision-division-checks-the-working-scale-even-when-exact
  (let [hi (at-scale 1 Integer/MAX_VALUE)
        lo (at-scale 1 Integer/MIN_VALUE)]
    (is (= "Overflow" (arithmetic-message #(.divide hi 1M (java.math.MathContext. 40)))))
    (is (= "Overflow" (arithmetic-message #(.divide hi 2M (java.math.MathContext. 40)))))
    (is (= Integer/MIN_VALUE (.scale (.divide lo 1M (java.math.MathContext. 40)))))
    (is (= -2147483647 (.scale (.divide lo 2M (java.math.MathContext. 40)))))
    (is (= -2147483608 (.scale (.divide lo 3M (java.math.MathContext. 40)))))))

(deftest division-and-zero-boundaries
  (let [lo (at-scale 1 Integer/MIN_VALUE)
        hi (at-scale 1 Integer/MAX_VALUE)
        zlo (at-scale 0 Integer/MIN_VALUE)
        zhi (at-scale 0 Integer/MAX_VALUE)]
    (is (= "Non-terminating decimal expansion; no exact representable decimal result."
           (arithmetic-message #(.divide hi 2M))))
    (is (= "Underflow" (arithmetic-message #(.divide 1M hi Integer/MAX_VALUE BigDecimal/ROUND_DOWN))))
    (is (= "BigInteger would overflow supported range"
           (arithmetic-message #(.divide 1M 3M Integer/MAX_VALUE BigDecimal/ROUND_HALF_UP))))
    (is (= "BigInteger would overflow supported range" (arithmetic-message #(.remainder lo 1M))))
    (is (= "Underflow" (arithmetic-message #(.toBigInteger lo))))
    (is (= Integer/MAX_VALUE (.scale (.divide zhi lo))))
    (is (= Integer/MAX_VALUE (.scale (.setScale zlo Integer/MAX_VALUE))))
    (is (= Integer/MIN_VALUE (.scale (.round zlo (java.math.MathContext. 1)))))
    (is (= Integer/MIN_VALUE (.scale (.pow zlo 2))))
    (is (= 0 (.scale (.stripTrailingZeros zlo))))))

(deftest normalized-keys-do-not-lose-value-at-the-scale-floor
  (let [ten (at-scale 10 Integer/MIN_VALUE)
        one (at-scale 1 Integer/MIN_VALUE)
        same-ten (at-scale 100 (inc Integer/MIN_VALUE))]
    (is (not= ten one))
    (is (= ten same-ten))
    (is (= 2 (count #{ten one})))
    (is (= (hash ten) (hash same-ten)))))

(deftest ordinary-scale-operations-are-unchanged
  (is (= "2.00" (str (+ 1.50M 0.5M))))
  (is (= "1.50" (str (- 3.00M 1.5M))))
  (is (= "0.50" (str (.divide 1.00M 2M))))
  (is (= "1.4400" (str (.pow 1.20M 2))))
  (is (= "1.5" (str (.stripTrailingZeros 1.500M))))
  (is (= "3.600" (str (* 1.20M 3.0M))))
  (is (= "0.1234" (str (.movePointLeft 12.34M 2))))
  (is (= "12340" (str (.movePointRight 12.34M 3))))
  (is (= "1.234E+4" (str (.scaleByPowerOfTen 12.34M 3))))
  (is (= "10" (str (.round 9.95M (java.math.MathContext. 2))))))
