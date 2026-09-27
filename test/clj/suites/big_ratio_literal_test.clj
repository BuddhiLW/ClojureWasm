;; Ratio literals wider than i64 (CLJW-BIG-RATIO-LITERAL).
;;
;; The reader used to parse each side of `n/d` as an i64, so a numerator or
;; denominator past Long raised "Invalid float literal", and the integer
;; collapse went through the i48 immediate, so `36028797018963968/2` came back
;; a lossy Double. Expected values are the clj oracle (clojure -M).
(ns suites.big-ratio-literal-test
  (:require [clojure.edn :as edn]
            [clojure.test :refer [deftest is testing]]))

(deftest collapse-divides
  (testing "den divides num: the value is the quotient, not the numerator"
    (is (= 3 6/2))
    (is (= -3 -6/2))
    (is (= 0 0/5))
    (is (= 3 (read-string "+6/2")))
    (is (= "java.lang.Long" (str (class 6/2))))))

(deftest collapse-past-i48-stays-long
  (is (= "[18014398509481984 java.lang.Long]"
         (pr-str [36028797018963968/2 (class 36028797018963968/2)])))
  (is (= "[-18014398509481984 java.lang.Long]"
         (pr-str [-36028797018963968/2 (class -36028797018963968/2)])))
  (is (= "9223372036854775807" (pr-str (read-string "9223372036854775807/1")))))

(deftest collapse-past-i64-is-bigint
  (is (= "17636684144620811271604938270N"
         (pr-str (read-string "123456789012345678901234567890/7"))))
  (is (= "4611686018427387904N" (pr-str (read-string "36893488147419103232/8"))))
  (is (= "1N" (pr-str (read-string "36893488147419103232/36893488147419103232"))))
  (is (= "-9223372036854775808N" (pr-str (read-string "-9223372036854775808/1")))))

(deftest wide-ratio-reads
  (is (ratio? 24691357802469135781/2))
  (is (= "24691357802469135781/2" (pr-str 24691357802469135781/2)))
  (is (= "-24691357802469135781/2" (pr-str (read-string "-24691357802469135781/2"))))
  (is (= "1/24691357802469135781" (pr-str (read-string "1/24691357802469135781"))))
  (is (= "1/2" (pr-str (read-string "18446744073709551616/36893488147419103232"))))
  (is (= 24691357802469135781N (numerator 24691357802469135781/2)))
  (is (= 24691357802469135781N (denominator 1/24691357802469135781)))
  (is (= 24691357802469135781N (* 2 24691357802469135781/2))))

(deftest round-trip
  (doseq [s ["24691357802469135781/2" "-24691357802469135781/2"
             "1/24691357802469135781" "3/4"]]
    (let [v (read-string s)]
      (is (= v (read-string (pr-str v))))
      (is (= s (pr-str v))))))

(deftest data-and-edn-paths
  (is (= "24691357802469135781/2" (pr-str '24691357802469135781/2)))
  (is (= "[18014398509481984 3]" (pr-str '[36028797018963968/2 6/2])))
  (is (= "24691357802469135781/2" (pr-str (edn/read-string "24691357802469135781/2"))))
  (is (= "[18014398509481984 java.lang.Long]"
         (let [v (edn/read-string "36028797018963968/2")] (pr-str [v (class v)])))))

(deftest bad-ratio-still-throws
  (is (thrown? Throwable (read-string "1/0"))))
