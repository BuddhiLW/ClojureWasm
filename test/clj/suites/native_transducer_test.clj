(ns suites.native-transducer-test
  (:require [clojure.test :refer [deftest is testing]]))

;; The same suite runs on cljw and the JVM oracle. Only public core behavior
;; is asserted, so an interpreted fallback cannot hide a semantic difference.
(defn duplicate-input [rf]
  (fn
    ([] (rf))
    ([r] (rf r))
    ([r x] (let [r (rf r x)]
             (if (reduced? r) r (rf r x))))))

(defn append-on-completion [rf]
  (fn
    ([] (rf))
    ([r] (rf (unreduced (rf r :done))))
    ([r x] (rf r x))))

(def ^:dynamic *stage-offset* 0)

(deftest stage-dynamic-binding-at-invocation
  (let [xf (comp (map (fn [x] (+ x *stage-offset*))) (filter even?))]
    (is (= [2] (into [] xf [1 2 3])))
    (is (= [22] (binding [*stage-offset* 20] (into [] xf [1 2 3]))))))

(deftest transducer-values-and-truthiness
  (doseq [coll [nil [] '(0 1 2 3 4 5) [0 1 2 3 4 5] (range 6)]]
    (let [xs (vec coll)]
      (is (= (mapv inc xs) (into [] (map inc) coll)))
      (is (= (vec (filter even? xs)) (into [] (filter even?) coll)))
      (is (= (vec (remove even? xs)) (into [] (remove even?) coll)))
      (is (= (vec (take 3 xs)) (into [] (take 3) coll)))))
  (is (= [0 "" [] :yes] (into [] (filter identity) [nil false 0 "" [] :yes])))
  (is (= [nil false] (into [] (remove identity) [nil false 0 "" [] :yes])))
  (is (= [2 4] (into [] (comp (map inc) (filter even?) (remove #{6}) (take 2)) (range 20))))
  (is (= 20 (transduce (comp (map inc) (filter even?)) + 0 (range 8))))
  (is (= 20 (transduce (comp (map inc) (filter even?)) + (range 8))))
  (is (= {:a 2 :b 3} (into {} (map (fn [[k v]] [k (inc v)])) {:a 1 :b 2})))
  (is (= #{2 3} (into #{} (map inc) [1 1 2])))
  (is (= '(3 2) (into '() (map inc) [1 2]))))

(deftest init-completion-and-reduced
  (let [calls (atom [])
        rf (fn ([] (swap! calls conj :init) [])
               ([r] (swap! calls conj [:complete (reduced? r)]) (conj r :end))
               ([r x] (swap! calls conj [:step x]) (conj r x)))]
    (is (= [2 4 :end] (transduce (comp (map inc) (filter even?) (take 2)) rf (range 10))))
    (is (= [:init [:step 2] [:step 4] [:complete false]] @calls)))
  (doseq [xf [(map inc) (filter even?) (remove odd?) (take 0) (take 3)
              (comp (map inc) (take 0))]]
    (let [calls (atom [])
          rf (fn ([] (swap! calls conj :init) 7)
                 ([r] (swap! calls conj :complete) (inc r))
                 ([r x] (+ r x)))]
      (is (= 8 (transduce xf rf [])))
      (is (= [:init :complete] @calls))))
  (doseq [xf [(map inc) (filter identity) (remove nil?) (take 1) (take 10)
              (comp (map inc) (take 1) (map inc))]]
    (let [calls (atom [])
          rf (xf (fn ([] []) ([r] r) ([r x] (swap! calls conj x) (reduced (conj r x)))))
          r (rf [] 2)]
      (is (reduced? r))
      (is (= 1 (count @calls)))
      (is (= @calls @r))))
  (let [rf ((take 1) (fn ([r] r) ([r x] (reduced (reduced x)))))
        r (rf nil 4)]
    (is (reduced? @r))
    (is (= 4 @@r)))
  (is (= [2 3 :done] (into [] (comp (map inc) append-on-completion) [1 2])))
  (is (= [:done] (into [] (comp (take 0) append-on-completion) [1 2]))))

(deftest take-state-order-and-reuse
  (doseq [[n expected] [[-2 []] [0 []] [1 [0]] [3 [0 1 2]] [10 [0 1 2 3]]
                         [2.5 [0 1 2]] [3/2 [0 1]] [2N [0 1]] [2M [0 1]]]]
    (is (= expected (into [] (take n) (range 4)))))
  (let [xf (take 2)]
    (is (= [1 2] (into [] xf [1 2 3])))
    (is (= [4 5] (into [] xf [4 5 6])))
    (let [rf (xf conj)]
      (is (= [] (rf)))
      (is (= [1] (rf [] 1)))
      (is (= [1] (rf [1])))
      (is (= [1 2] @(rf [1] 2)))
      (is (= [1 2] @(rf [1 2] 3)))))
  (let [seen (atom [])
        xf (comp (map (fn [x] (swap! seen conj x) x)) (take 0))]
    (is (= [] (into [] xf (range 20))))
    (is (= [0] @seen)))
  (let [seen (atom [])]
    (is (= [1 2] (into [] (comp (take 2) (map (fn [x] (swap! seen conj x) x))) (range 1 20))))
    (is (= [1 2] @seen)))
  (let [rf-slot (atom nil)
        calls (atom [])
        rf ((take 2) (fn ([r] r)
                         ([r x] (swap! calls conj x)
                                (when (= x :outer) (@rf-slot r :inner))
                                (conj r x))))]
    (reset! rf-slot rf)
    ;; Outer invocation tests its own decremented count, not the value changed
    ;; by the nested call. Decrement precedes the downstream call.
    (is (= [:outer] (rf [] :outer)))
    (is (= [:outer :inner] @calls))
    (is (reduced? (rf [] :after)))))

(deftest take-generic-counter-and-throw-state
  (doseq [[n expected] [[##NaN []] [##Inf [1 2 3]] [-9223372036854775808N []]]]
    (is (= expected (into [] (take n) [1 2 3]))))
  (let [calls (atom 0)
        rf ((take 2) (fn ([r] r)
                         ([r x] (if (= 1 (swap! calls inc))
                                  (throw (ex-info "first" {}))
                                  (conj r x)))))]
    (is (thrown? clojure.lang.ExceptionInfo (rf [] :first)))
    (is (= [:second] @(rf [] :second)))
    (is (= [] @(rf [] :third)))
    (is (= 2 @calls))))

(deftest mixed-user-transducers-and-comp
  (is (= [2 2 4] (into [] (comp (map inc) duplicate-input (filter even?) (take 3)) (range 10))))
  (is (= [2 2 3 3] (into [] (comp (take 2) duplicate-input (map inc)) (range 1 10))))
  (is (= [2 2 3] (into [] (comp duplicate-input (take 3) (map inc)) [1 2 3])))
  (is (= [1 2] (into [] (comp) [1 2])))
  (let [xf (map inc)] (is (identical? xf (comp xf))))
  (is (= 7 ((comp inc +) 1 2 3)))
  (is (= 8 ((comp inc inc +) 1 2 3)))
  (is (= [true true true true] (mapv fn? [(map inc) ((map inc) +) inc +])))
  (is (ifn? ((take 2) conj))))

(deftest sequence-and-eduction
  (is (= [4 8 12] (vec (sequence (comp (map inc) (filter even?) (map #(* 2 %)) (take 3)) (range 30)))))
  (is (= [11 22] (vec (sequence (map +) [1 2 3] [10 20]))))
  (is (= [111 222] (vec (sequence (comp (map +) (take 2)) [1 2 3] [10 20 30] [100 200 300]))))
  (is (= [2 4 6] (vec (sequence (comp (map inc) (filter even?)) [0 1 2 3 4 5]))))
  (let [ed (eduction (map inc) (filter even?) (take 2) (range 100))]
    (is (= [2 4] (into [] ed)))
    (is (= [2 4] (into [] ed)))
    (is (= 6 (reduce + 0 ed))))
  (is (= [2 2 3] (vec (sequence (comp (map inc) duplicate-input (take 3)) [1 2 3])))))

(deftest callables-dynamic-bindings-and-exceptions
  (is (= [1 2] (into [] (map :x) [{:x 1} {:x 2}])))
  (is (= [1 3] (into [] (filter #{1 3}) (range 5))))
  (let [v (with-local-vars [f inc] (into [] (map f) [1 2]))]
    (is (= [2 3] v)))
  (is (= ["2" "3"] (binding [*print-length* 1] (into [] (map str) [2 3]))))
  (let [xf (map (fn [x] (if (= x 2) (throw (ex-info "mapped" {:x x})) x)))]
    (is (= {:x 2} (try (into [] xf [1 2 3]) nil (catch clojure.lang.ExceptionInfo e (ex-data e))))))
  (doseq [xf [(filter (fn [_] (throw (ex-info "pred" {:pred true}))))
              (remove (fn [_] (throw (ex-info "pred" {:pred true}))))]]
    (is (= {:pred true} (try (into [] xf [1]) nil (catch clojure.lang.ExceptionInfo e (ex-data e))))))
  (is (= :complete (try (transduce (map inc)
                                  (fn ([r] (throw (ex-info "complete" {}))) ([r x] (+ r x))) 0 [1])
                         (catch clojure.lang.ExceptionInfo _ :complete))))
  (doseq [xf [(map nil) (filter nil) (remove nil)]]
    (is (= [] (into [] xf [])))
    (is (thrown? Exception (into [] xf [1]))))
  (let [xf (take :bad)]
    (is (= [] (into [] xf [])))
    (is (thrown? Exception (into [] xf [1]))))
  (doseq [xf [(map inc) (filter even?) (remove odd?) (take 2)]]
    (is (thrown? clojure.lang.ArityException (xf)))
    (is (thrown? clojure.lang.ArityException (xf + +)))
    (is (thrown? clojure.lang.ArityException ((xf +) 1 2 3))))
  (is (thrown? clojure.lang.ArityException (doall (sequence (filter even?) [1] [2])))))

(deftest native-stage-gc-reentry
  (let [xf (comp (map (let [captured {:k 3}] (fn [x] (+ x (:k captured)))))
                 (filter (fn [x] (odd? (transduce (map inc) + 0 [x]))))
                 (take 4))]
    (is (= [4 6 8 10] (into [] xf (range 20)))))
  ;; A mapped Reduced is data, not a signal, until the downstream rf returns it.
  (let [xs (into [] (map reduced) [1 2 3])]
    (is (= [1 2 3] (mapv deref xs)))))

(deftest map-reducing-function-lazy-apply
  (let [seen (atom [])
        rf ((map (fn [& xs] (first xs))) conj)
        tail (map (fn [x] (swap! seen conj x) x) '(20 30 40 50 60 70 80))]
    (is (= [10] (apply rf [] 10 tail)))
    ;; The rf and mapped function inspect their bounded arity prefixes, not
    ;; the unused tail. This count is measured on the live JVM oracle.
    (is (= [20 30] @seen)))
  (is (= [6] (apply ((map +) conj) [] 1 [2 3])))
  (is (= [] (apply ((map inc) conj) [])))
  (is (= [4] (apply ((map inc) conj) [[4]]))))

(deftest map-rf-unused-tail-and-sequence-valued-input
  (let [tail (lazy-seq (cons :a (lazy-seq (cons :b (lazy-seq (throw (ex-info "unused" {})))))))
        rf ((map (fn [x & _] x)) conj)]
    (is (= [:head] (apply rf [] :head tail))))
  (let [rf ((map vector) conj)]
    (is (= [[[1 2]]] (rf [] [1 2])))
    (is (= [[1 2]] (apply rf [] [1 2])))))

(deftest native-stage-forced-gc
  (let [xf (comp (map (let [c {:add 7}] (fn [x] (System/gc) {:v (+ x (:add c))})))
                 (filter (fn [x] (System/gc) (even? (:v x))))
                 (remove (fn [x] (System/gc) (= 10 (:v x))))
                 (take 3))
        rf (fn ([r] (System/gc) (conj r :end))
               ([r x] (System/gc) (conj r (:v x))))]
    (System/gc)
    (is (= [8 12 14 :end] (transduce xf rf [] (range 20)))))
  (let [rf ((map (fn [x & xs] (System/gc) [x (first xs)])) conj)]
    (is (= [[:head "tail-0"]]
           (apply rf [] :head (map (fn [x] (System/gc) (str "tail-" x)) (range 10)))))))

(deftest take-ratio-counter-survives-nested-gc
  (let [slot (atom nil)
        rf ((take 5/2) (fn ([r] r)
                           ([r x] (System/gc)
                                  (when (= x :outer) (@slot r :inner))
                                  (System/gc)
                                  (conj r x))))]
    (reset! slot rf)
    (is (= [:outer] (rf [] :outer)))
    (is (= [:last] @(rf [] :last)))
    (is (= [] @(rf [] :after)))))

(deftest deep-native-stages-have-a-controlled-stack-limit
  (let [xf (filter :keep)
        rf (reduce (fn [rf _] (xf rf)) (fn [r _] r) (range 30000))]
    ;; Keyword predicates do not enter an evaluator or allocate, so only the
    ;; native stage checkpoint can make this depth a controlled exception.
    (is (= :caught (try (rf [] {:keep true}) (catch StackOverflowError _ :caught))))))
