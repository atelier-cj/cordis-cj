package ystyle::cordis_host

import ystyle::cordis_core.{PluginEntry, InstanceStatus}
import ystyle::jsonrpc.{JsonRpcClient, NewlineFraming, ContentLengthFraming}
import ystyle::jsonrpc_unix.UnixServerTransport
import std.process.{launch, SubProcess, ProcessRedirect}
import std.io.StringReader
import std.sync.Mutex
import std.fs.{removeIfExists, Path}
import std.collection.ArrayList

/**
 * 插件进程管理器（docs/design-impl.md §3.3、§3.4）
 *
 * 职责：
 * - launch：拉起插件子进程并建立 JSON-RPC 连接
 *   · stdio 模式（默认）：三流 Pipe，PipeTransport + NewlineFraming
 *   · uds 模式：宿主 bind UnixServerSocket，插件经 --uds <path> 参数
 *     连接上来（UnixServerTransport + ContentLengthFraming）
 * - terminate：热卸载（关闭连接 + 强杀 + wait 回收退出码，避免僵尸进程）
 * - forwardStderr：独立线程转发插件 stderr 到宿主日志
 * - isExited：探测插件连接是否已关闭（stdout EOF / socket EOF 判定崩溃）
 *
 * UDS 模式说明（docs/design-impl.md §3.4）：
 * - 宿主是服务端：bind 一次 uds_path，多个插件可依次连接（accept 顺序
 *   与 launch 顺序一致，因为 launch 同步 accept 后才返回）
 * - bind 前清理残留 socket 文件（文件已存在则 bind 失败）
 * - UDS 的 read 是标准流式读（无管道 ConsoleReader 阻塞坑），因此使用
 *   jsonrpc 默认的 ContentLengthFraming（与 MCP 等标准一致）
 */
public class PluginManager {
    private let logger: (String, String) -> Unit   // (pluginId, line) 日志回调
    private let lock: Mutex = Mutex()
    private var udsPath: ?String = None            // Some → UDS 模式
    private var udsServer: ?UnixServerTransport = None
    private let udsServerLock: Mutex = Mutex()

    public init(logger: (String, String) -> Unit) {
        this.logger = logger
    }

    public init() {
        this.logger = { _, _ => () }
    }

    /**
     * UDS 模式构造：宿主监听 udsPath，插件以客户端身份连接
     * @param udsPath Unix Domain Socket 监听路径（如 "/tmp/cordis.sock"）
     */
    public init(udsPath: String, logger: (String, String) -> Unit) {
        this.udsPath = Some(udsPath)
        this.logger = logger
    }

    /**
     * UDS 模式构造（无日志）
     */
    public init(udsPath: String) {
        this.udsPath = Some(udsPath)
        this.logger = { _, _ => () }
    }

    public prop isUdsMode: Bool {
        get() {
            this.udsPath.isSome()
        }
    }

    /**
     * 拉起插件进程并建立 RPC 连接（不等待握手）
     * @throws ProcessException 进程创建失败时
     * @throws Exception UDS 模式下插件未在超时内连接时
     */
    public func launch(entry: PluginEntry): PluginInstance {
        match (this.udsPath) {
            case None => this.launchStdio(entry)
            case Some(path) => this.launchUds(entry, path)
        }
    }

    /**
     * 热卸载：关闭 RPC 连接 → 强杀进程 → 回收退出码
     *
     * 幂等：已处于 Unloading 的实例直接返回（防重复 terminate）。
     * 注意：调用方（PluginHost.removePlugin）已先 transitionStatus(Unloading)，
     * 因此这里不能仅凭状态判断——用独立标志位防止重复执行。
     *
     * @return 子进程退出码（正常退出为退出码，被信号杀死为信号编号）
     */
    public func terminate(instance: PluginInstance): Int64 {
        if (!instance.terminateLock.tryLock()) {
            return 0   // 已有 terminate 在进行
        }
        try {
            instance.transitionTo(InstanceStatus.Unloading)
            try {
                instance.client.close()
            } catch (e: Exception) {
                ()
            }
            instance.process.terminate(force: true)
            instance.process.wait()
        } finally {
            instance.terminateLock.unlock()
        }
    }

    /**
     * 探测插件连接是否已关闭（stdout/socket EOF）
     * 用于崩溃检测：client 因 EOF 自动停止后 isClosed() 为 true
     */
    public func isExited(instance: PluginInstance): Bool {
        instance.client.isClosed()
    }

    /**
     * 关闭 UDS 监听（释放 socket；测试与宿主退出时调用）
     * stdio 模式无操作
     */
    public func close(): Unit {
        synchronized(this.udsServerLock) {
            match (this.udsServer) {
                case Some(s) =>
                    s.close()
                    this.udsServer = None
                case None => ()
            }
        }
    }

    // ── stdio 模式（默认）──────────────────────────────────────────────

    private func launchStdio(entry: PluginEntry): PluginInstance {
        let proc = launch(entry.source, entry.args.toArray(),
            stdIn: ProcessRedirect.Pipe,
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe)
        let transport = PipeTransport(proc)
        // 换行帧协议：与插件侧 LineStdioTransport（readln 逐行）保持一致
        let client = JsonRpcClient(transport, framing: NewlineFraming())
        client.start()
        let instance = PluginInstance(entry, proc, client)
        this.forwardStderr(instance)
        instance
    }

    // ── UDS 模式 ──────────────────────────────────────────────────────

    private func launchUds(entry: PluginEntry, path: String): PluginInstance {
        let server = this.ensureUdsServer(path)
        // 向插件传递 UDS 地址：args 追加 --uds <path>
        let args = ArrayList<String>(entry.args)
        args.add("--uds")
        args.add(path)
        let proc = launch(entry.source, args.toArray(),
            stdIn: ProcessRedirect.Pipe,
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe)
        // 阻塞等待插件连接（超时判定启动失败；UDS connect 进入 backlog，
        // 因此 accept 顺序与 launch 顺序一致）
        match (server.acceptConnection(10 * Duration.second)) {
            case Some(transport) =>
                // UDS 是可靠流式读，用标准 Content-Length 帧（与插件侧 runUds 一致）
                let client = JsonRpcClient(transport, framing: ContentLengthFraming())
                client.start()
                let instance = PluginInstance(entry, proc, client)
                this.forwardStderr(instance)
                instance
            case None =>
                // 启动失败/超时：回收进程
                try {
                    proc.terminate(force: true)
                    proc.wait()
                } catch (e: Exception) {
                    ()
                }
                throw Exception("plugin '${entry.id}' did not connect via UDS '${path}' within timeout")
        }
    }

    /**
     * 惰性创建 UDS 监听（bind 一次，多插件依次 accept）
     * bind 前清理残留 socket 文件（文件已存在则 bind 失败）
     */
    private func ensureUdsServer(path: String): UnixServerTransport {
        synchronized(this.udsServerLock) {
            match (this.udsServer) {
                case Some(s) => s
                case None =>
                    removeIfExists(Path(path))
                    let s = UnixServerTransport(path)
                    this.udsServer = Some(s)
                    s
            }
        }
    }

    // ── 公共辅助 ──────────────────────────────────────────────────────

    /**
     * 独立线程转发插件 stderr 到宿主日志
     * stderr 仅供插件打日志；进程退出后 readln 返回 None，线程自然结束
     */
    private func forwardStderr(instance: PluginInstance): Unit {
        spawn {
            let reader = StringReader(instance.process.stdErrPipe)
            while (let Some(line) <- reader.readln()) {
                this.logger(instance.entry.id, line)
            }
        }
    }
}
