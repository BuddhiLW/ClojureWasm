;; Precision-bounded arithmetic must not materialize every digit between two
;; operands' decimal points. Expected strings are JVM BigDecimal results with
;; MathContext(40, HALF_UP), unless the test names a different rounding mode.
(ns suites.bigdecimal-precision-alignment-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.java.shell :refer [sh]]))

(defn- bounded-eval [form]
  ;; A native arithmetic loop cannot observe an eval deadline. Bound a child
  ;; process so a regression fails this suite instead of stalling the gate.
  (sh "perl" "-e" "alarm shift; exec @ARGV" "5"
      "zig-out/bin/cljw" "-e" (pr-str form)))

(deftest distant-scale-addition-rounds-without-expanding-the-gap
  ;; The discarded -0.74 is smaller than half of the last retained decimal
  ;; place (10^155206), so HALF_UP leaves all forty significant digits intact.
  (let [r (bounded-eval
            '(with-precision 40
               (let [x 1.613588325170455724932267351034637780127E+155245M]
                 (mapv str [(+ x -0.74M) (+ 0.13M x)
                            (- x 0.74M) (- 0.13M x)]))))]
    (is (zero? (:exit r)) (str "addition exceeded 5 seconds: " (:err r)))
    (when (zero? (:exit r))
      (is (= ["1.613588325170455724932267351034637780127E+155245"
              "1.613588325170455724932267351034637780127E+155245"
              "1.613588325170455724932267351034637780127E+155245"
              "-1.613588325170455724932267351034637780127E+155245"]
             (read-string (:out r)))))))

(deftest a-bounded-complex-orbit-completes-two-thousand-steps
  ;; The reported -0.74 + 0.13i orbit escapes after step 720 and ultimately
  ;; overflows even on the JVM. -0.74 + 0.10i stays bounded for this run.
  (let [r (bounded-eval
            '(with-precision 40
               (loop [zr 0M zi 0M i 0]
                 (if (= i 2000)
                   [(str zr) (str zi) (.scale zr) (.scale zi)]
                   (recur (+ (- (* zr zr) (* zi zi)) -0.74M)
                          (+ (* 2M zr zi) 0.1M)
                          (inc i))))))]
    (is (zero? (:exit r)) (str "orbit exceeded 5 seconds: " (:err r)))
    (when (zero? (:exit r))
      (is (= ["-0.4943688133562337039706890695287953684420"
              "0.04974702621546482206699951899575010724693" 40 41]
             (read-string (:out r)))))))

(deftest guard-digits-preserve-directed-rounding-and-half-ties
  (testing "a tiny tail below the guard digits remains visible to every mode"
    (let [x 1.2345E+100M y 0.00001M
          sums (fn [mode]
                 (binding [*math-context* (java.math.MathContext. 5 mode)]
                   (mapv str [(+ x y) (- x y) (+ (- x) y) (- (- x) y)])))]
      (is (= ["1.2346E+100" "1.2345E+100" "-1.2345E+100" "-1.2346E+100"]
             (sums java.math.RoundingMode/UP)))
      (is (= ["1.2345E+100" "1.2344E+100" "-1.2344E+100" "-1.2345E+100"]
             (sums java.math.RoundingMode/DOWN)))
      (is (= ["1.2346E+100" "1.2345E+100" "-1.2344E+100" "-1.2345E+100"]
             (sums java.math.RoundingMode/CEILING)))
      (is (= ["1.2345E+100" "1.2344E+100" "-1.2345E+100" "-1.2346E+100"]
             (sums java.math.RoundingMode/FLOOR)))
      (doseq [mode [java.math.RoundingMode/HALF_UP java.math.RoundingMode/HALF_DOWN
                    java.math.RoundingMode/HALF_EVEN]]
        (is (= ["1.2345E+100" "1.2345E+100" "-1.2345E+100" "-1.2345E+100"]
               (sums mode))))
      (is (thrown? ArithmeticException (sums java.math.RoundingMode/UNNECESSARY)))))
  (testing "a distant tail changes which side of an existing tie the sum lies on"
    (doseq [mode [java.math.RoundingMode/HALF_UP java.math.RoundingMode/HALF_DOWN
                  java.math.RoundingMode/HALF_EVEN]]
      (binding [*math-context* (java.math.MathContext. 3 mode)]
        (is (= ["1.25E+100" "1.24E+100" "-1.24E+100" "-1.25E+100"]
               (mapv str [(+ 1.245E+100M 1M) (- 1.245E+100M 1M)
                          (+ -1.245E+100M 1M) (- -1.245E+100M 1M)])))))))

(deftest precision-alignment-preserves-zero-cancellation-and-preferred-scale
  (with-precision 5
    (is (= "1.2000E+100" (str (+ 1.2E+100M 0M))))
    (is (= "1.2000E+100" (str (+ 0M 1.2E+100M))))
    (is (= "1E-100" (str (+ 0E+100M 1E-100M))))
    (is (= "0E+99" (str (- 1.2E+100M 1.2E+100M))))
    (is (= "1.0000E+100" (str (+ 9.99999E+99M 1M))))
    (is (= "9.9999E+99"
           (str (with-precision 5 :rounding DOWN (- 1E+100M 1M))))))
  (testing "unlimited arithmetic keeps every digit and its preferred scale"
    (let [x (with-precision 0 (+ 1E+100M 1M))]
      (is (= 101 (.precision x)))
      (is (= 0 (.scale x)))
      (is (= 1M (- x 1E+100M))))))

(deftest precision-alignment-agrees-with-exact-then-round
  ;; Moderate gaps keep the independent exact path cheap. Cross the sticky
  ;; cutoff, including overlap/cancellation, zero, and every rounding mode.
  (let [outcome (fn [f]
                  (try (str (f))
                       (catch ArithmeticException _ :rounding-required)))]
    (doseq [precision [1 3 5]
            mode [java.math.RoundingMode/UP java.math.RoundingMode/DOWN
                  java.math.RoundingMode/CEILING java.math.RoundingMode/FLOOR
                  java.math.RoundingMode/HALF_UP java.math.RoundingMode/HALF_DOWN
                  java.math.RoundingMode/HALF_EVEN java.math.RoundingMode/UNNECESSARY]
            [x y] [[1E+100M 0.13M] [-1.245E+100M -1M] [9.99999E+100M 0M]
                   [0E+100M 1E-100M] [1.245M 0.00001M] [1.245M -0.00001M]
                   [1.245M 0.0001M] [1.245M -0.0001M] [1.245M -1.24499M]
                   [123456789.999M -123456789.998M]]
            [a b] [[x y] [y x]]
            [op exact] [[+ #(.add a b)] [- #(.subtract a b)]]
            ;; JVM Clojure negates b in the active context before subtracting.
            ;; Exact-then-round is its oracle only when that negate is exact.
            :when (or (= op +) (<= (.precision b) precision))]
      (let [mc (java.math.MathContext. precision mode)]
        (is (= (outcome #(.round (exact) mc))
               (outcome #(binding [*math-context* mc] (op a b))))
            (str "precision=" precision " mode=" mode " a=" a " b=" b))))))
