#!/usr/bin/env python3
"""Drive mojo-lsp-server like an editor session and time every request.

    timing_session.py <lsp-binary> <fixture.mojo>

The companion to complete.py: where that asks for one completion, this runs
a typing session -- didOpen, a loop of didChange+completion at the three
Cocoa positions in cocoa_completion.mojo, a Mojo-side completion, then
shutdown -- and prints per-request latencies as the editor sees them, plus
the MODULAR_COCOAKB_TIMING stderr report the instrumented server prints at
exit (one table: per query name, count, total/avg/max ms, rows). The server
cancels stale completions ("outdated request"); those show up as ~0 ms
latencies, so the table -- not the latency list -- is the record of the SQL
that actually ran.
"""
import json, os, select, subprocess, sys, time

exe, doc = sys.argv[1], sys.argv[2]
text0 = open(doc).read()
uri = "file:///tmp/ide_session.mojo"
D = "/Volumes/xb/mojo2026/MojoCocoa/dist/CocoaMojo"

env = dict(os.environ)
env.update({
    "MODULAR_COCOAKB_TIMING": "1",
    "MODULAR_MOJO_MAX_COCOAKB_PATH": f"{D}/share/cocoa.sqlite",
    "MODULAR_MOJO_MAX_IMPORT_PATH": ",".join(
        [f"{D}/lib/mojo/stdlib", f"{D}/lib/mojo/max", f"{D}/lib/mojo/kernels"]),
})

proc = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, env=env)
next_id = 1
latencies = []  # (label, seconds)

def send(msg):
    b = json.dumps(msg).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(b) + b)
    proc.stdin.flush()

buf = b""
def read_frame(timeout=60):
    global buf
    deadline = time.time() + timeout
    while True:
        if b"\r\n\r\n" in buf:
            head, rest = buf.split(b"\r\n\r\n", 1)
            length = None
            for line in head.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":")[1].strip())
            if length is not None and len(rest) >= length:
                body, buf = rest[:length], rest[length:]
                return json.loads(body)
        timeout_left = deadline - time.time()
        if timeout_left <= 0:
            raise TimeoutError("no frame within timeout; buf=%r" % buf[:200])
        r, _, _ = select.select([proc.stdout], [], [], min(timeout_left, 5))
        if not r:
            continue
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            raise EOFError("server closed stdout; stderr=%r" % proc.stderr.read()[:2000])
        buf += chunk

def request(method, params, label):
    global next_id
    rid = next_id; next_id += 1
    t0 = time.perf_counter()
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    while True:
        frame = read_frame()
        if frame.get("id") == rid:
            break  # notifications and server->client msgs skipped
    latencies.append((label, time.perf_counter() - t0))
    return frame

def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})

def did_change(text, version):
    notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": version},
        "contentChanges": [{"text": text}]})

# --- session ---
request("initialize", {"processId": None, "rootUri": None,
                       "capabilities": {}}, "initialize")
notify("initialized", {})
notify("textDocument/didOpen", {"textDocument": {
    "uri": uri, "languageId": "mojo", "version": 1, "text": text0}})

# fixture lines (0-based): 6 class, 7 instance selector, 8 class selector,
# 2 = the import line for a Mojo-side completion.
POSITIONS = {
    "class": (6, len('    let cls = ObjCClass.lookup["NSWin')),
    "inst":  (7, len('    let a = msg_send[ObjCObject, "NSWindow", "setTit')),
    "clsm":  (8, len('    let b = msg_send[ObjCObject, "NSWindow", "allo')),
    "mojo":  (2, len("from std.objc import ObjCClas")),
}

def complete(label, pos):
    r = request("textDocument/completion",
                {"textDocument": {"uri": uri},
                 "position": {"line": pos[0], "character": pos[1]}}, label)
    items = r.get("result", {}).get("items", [])
    return len(items)

n = complete("first:classes", POSITIONS["class"])
n = complete("first:selector", POSITIONS["inst"])
n = complete("first:class-method", POSITIONS["clsm"])

# typing loop: the selector prefix grows, the way it does while a person types
prefixes = ["setT", "setTi", "setTit", "setTitl", "setTitle"]
lines = text0.split("\n")
for i, p in enumerate(prefixes * 3):
    lines = text0.split("\n")
    lines[7] = f'    let a = msg_send[ObjCObject, "NSWindow", "{p}"](cls)'
    did_change("\n".join(lines), 100 + i)
    pos = (7, len(f'    let a = msg_send[ObjCObject, "NSWindow", "{p}'))
    complete(f"typing:{p}", pos)

# class-name typing
for i, p in enumerate(["NSWi", "NSWin", "NSWindo"]):
    lines = text0.split("\n")
    lines[6] = f'    let cls = ObjCClass.lookup["{p}"]()'
    did_change("\n".join(lines), 200 + i)
    pos = (6, len(f'    let cls = ObjCClass.lookup["{p}'))
    complete(f"typing-class:{p}", pos)

# Mojo-side completion (forces the parse/elaborate path, not the string path)
complete("mojo-path:1st", POSITIONS["mojo"])
lines = text0.split("\n"); lines.insert(3, "# a plain edit while typing")
did_change("\n".join(lines), 300)
complete("mojo-path:after-edit", (3, 1))

request("shutdown", None, "shutdown")
notify("exit", None)
try:
    proc.wait(timeout=15)
except subprocess.TimeoutExpired:
    proc.kill()

print("=== request latencies (editor's view) ===")
for label, s in latencies:
    print(f"  {s * 1000:9.1f} ms  {label}")

stderr = proc.stderr.read().decode(errors="replace")
print("=== server stderr (CocoaKB timing report) ===")
print(stderr[-4000:] if stderr.strip() else "(no output)")
