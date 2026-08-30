;; scripts/dev/nrepl.cljc — a minimal nREPL client that runs on BOTH cljw and
;; babashka, sharing one implementation.
;;
;; The ONLY runtime difference is how a TCP socket is opened and read/written:
;; cljw exposes `cljw.net/connect` with `.read`/`.write` directly on the socket,
;; while the JVM/babashka side goes through get{Input,Output}Stream. Those three
;; functions are the entire reader-conditional surface; everything above them —
;; the request encoding, the incremental decode, the response loop — is shared.
(ns dev.nrepl
  (:require [dev.bencode :as b]))

;; --- the runtime seam -----------------------------------------------------
(defn connect [host port]
  #?(:cljw {:sock (cljw.net/connect host port)}
     :default (let [s (java.net.Socket. ^String host ^long port)]
                {:sock s :in (.getInputStream s) :out (.getOutputStream s)})))

(defn- write-bytes [conn ba]
  #?(:cljw (.write (:sock conn) ba (alength ba))
     :default (doto (:out conn) (.write ba) (.flush))))

(defn- read-bytes
  "Fill `buf`; => number of bytes read, or -1/nil at EOF."
  [conn buf]
  #?(:cljw (.read (:sock conn) buf)
     :default (.read (:in conn) buf)))

(defn close [conn] (.close (:sock conn)))

;; --- the shared protocol loop ---------------------------------------------
(defn- unsigned [x] (bit-and x 255))

(defn eval-code
  "Send `code` to the connected nREPL and collect its responses.
   => vector of response maps (string keys, as they arrive on the wire).
   Reads until the server sends a \"done\" status, so a multi-form input that
   produces several values is fully drained."
  [conn code]
  (let [req (.getBytes (b/encode-dict {"op" "eval" "code" code "id" "1"}) "UTF-8")]
    (write-bytes conn req)
    (loop [buf [] consumed 0 acc []]
      (let [chunk (byte-array 8192)
            n (read-bytes conn chunk)]
        (if (or (nil? n) (<= n 0))
          acc
          (let [buf' (into buf (map unsigned (take n (seq chunk))))
                r (b/decode-all buf' consumed)
                msgs (first r)
                acc' (into acc msgs)
                done? (some (fn [m]
                              (let [st (get m "status")]
                                (and (coll? st) (some (fn [s] (= s "done")) st))))
                            msgs)]
            (if done?
              acc'
              (recur buf' (second r) acc'))))))))

(defn print-responses
  "Render responses the way a REPL client should. => true if the server
   reported an evaluation error (so a caller can set its exit code)."
  [msgs]
  (reduce (fn [failed m]
            (when-let [o (get m "out")] (print o) (flush))
            (when-let [e (get m "err")] (print e) (flush))
            (when-let [v (get m "value")] (println "value" v))
            (when-let [x (get m "ex")] (println "ex" x))
            (or failed (some? (get m "ex"))))
          false
          msgs))
