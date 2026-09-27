;; The java.lang.Number instance methods on Long, Double, BigInt and Ratio:
;; .intValue / .longValue / .shortValue / .byteValue / .doubleValue /
;; .floatValue, plus the per-class .compareTo / .equals / .hashCode and the
;; Double .isNaN / .isInfinite instance predicates (CLJW-NUMBER-VALUE-METHODS).
;;
;; Every expected value is JVM Clojure's, measured with `clojure -M`. Narrowing
;; is JLS: int/short/byte keep the low bits of a Long or BigInt; a Double
;; truncates toward zero and saturates, NaN giving 0. The one exception is
;; `.floatValue`: cljw has no f32 value (AD-004), so it answers what
;; `(float x)` does, the double itself.
;;
;; Run by `test/clj/run_suites.clj`.
(ns suites.number-value-methods-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest long-narrowing
  (is (= 5 (.longValue 5)))
  (is (= 5 (.intValue 5)))
  (is (= 4464 (.shortValue 70000)))
  (is (= 44 (.byteValue 300)))
  (is (= 1 (.intValue 4294967297)))
  (is (= 2147483647 (.intValue -2147483649)))
  (is (= 127 (.byteValue -129)))
  (is (= 9007199254740993 (.longValue 9007199254740993)))
  (is (= 5.0 (.doubleValue 5)))
  (is (= 5.0 (.floatValue 5))))

(deftest double-narrowing
  (is (= 3 (.intValue 3.9)))
  (is (= -3 (.intValue -3.9)))
  (is (= -3 (.shortValue -3.9)))
  (is (= -56 (.byteValue 200.7)))
  (is (= 5 (.longValue 5.5)))
  (testing "NaN gives 0, infinities and huge values saturate"
    (is (= 0 (.intValue ##NaN)))
    (is (= 9223372036854775807 (.longValue ##Inf)))
    (is (= -9223372036854775808 (.longValue ##-Inf)))
    (is (= 9223372036854775807 (.longValue 1.0E300)))
    (is (= 2147483647 (.intValue 1.0E20)))
    (is (= -1 (.shortValue 1.0E10)))
    (is (= -1 (.byteValue 1.0E10)))))

;; AD-004: no f32 narrowing, the same answer as `float` and `.doubleValue`.
;; clj prints `(.floatValue 0.1)` as 0.1 too; it differs where the f32 does
;; (clj `(.floatValue 16777217)` is 1.6777216E7).
(deftest float-value-is-the-double-as-float-is
  (is (= 0.1 (.floatValue 0.1)))
  (is (= (float 0.1) (.floatValue 0.1)))
  (is (= (float 1/3) (.floatValue 1/3) (.doubleValue 1/3)))
  (is (= 1.6777217E7 (.floatValue 16777217)))
  (is (= 1.0E300 (.floatValue 1.0E300)))
  (is (= (.doubleValue 99999999999999999999N) (.floatValue 99999999999999999999N))))

(deftest bigint-narrowing
  (is (= 5 (.intValue 5N)))
  (is (= 5 (.byteValue 5N)))
  (is (= 4464 (.shortValue 70000N)))
  (is (= 5.0 (.floatValue 5N)))
  (is (= 5.0 (.doubleValue 5N)))
  (is (= 1.0E20 (.doubleValue 99999999999999999999N)))
  (is (= 7766279631452241919 (.longValue 99999999999999999999N)))
  (is (= -7766279631452241919 (.longValue -99999999999999999999N)))
  (is (= 1661992959 (.intValue 99999999999999999999N)))
  (is (= -1661992959 (.intValue -99999999999999999999N))))

(deftest ratio-narrowing
  (is (= 0.5 (.doubleValue 1/2)))
  (is (= -0.6666666666666667 (.doubleValue -2/3)))
  (is (= 3 (.longValue 7/2)))
  (is (= -3 (.intValue -7/2)))
  (is (= 0 (.byteValue 1/2)))
  (is (= -3 (.byteValue -7/2)))
  (is (= -32203 (.shortValue 100000/3)))
  (testing "int goes through the double and saturates; long truncates exactly"
    (is (= 2147483647 (.intValue 10000000000/3)))
    (is (= -1 (.shortValue 10000000000/3)))
    (is (= 66792140173563221 (.longValue (/ 100000000000000000000000N 3))))))

(deftest compare-to
  (is (= -1 (.compareTo 5 6)))
  (is (= 1 (.compareTo 6 5)))
  (is (= 0 (.compareTo 5 5)))
  (is (= -1 (.compareTo 1.5 2.5)))
  (testing "Double.compare total order"
    (is (= 1 (.compareTo 0.0 -0.0)))
    (is (= 1 (.compareTo ##NaN 1.0))))
  (is (= 1 (.compareTo 1/2 1/3)))
  (is (= -1 (.compareTo 1/2 1)))
  (is (= -1 (.compareTo (biginteger 5) (biginteger 6))))
  (is (= 0 (.compareTo 1/2 0.5)))
  (is (= -1 (.compareTo 1/2 5N)))
  (testing "BigInteger.compareTo takes only a BigInteger"
    (is (thrown? Exception (.compareTo (biginteger 5) 6)))
    (is (thrown? Exception (.compareTo 1 5N))))
  (testing "Long and Double compare only against their own class"
    (is (thrown? Exception (.compareTo 1 1.0)))
    (is (thrown? Exception (.compareTo 1.0 1)))))

(deftest equals-is-class-gated
  (is (true? (.equals 5 5)))
  (is (false? (.equals 5 5.0)))
  (is (true? (.equals 1.5 1.5)))
  (is (true? (.equals 5N 5N)))
  (is (true? (.equals 1/2 1/2)))
  (is (false? (.equals 5 5N)))
  (is (false? (.equals 5N 5)))
  (is (false? (.equals 1/2 0.5)))
  (is (true? (.equals 9007199254740993 9007199254740993)))
  (testing "Double.equals compares bits"
    (is (true? (.equals ##NaN ##NaN)))
    (is (false? (.equals 0.0 -0.0)))))

(deftest hash-code-is-the-java-class-hash
  (is (= 5 (.hashCode 5)))
  (is (= 0 (.hashCode -1)))
  (is (= 1 (.hashCode 4294967296)))
  (is (= 2097153 (.hashCode 9007199254740993)))
  (is (= 1073217536 (.hashCode 1.5)))
  (is (= 0 (.hashCode 0.0)))
  (is (= -2147483648 (.hashCode -0.0)))
  (is (= 2146959360 (.hashCode ##NaN)))
  (is (= 5 (.hashCode 5N)))
  (is (= 0 (.hashCode -1N)))
  (is (= 1882487351 (.hashCode 99999999999999999999N)))
  (is (= -1882487351 (.hashCode -99999999999999999999N)))
  (is (= 1915528825 (.hashCode 123456789012345678901234567890N)))
  (is (= 3 (.hashCode 1/2)))
  (is (= -3 (.hashCode -1/2)))
  (is (= 2 (.hashCode 1/3))))

(deftest double-instance-predicates
  (is (true? (.isNaN ##NaN)))
  (is (false? (.isNaN 1.0)))
  (is (true? (.isInfinite ##Inf)))
  (is (true? (.isInfinite ##-Inf)))
  (is (false? (.isInfinite 1.0)))
  (testing "a Long has no Double predicates"
    (is (thrown? Exception (.isNaN 1)))))

(deftest long-value-of-heap-long
  (is (= 9007199254740993 (Long/valueOf 9007199254740993)))
  (is (= 5 (Long/valueOf 5)))
  (testing "a genuine BigInt or a Double matches no Long/valueOf overload"
    (is (thrown? IllegalArgumentException (Long/valueOf 5N)))
    (is (thrown? IllegalArgumentException (Long/valueOf 5.0))))
  (testing "nil takes the String overload and fails to parse"
    (is (thrown? NumberFormatException (Long/valueOf nil)))))
