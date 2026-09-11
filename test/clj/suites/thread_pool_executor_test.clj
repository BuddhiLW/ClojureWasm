;; Executor semantics run inside cljw itself.  Discovery is automatic through
;; harness.suites; no Bash wrapper or test/run_all registration belongs here.
(ns suites.thread-pool-executor-test
  (:require [clojure.test :refer [deftest is testing]])
  (:import [java.util.concurrent Executors
                                 Callable
                                 LinkedBlockingQueue
                                 Semaphore
                                 ThreadFactory
                                 ThreadPoolExecutor
                                 ThreadPoolExecutor$CallerRunsPolicy
                                 TimeUnit]
           [java.util.concurrent.atomic AtomicBoolean AtomicLong]))

;; Wait for a worker to signal that it is running, bounded so a genuinely
;; stuck pool fails the assertion instead of hanging the suite. This is the
;; safe half of a wall-clock assertion per `.claude/rules/test_taxonomy.md`:
;; a deadline that separates a hang from a busy machine, never a ratio.
(defn- await-flag [^AtomicBoolean flag]
  (loop [waited 0]
    (cond
      (.get flag) true
      (>= waited 5000) false
      :else (do (Thread/sleep 1) (recur (inc waited))))))

(deftest fixed-pool-submit-get-and-shutdown
  (let [pool (Executors/newFixedThreadPool 2)]
    (try
      (let [a (.submit pool (reify Callable (call [_] 40)))
            b (.submit pool (reify Callable (call [_] 2)))]
        (is (= 42 (+ (.get a) (.get b))))
        (is (false? (.isShutdown pool))))
      (finally (.shutdown pool)))
    (is (true? (.isShutdown pool)))
    (is (true? (.awaitTermination pool 1000 TimeUnit/MILLISECONDS)))
    (is (true? (.isTerminated pool)))))

(deftest supplied-thread-factory-creates-the-real-workers
  (let [created (AtomicLong. 0)
        factory (reify ThreadFactory
                  (newThread [_ runnable]
                    (.incrementAndGet created)
                    (doto (Thread. runnable)
                      (.setName (str "pool-worker-" (.get created)))
                      (.setDaemon true))))
        queue (LinkedBlockingQueue. 4)
        pool (ThreadPoolExecutor. 2 2 0 TimeUnit/MILLISECONDS queue factory
                                  (ThreadPoolExecutor$CallerRunsPolicy.))]
    (try
      (testing "construction asks the supplied factory for each fixed worker"
        (is (= 2 (.get created))))
      (is (= :ok (.get (.submit pool (reify Callable (call [_] :ok))))))
      (finally (.shutdown pool)))
    (is (true? (.awaitTermination pool 1000 TimeUnit/MILLISECONDS)))))

;; The sole worker is pinned on a semaphore, never on a sleep. Holding
;; saturation for a fixed 120 ms is a race window, not a synchronisation
;; point: on a loaded CI runner the worker finished first-job and drained the
;; queue before the third submit arrived, so the third job ran on the worker
;; ("Thread-4") instead of on the caller, and the assertion failed for a
;; reason it was not written to detect (2026-09-10, macOS gate). A gate the
;; test itself opens is load-independent.
(deftest bounded-pool-runs-saturated-work-on-caller
  (let [queue (LinkedBlockingQueue. 1)
        pool (ThreadPoolExecutor. 1 1 0 TimeUnit/MILLISECONDS queue nil
                                  (ThreadPoolExecutor$CallerRunsPolicy.))
        gate (Semaphore. 0)
        running (AtomicBoolean. false)]
    (try
      (let [first-job (.submit pool
                               (reify Callable
                                 (call [_]
                                   (.set running true)
                                   (.acquire gate)
                                   :first)))]
        ;; The sole worker owns first-job once it has signalled, and keeps
        ;; owning it until this test releases the gate below.
        (is (true? (await-flag running)))
        (let [queued-job (.submit pool (reify Callable (call [_] :queued)))
              queued-count (.size (.getQueue pool))
              caller-job (.submit pool
                                  (reify Callable
                                    (call [_]
                                      [(.getName (Thread/currentThread)) :caller])))]
          (testing "the third job completes before submit returns, on main"
            (is (= 1 queued-count))
            (is (true? (.isDone caller-job)))
            (is (= ["main" :caller] (.get caller-job))))
          (.release gate)
          (is (= :first (.get first-job)))
          (is (= :queued (.get queued-job)))))
      (finally (.shutdown pool)))
    (is (true? (.awaitTermination pool 1000 TimeUnit/MILLISECONDS)))))

;; Same discipline as above: the worker is held on a gate, so the job under
;; test is still QUEUED when it is cancelled regardless of runner load.
(deftest cancelling-a-queued-future-prevents-invocation
  (let [pool (Executors/newSingleThreadExecutor)
        ran (AtomicBoolean. false)
        gate (Semaphore. 0)
        running (AtomicBoolean. false)]
    (try
      (let [first-job (.submit pool
                               (reify Callable
                                 (call [_]
                                   (.set running true)
                                   (.acquire gate)
                                   :first)))]
        (is (true? (await-flag running)))
        (let [cancelled-job (.submit pool
                                     (reify Callable
                                       (call [_] (.set ran true) :cancelled)))]
          (is (true? (.cancel cancelled-job true)))
          (is (true? (.isCancelled cancelled-job)))
          (is (true? (.isDone cancelled-job)))
          (.release gate)
          (is (= :first (.get first-job)))
          (is (false? (.get ran)))))
      (finally (.shutdown pool)))
    (is (true? (.awaitTermination pool 1000 TimeUnit/MILLISECONDS)))))

(deftest shutdown-rejects-with-the-java-exception-class
  (let [pool (Executors/newSingleThreadExecutor)]
    (.shutdown pool)
    (is (= :rejected
           (try
             (.submit pool (reify Callable (call [_] :too-late)))
             (catch java.util.concurrent.RejectedExecutionException _
               :rejected))))
    (is (true? (.awaitTermination pool 1000 TimeUnit/MILLISECONDS)))))
