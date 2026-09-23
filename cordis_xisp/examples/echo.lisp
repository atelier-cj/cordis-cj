;; 示例 xisp 插件：echo / add / whoami 服务 + 事件订阅
;;
;; 用法（cordis.toml）：
;;   [[plugins]]
;;   id = "lisp-echo"
;;   source = "./target/release/bin/ystyle::cordis_xisp.cli"
;;   args = ["--script", "./cordis_xisp/examples/echo.lisp"]
;;   provide = ["echo", "add", "whoami"]
;;   enabled = true
;;
;; 脚本顶层求值即插件初始化：注册服务 handler 与事件监听器。
;; id / provide / inject 由宿主按 entry 经环境变量下发（cordis.toml 是唯一来源），
;; 脚本只负责注册实现。

(cordis::log "info" "lisp-echo ready")

;; echo：原样返回第一个参数（无参数返回 nil）
(cordis::register-handler "echo" (lambda (method args)
  (if (> (length args) 0) (car args) nil)))

;; add：两个数字相加
(cordis::register-handler "add" (lambda (method args)
  (+ (car args) (car (cdr args)))))

;; whoami：返回插件 ID（宿主按 cordis.toml entry.id 经环境变量下发）
(cordis::register-handler "whoami" (lambda (method args)
  (cordis::plugin-id)))

;; 订阅 hello 事件（emit 模式，返回值被忽略）
(cordis::on "hello" (lambda (args)
  (cordis::log "info" (string-append "hello event: " (car args)))))
