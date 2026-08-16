import subprocess, threading, time, json, os
os.chdir("/home/ystyle/Projects/Cangjie/cordis-cj")
p = subprocess.Popen(["./target/release/bin/ystyle::cordis_plugin.examples.inject_demo"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
def read_out():
    while True:
        line = p.stdout.readline()
        if not line: break
        print(f"[OUT] {line!r}", flush=True)
def read_err():
    while True:
        line = p.stderr.readline()
        if not line: break
        print(f"[ERR] {line!r}", flush=True)
threading.Thread(target=read_out, daemon=True).start()
threading.Thread(target=read_err, daemon=True).start()
time.sleep(1.0)
p.stdin.write(b'{"jsonrpc":"2.0","id":0,"result":{"ok":true,"providers":{"add":"e2e"}}}\n'); p.stdin.flush()
time.sleep(1.0)
p.stdin.write(b'{"jsonrpc":"2.0","id":1,"result":{"undoId":"u1"}}\n'); p.stdin.flush()
time.sleep(0.5)
print("=== invoke calc ===", flush=True)
p.stdin.write(b'{"jsonrpc":"2.0","id":2,"method":"invoke","params":{"service":"calc","method":"calc","args":[]}}\n'); p.stdin.flush()
time.sleep(2.0)
# 响应消费者的 add 转发（id 是消费者 server.request 发的）
print("=== responding add forward ===", flush=True)
p.stdin.write(b'{"jsonrpc":"2.0","id":0,"result":11}\n'); p.stdin.flush()
time.sleep(2.0)
p.kill(); p.wait()
