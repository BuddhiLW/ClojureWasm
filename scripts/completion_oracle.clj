#!/usr/bin/env bb
(ns completion-oracle
  "Capture and compare CIDER completion responses with shared Clojure nREPL IO."
  (:require [babashka.fs :as fs]
            [cheshire.core :as json]
            [clojure.set :as set]
            [dev.nrepl :as nrepl]
            [harness.process :as process]))

(def fixture-dir "test/e2e/fixtures/completion")
(def requests-path (str fixture-dir "/requests.json"))
(def expected-path (str fixture-dir "/expected.json"))

(defn usage! []
  (binding [*out* *err*]
    (println "usage: bb scripts/completion_oracle.clj --capture|--diff|--cljw"))
  (System/exit 2))

(defn mode [args]
  (let [modes (filter #{"--capture" "--diff" "--cljw"} args)]
    (if (= 1 (count modes)) (first modes) (usage!))))

(defn normalize [candidates]
  (->> (or candidates [])
       (map (fn [candidate]
              (cond-> {"candidate" (get candidate "candidate")
                       "type" (get candidate "type")}
                (contains? candidate "ns")
                (assoc "ns" (get candidate "ns")))))
       (sort-by #(or (get % "candidate") ""))
       vec))

(defn run-probes [port groups]
  (reduce
   (fn [result group]
     (let [conn (nrepl/connect "127.0.0.1" port)]
       (try
         (nrepl/clone-session! conn)
         (doseq [code (get group "setup" [])]
           (nrepl/eval-code conn code))
         (reduce
          (fn [result probe]
            (let [key (str (get group "group") "|" (get probe "prefix"))
                  responses
                  (try
                    (nrepl/request
                     conn
                     {"op" "completions"
                      "prefix" (get probe "prefix")
                      "ns" (get probe "ns" "user")})
                    (catch Exception e
                      (throw (ex-info "completion request failed"
                                      {:probe key :port port}
                                      e))))
                  candidates (some #(get % "completions") responses)]
              (assoc result key (normalize candidates))))
          result
          (get group "probes"))
         (finally
           (nrepl/close conn)))))
   (sorted-map)
   groups))

(defn print-json [value]
  (println (json/generate-string value {:pretty true})))

(defn diff-results [mainline cljw]
  (let [diffs
        (reduce
         (fn [diffs key]
           (let [main (get mainline key)
                 actual (get cljw key)]
             (if (= main actual)
               (do
                 (println (str "OK   " key " (" (count main) ")"))
                 diffs)
               (let [main-set (set main)
                     actual-set (set (or actual []))]
                 (println (str "DIFF " key ": mainline " (count main)
                               " vs cljw " (count (or actual []))))
                 (doseq [candidate (take 15 (sort-by pr-str (set/difference main-set actual-set)))]
                   (println (str "  -mainline-only " (json/generate-string candidate))))
                 (doseq [candidate (take 15 (sort-by pr-str (set/difference actual-set main-set)))]
                   (println (str "  +cljw-only     " (json/generate-string candidate))))
                 (inc diffs)))))
         0
         (sort (keys mainline)))]
    (println "---")
    (println (str (- (count mainline) diffs) "/" (count mainline)
                  " probes match"))
    (if (zero? diffs) 0 1)))

(defn capture! [groups]
  (process/with-server
   (process/start-mainline! true)
   (fn [server]
     (let [responses (run-probes (:port server) groups)]
       (fs/create-dirs fixture-dir)
       (spit expected-path
             (str (json/generate-string responses {:pretty true}) "\n"))
       (println (str "captured " (count responses)
                     " probe responses -> " expected-path))
       0))))

(defn cljw! [groups]
  (process/ensure-cljw-built!)
  (process/with-server
   (process/start-cljw!)
   (fn [server]
     (print-json (run-probes (:port server) groups))
     0)))

(defn compare! [groups]
  (process/ensure-cljw-built!)
  (process/with-server
   (process/start-mainline! true)
   (fn [mainline-server]
     (let [mainline (run-probes (:port mainline-server) groups)]
       (process/with-server
        (process/start-cljw!)
        (fn [cljw-server]
          (diff-results mainline
                        (run-probes (:port cljw-server) groups))))))))

(defn -main [& args]
  (let [groups (json/parse-string (slurp requests-path))
        status (case (mode args)
                 "--capture" (capture! groups)
                 "--cljw" (cljw! groups)
                 "--diff" (compare! groups))]
    (System/exit status)))

(apply -main *command-line-args*)
