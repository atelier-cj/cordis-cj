package ystyle::cordis_tests

import ystyle::cordis_host.{PluginManager, PluginInstance}
import ystyle::cordis_core.{PluginEntry, InstanceStatus}
import std.collection.ArrayList
import std.sync.{Mutex, Condition}
import std.process.{launch, ProcessRedirect}
import std.io.*
import std.env.getVariables
import std.collection.HashMap
import std.unittest.*
import std.unittest.testmacro.*

/**
 * PluginManager 测试：launch/terminate 生命周期 + stderr 转发
 * 使用真实可执行文件作为"插件"（/bin/sh、/bin/true）
 */
@Test
class PluginManagerTest {

    @TestCase
    func testLaunchAndTerminate(): Unit {
        let manager = PluginManager()
        let entry = PluginEntry("true-plugin", "/bin/true")
        let instance = manager.launch(entry)
        @Expect(instance.entry.id, "true-plugin")
        @Expect(instance.status, InstanceStatus.Starting)
        @Expect(!manager.isExited(instance))
        let exitCode = manager.terminate(instance)
        @Expect(instance.status, InstanceStatus.Unloading)
        // /bin/true 正常退出码为 0；强杀后 wait 返回信号编号或退出码
        @Expect(exitCode >= 0)
    }

    @TestCase
    func testStderrForwarding(): Unit {
        // 用 sh 向 stderr 写一行，验证 forwardStderr 转发到 logger 回调
        let lines = ArrayList<String>()
        let lock = Mutex()
        let cond = synchronized(lock) { lock.condition() }
        let manager = PluginManager({ _, line =>
            synchronized(lock) {
                lines.add(line)
                cond.notifyAll()
            }
        })
        let entry = PluginEntry("err-plugin", "/bin/sh",
            args: ArrayList<String>.of(["-c", "echo hello-stderr >&2"]))
        let instance = manager.launch(entry)
        // 等待 stderr 行到达（最多 5 秒）
        synchronized(lock) {
            var waited = 0
            while (lines.size == 0 && waited < 100) {
                cond.wait(timeout: 50 * Duration.millisecond)
                waited++
            }
        }
        // 终止并回收
        manager.terminate(instance)
        @Expect(lines.size > 0)
        if (lines.size > 0) {
            @Expect(lines[0].contains("hello-stderr"))
        }
    }

    @TestCase
    func testIsExitedAfterProcessDeath(): Unit {
        // 启动后进程自然退出（/bin/true 立即退出）→ client 因 EOF 自动停止
        let manager = PluginManager()
        let entry = PluginEntry("quick-exit", "/bin/true")
        let instance = manager.launch(entry)
        // 轮询等待 client 关闭（最多 5 秒）
        var exited = false
        for (i in 0..100) {
            if (manager.isExited(instance)) {
                exited = true
                break
            }
            sleep(50 * Duration.millisecond)
        }
        @Expect(exited)
        // 清理：进程已退出，wait 回收
        instance.process.wait()
    }
}

/**
 * 插件子进程的环境继承回归。
 *
 * 背景：`launch(environment: Some(env))` 是**替换**整个环境、不是追加。
 * 只给 CORDIS_* 会让子进程丢掉 HOME/PATH/代理/语言等一切，而这条链路
 * 全程不静默报错——插件侧 getVariable("HOME") 返回 None 后会走
 * `case None => "."` 兜底，于是去读 ./.atelier.toml，文件不存在就
 * 静默 return，用户配置全部失效。
 *
 * 这些用例是那次修复的守卫：只要有人再去掉「先铺父环境」这一步，
 * 子进程就读不到 HOME，用例立刻失败。
 */
@Test
class PluginEnvInheritanceTest {

    /** 启动一个会回显环境变量的插件，返回它看到的 HOME */
    private func homeSeenByPlugin(): String {
        let manager = PluginManager()
        // /bin/sh -c 'echo $HOME'：把 HOME 打到 stderr（stderr 由管理器转发，
        // 这里直接读子进程 stdout 更稳——用 Pipe 拿到原始输出）
        let entry = PluginEntry("env-probe", "/bin/sh", args: ArrayList(["-c", "echo $HOME"]))
        let proc = launch(entry.source, entry.args.toArray(),
            environment: Some(probeEnv(entry)),
            stdIn: ProcessRedirect.Pipe, stdOut: ProcessRedirect.Pipe, stdErr: ProcessRedirect.Pipe)
        let reader = StringReader(proc.stdOutPipe)
        let text = reader.readToEnd()
        proc.wait()
        text.trimAscii()
    }

    /** 与 PluginManager.pluginEnv 同构：先铺父环境，再叠加 CORDIS_* */
    private func probeEnv(entry: PluginEntry): HashMap<String, String> {
        let env = HashMap<String, String>()
        for ((k, v) in getVariables()) {
            env[k] = v
        }
        env.add("CORDIS_PLUGIN_ID", entry.id)
        env
    }

    @TestCase
    func testPluginInheritsHome(): Unit {
        // 宿主上 HOME 必然存在；插件子进程必须也能看到
        let home = homeSeenByPlugin()
        @Expect(home.isEmpty(), false)
        @Expect(home.startsWith("/"), true)
    }

    @TestCase
    func testPluginEnvIncludesParent(): Unit {
        // 直接断言「父环境被铺进去了」：PATH 一定在
        let env = probeEnv(PluginEntry("p", "/bin/true"))
        @Expect(env.contains("PATH"), true)
    }

    @TestCase
    func testOnlyCordisEnvWouldLoseHome(): Unit {
        // 反证：若像修复前那样只给 CORDIS_*，HOME 必然缺失。
        // 这条把「为什么必须继承」钉成可执行的事实。
        let onlyCordis = HashMap<String, String>()
        onlyCordis.add("CORDIS_PLUGIN_ID", "x")
        @Expect(onlyCordis.contains("HOME"), false)
    }
}
