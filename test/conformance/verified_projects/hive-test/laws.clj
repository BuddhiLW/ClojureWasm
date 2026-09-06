(ns laws
  "Native runtime laws plus hive-test golden and mutation witnesses.
   Run serially: cljw -M:laws. Source mutation campaigns remain separate."
  (:require [clojure.test :as test]
            [clojure.string :as str]
            [clojure.test.check.clojure-test :refer [defspec]]
            [clojure.test.check.generators :as gen]
            [clojure.test.check.properties :as prop]
            [hive-test.trifecta :refer [deftrifecta]]))

(def int-vectors (gen/vector (gen/choose -1000 1000) 0 30))
(def slices
  (gen/bind int-vectors
    (fn [xs]
      (gen/bind (gen/choose 0 (count xs))
        (fn [start]
          (gen/fmap (fn [end] [xs start end])
                    (gen/choose start (count xs))))))))
(def text-input
  (gen/fmap #(apply str %) (gen/vector (gen/elements [\a \b \space \newline \return]) 0 50)))

(deftrifecta subvec-boundaries
  #'clojure.core/subvec
  {:golden-path "subvec.edn"
   :apply? true
   :cases {:empty [[] 0]
           :suffix [[0 1 2 3] 2]
           :middle [[0 1 2 3] 1 3]
           :empty-middle [[0 1 2 3] 2 2]}
   :gen slices
   :pred vector?
   :num-tests {:num-tests 200 :seed 20260906}
   :mutations [["ignore-start" (fn [xs _ & ends] (vec (take (if (seq ends) (first ends) (count xs)) xs)))]
               ["include-end" (fn [xs start & ends] (vec (take (inc (- (if (seq ends) (first ends) (count xs)) start)) (drop start xs))))]]})

(deftrifecta split-lines-boundaries
  #'clojure.string/split-lines
  {:golden-path "split-lines.edn"
   :cases {:empty "" :plain "alpha" :lf "a\nb\n" :crlf "a\r\nb\r\n"
           :empty-line "a\n\nb" :lone-cr "a\rb"}
   :gen text-input
   :pred vector?
   :num-tests {:num-tests 200 :seed 20260907}
   :mutations [["lf-only" (fn [s] (str/split s #"\n"))]
               ["retain-trailing-empty" (fn [s] (str/split s #"\r?\n" -1))]]})

(deftrifecta replace-boundaries
  #'clojure.string/replace
  {:golden-path "replace.edn"
   :apply? true
   :cases {:repeated ["abaaba" "a" "x"]
           :absent ["bbb" "a" "x"]
           :delete ["abaaba" "a" ""]
           :literal-replacement ["a.a" "a" "$1\\x"]}
   :gen (gen/fmap (fn [s] [s "a" "x"]) text-input)
   :pred string?
   :num-tests {:num-tests 200 :seed 20260908}
   :mutations [["first-only" str/replace-first]
               ["ignore-replacement" (fn [s _ _] s)]]})

(defspec apply-preserves-split-arguments
  {:num-tests 300 :seed 20260909}
  (prop/for-all [xs (gen/vector (gen/choose -1000 1000) 2 30)
                split (gen/choose 0 30)]
    (let [n (min split (count xs))
          f (fn ([a b] [a b]) ([a b & more] (into [a b] more)))]
      (= xs (apply apply f (conj (vec (take n xs)) (drop n xs)))))))

(defspec concat-preserves-order
  {:num-tests 300 :seed 20260910}
  (prop/for-all [left int-vectors right int-vectors]
    (= (into left right) (vec (concat left right)))))

(defspec subvec-conserves-partition
  {:num-tests 300 :seed 20260911}
  (prop/for-all [[xs start end] slices]
    (= xs (into (into (subvec xs 0 start) (subvec xs start end))
                (subvec xs end)))))

(defspec repeat-truncates-positive-count
  {:num-tests 300 :seed 20260912}
  (prop/for-all [n (gen/choose 0 30) x (gen/choose -1000 1000)]
    (= (vec (repeat n x)) (vec (repeat (+ n 0.75) x)))))

(defspec replace-preserves-unmatched-characters
  {:num-tests 300 :seed 20260913}
  (prop/for-all [s text-input]
    (let [out (str/replace s "a" "x")]
      (and (= (count s) (count out))
           (= (count (filter #{\a} s)) (count (filter #{\x} out)))
           (= (remove #{\a} s) (remove #{\x} out))))))

(defn -main [& _]
  (let [{:keys [test pass fail error] :as result} (test/run-tests 'laws)]
    (assert (= 14 test) (pr-str result))
    (assert (and (pos? pass) (zero? fail) (zero? error)) (pr-str result))
    (println "OK native runtime laws: 2100 generated cases, six mutation witnesses")))
