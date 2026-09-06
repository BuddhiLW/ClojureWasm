;; Executor semantics run inside cljw itself.  Discovery is automatic through
;; harness.suites; no Bash wrapper or test/run_all registration belongs here.
(ns suites.thread-pool-executor-test
  (:require [clojure.test :refer [deftest is testing]])
  (:import [java.util.concurrent Executors
                                 Callable
                                 LinkedBlockingQueue
                                 ThreadFactory
                                 ThreadPoolExecutor
                                 ThreadPoolExecutor$CallerRunsPolicy
                                 TimeUnit]
           [java.util.concurrent.atomic AtomicBoolean AtomicLong]))

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

(deftest bounded-pool-runs-saturated-work-on-caller
  (let [queue (LinkedBlockingQueue. 1)
        pool (ThreadPoolExecutor. 1 1 0 TimeUnit/MILLISECONDS queue nil
                                  (ThreadPoolExecutor$CallerRunsPolicy.))]
    (try
      (let [first-job (.submit pool
                               (reify Callable
                                 (call [_] (Thread/sleep 120) :first)))]
        ;; Ensure the sole worker owns first-job before filling the one-slot queue.
        (Thread/sleep 20)
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
          (is (= :first (.get first-job)))
          (is (= :queued (.get queued-job)))))
      (finally (.shutdown pool)))
    (is (true? (.awaitTermination pool 1000 TimeUnit/MILLISECONDS)))))

(deftest cancelling-a-queued-future-prevents-invocation
  (let [pool (Executors/newSingleThreadExecutor)
        ran (AtomicBoolean. false)]
    (try
      (let [first-job (.submit pool
                               (reify Callable
                                 (call [_] (Thread/sleep 100) :first)))]
        (Thread/sleep 20)
        (let [cancelled-job (.submit pool
                                     (reify Callable
                                       (call [_] (.set ran true) :cancelled)))]
          (is (true? (.cancel cancelled-job true)))
          (is (true? (.isCancelled cancelled-job)))
          (is (true? (.isDone cancelled-job)))
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
