;; 示例 xisp 插件：嵌套服务调用（脚本锁释放窗口验证）
;;
;; outer handler 内部经宿主转发调用本插件自己的 inner 服务。
;; 验证「脚本回调内嵌套 invoke 自己插件」不死锁：
;; 宿主把调用链派发回本插件时，等待响应前已释放脚本锁。
;;
;; 用法（cordis.toml）：
;;   [[plugins]]
;;   id = "lisp-nested"
;;   source = "./target/release/bin/ystyle::cordis_xisp.cli"
;;   args = ["--script", "./cordis_xisp/examples/nested_invoke.lisp",
;;           "--plugin-id", "lisp-nested"]
;;   provide = ["inner", "outer"]
;;   enabled = true

(cordis::log "info" "lisp-nested ready")

;; inner：参数 × 2
(cordis::register-handler "inner" (lambda (method args)
  (* 2 (car args))))

;; outer：内部调用 inner（宿主转发回本插件）
(cordis::register-handler "outer" (lambda (method args)
  (cordis::invoke "inner" "inner" (list (car args)))))
