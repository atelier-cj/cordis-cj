package ystyle::cordis_host

import ystyle::cordis_core.{PluginEntry, InstanceStatus}
import ystyle::jsonrpc.JsonRpcClient
import std.process.{launch, SubProcess, ProcessRedirect}
import std.io.StringReader
import std.sync.Mutex

/**
 * 插件进程管理器（docs/design-impl.md §3.3）
 *
 * 职责：
 * - launch：拉起插件子进程（三流 Pipe），建立 PipeTransport + JsonRpcClient 连接
 * - terminate：热卸载（关闭连接 + 强杀 + wait 回收退出码，避免僵尸进程）
 * - forwardStderr：独立线程转发插件 stderr 到宿主日志
 * - isExited：探测进程是否已退出（stdout EOF 判定崩溃）
 */
public class PluginManager {
    private let logger: (String, String) -> Unit   // (pluginId, line) 日志回调
    private let lock: Mutex = Mutex()

    public init(logger: (String, String) -> Unit) {
        this.logger = logger
    }

    public init() {
        this.logger = { _, _ => () }
    }

    /**
     * 拉起插件进程并建立 RPC 连接（不等待握手）
     * @throws ProcessException 进程创建失败时
     */
    public func launch(entry: PluginEntry): PluginInstance {
        let proc = launch(entry.source, entry.args.toArray(),
            stdIn: ProcessRedirect.Pipe,
            stdOut: ProcessRedirect.Pipe,
            stdErr: ProcessRedirect.Pipe)
        let transport = PipeTransport(proc)
        let client = JsonRpcClient(transport)
        client.start()
        let instance = PluginInstance(entry, proc, client)
        this.forwardStderr(instance)
        instance
    }

    /**
     * 热卸载：关闭 RPC 连接 → 强杀进程 → 回收退出码
     * @return 子进程退出码（正常退出为退出码，被信号杀死为信号编号）
     */
    public func terminate(instance: PluginInstance): Int64 {
        synchronized(this.lock) {
            if (instance.status == InstanceStatus.Unloading) {
                return 0
            }
            instance.status = InstanceStatus.Unloading
        }
        try {
            instance.client.close()
        } catch (e: Exception) {
            ()
        }
        instance.process.terminate(force: true)
        instance.process.wait()
    }

    /**
     * 探测插件进程是否已退出（stdout EOF）
     * 用于崩溃检测：client 因 EOF 自动停止后 isClosed() 为 true
     */
    public func isExited(instance: PluginInstance): Bool {
        instance.client.isClosed()
    }

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
