package ystyle::cordis_host

import ystyle::cordis_core.{PluginEntry, InstanceStatus}
import ystyle::jsonrpc.JsonRpcClient
import std.process.SubProcess
import std.collection.HashMap

/**
 * 插件运行时实例（docs/design-impl.md §2.2）
 */
public class PluginInstance {
    public var entry: PluginEntry
    public var process: SubProcess
    public var client: JsonRpcClient
    public var status: InstanceStatus
    public var provides: HashMap<String, String>   // serviceKey -> undo_id

    public init(entry: PluginEntry, process: SubProcess, client: JsonRpcClient) {
        this.entry = entry
        this.process = process
        this.client = client
        this.status = InstanceStatus.Starting
        this.provides = HashMap<String, String>()
    }
}
