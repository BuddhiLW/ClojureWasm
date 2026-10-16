;; D-587: redefining a deftype/defrecord name must not invalidate instances
;; that were constructed against the previous definition.
;;
;; clj's semantics: re-evaluating `defrecord` creates a NEW class. Instances
;; made earlier keep the OLD class and keep printing, reading and comparing
;; correctly; the old class becomes garbage only when nothing references it.
;; cljw used to FREE the old TypeDescriptor on re-registration while live
;; instances still held a raw pointer to it, so touching an older instance
;; read freed memory. The symptom varied with whatever the freed memory
;; happened to contain: `thread panic: integer overflow` on some shapes,
;; `WriteFailed` on others, which is itself the signature of a
;; use-after-free rather than a logic error.
;;
;; This is a native suite rather than a shell e2e even though the OLD symptom
;; was a process abort: a crash cannot be caught in-process, but the FIXED
;; behaviour is an ordinary value assertion, which is where it belongs. The
;; consequence is that this file and the fix must land together, since the
;; suite runner shares one image and a crash here takes every suite with it.
(ns suites.type-redefine-test
  (:require [clojure.test :refer [deftest is]]))

;; --- same name, same shape, redefined in one namespace (the REPL re-eval
;; and `require :reload` path) ---

(defrecord RedefSameShape [x y])

(def ^:private same-shape-before (->RedefSameShape 1 2))
(def ^:private same-shape-repr-at-construction (pr-str same-shape-before))

(defrecord RedefSameShape [x y])

(def ^:private same-shape-after (->RedefSameShape 1 2))

(deftest older-instance-survives-a-same-shape-redefine
  (is (= same-shape-repr-at-construction (pr-str same-shape-before))))

(deftest older-instance-keeps-its-fields-after-redefine
  (is (= [1 2] [(:x same-shape-before) (:y same-shape-before)])))

(deftest newer-instance-works-after-redefine
  (is (= [1 2] [(:x same-shape-after) (:y same-shape-after)])))

;; --- same name, DIFFERENT field count: the retired layout must not be
;; consulted for the new type, nor the new layout for the old instance ---

(defrecord RedefDifferentShape [a b])

(def ^:private two-field (->RedefDifferentShape 7 8))
(def ^:private two-field-repr-at-construction (pr-str two-field))

(defrecord RedefDifferentShape [a])

(def ^:private one-field (->RedefDifferentShape 9))

(deftest older-instance-survives-a-narrowing-redefine
  (is (= two-field-repr-at-construction (pr-str two-field))))

(deftest older-instance-keeps-both-fields-after-narrowing
  (is (= [7 8] [(:a two-field) (:b two-field)])))

(deftest newer-narrower-instance-is-correct
  (is (= 9 (:a one-field)))
  (is (nil? (:b one-field))))

;; --- a deftype redefine, which failed with a different symptom (WriteFailed)
;; but the same root cause ---

(deftype RedefType [p q])

(def ^:private typed-before (RedefType. 3 4))

(deftype RedefType [p q])

(deftest older-deftype-instance-survives-redefine
  (is (= [3 4] [(.-p typed-before) (.-q typed-before)])))

;; --- equality and hashing must not read the retired layout either ---

(defrecord RedefEquality [v])

(def ^:private eq-before (->RedefEquality 5))

(defrecord RedefEquality [v])

(def ^:private eq-after (->RedefEquality 5))

;; What this row guarantees is that asking the question does not crash and
;; that each instance still equals one of its own vintage. Whether an old and
;; a new instance compare equal is a separate question (clj says no, they are
;; different classes); it is pinned loosely here on purpose so this test
;; fails for a use-after-free and not for a defensible answer either way.
(deftest redefined-type-equality-is-well-defined
  (is (= eq-before eq-before))
  (is (= eq-after eq-after))
  (is (boolean? (= eq-before eq-after))))

(deftest redefined-type-hash-is-well-defined
  (is (integer? (hash eq-before)))
  (is (integer? (hash eq-after))))

;; --- a class VALUE captured before the redefine stays traceable ---
;; `makeTypeDescriptorRef` hands out a process-lifetime boxed ref that the GC
;; traces as a persistent mark waypoint via `markDescriptorValues`. Freeing
;; the descriptor left that waypoint pointing at freed memory, so the
;; use-after-free could also fire inside the MARK phase rather than at print
;; time. Holding the ref across a redefine and then forcing a collect is the
;; assertion for that path.
(defrecord RedefClassRef [n])

(def ^:private captured-class (class (->RedefClassRef 1)))

(defrecord RedefClassRef [n])

(deftest captured-class-value-survives-redefine-and-collect
  (dotimes [_ 200] (vec (range 64)))
  (is (some? captured-class))
  (is (string? (pr-str captured-class))))
