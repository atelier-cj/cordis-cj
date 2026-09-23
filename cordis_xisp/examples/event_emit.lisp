;; 示例 xisp 插件：事件发布者
;;
;; 启动后 emit hello 事件（宿主扇出给订阅者），并订阅 world 事件回显。
;;
;; 用法（cordis.toml）：
;;   [[plugins]]
;;   id = "lisp-emit"
;;   source = "./target/release/bin/ystyle::cordis_xisp.cli"
;;   args = ["--script", "./cordis_xisp/examples/event_emit.lisp",
;;           "--plugin-id", "lisp-emit"]
;;   enabled = true

(cordis::log "info" "lisp-emit ready")

;; 启动时发布 hello 事件（emit 模式：通知宿主扇出，不等待订阅者）
(cordis::emit "hello" '("world"))

;; 订阅 world 事件并回显
(cordis::on "world" (lambda (args)
  (cordis::log "info" (string-append "world event: " (car args)))))
