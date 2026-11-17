"""Runs OptimizeBuild.lua inside the LuaJIT that ships in ../runtime (Windows), so no separate
Lua installation is needed. All arguments are passed through:

    python OptimizeBuild.py --class Ranger --ascendancy Deadeye --skill "Lightning Arrow"

For every build file that gets saved, a matching ".code.txt" with the import code for
"Import/Export Build -> Import from website or code" is written next to it.

Several variants at once (one line of arguments per variant, optionally starting with
name=<text>; parallelism defaults to the physical cores and free memory):

    python OptimizeBuild.py --batch variants.txt --out ../batch [--parallel 6]
"""
import base64
import ctypes
import os
import re
import sys
import zlib

SRC = os.path.dirname(os.path.abspath(__file__))
RUNTIME = os.path.join(os.path.dirname(SRC), "runtime")


def lua_string(text):
    level = 1
    while "]" + "=" * level + "]" in text:
        level += 1
    return "[" + "=" * level + "[" + text + "]" + "=" * level + "]"


def run(script, args):
    if hasattr(os, "add_dll_directory"):
        os.add_dll_directory(RUNTIME)
    os.environ["PATH"] = RUNTIME + os.pathsep + os.environ.get("PATH", "")
    os.chdir(SRC)
    lua = ctypes.CDLL(os.path.join(RUNTIME, "lua51.dll"))
    lua.luaL_newstate.restype = ctypes.c_void_p
    lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
    lua.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lua.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
    lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lua.lua_tolstring.restype = ctypes.c_char_p
    state = lua.luaL_newstate()
    lua.luaL_openlibs(state)
    boot = "\n".join([
        'package.path = "../runtime/lua/?.lua;../runtime/lua/?/init.lua;" .. package.path',
        'package.cpath = "../runtime/?.dll;" .. package.cpath',
        "arg = { " + ", ".join(lua_string(a) for a in args) + " }",
        "local ok, err = xpcall(function() dofile(" + lua_string(script) + ") end, debug.traceback)",
        "io.stdout:flush()",
        "if not ok then io.stderr:write(tostring(err), string.char(10)) os.exit(1) end",
    ])
    if lua.luaL_loadstring(state, boot.encode("utf-8")) or lua.lua_pcall(state, 0, 0, 0):
        message = lua.lua_tolstring(state, -1, None)
        sys.stderr.write((message or b"Lua error").decode("utf-8", "replace") + "\n")
        return 1
    return 0


def write_import_codes(log_path):
    with open(log_path, encoding="utf-8", errors="replace") as log:
        saved = re.findall(r"^Saved build: (.+\.xml)\s*$", log.read(), re.M)
    for xml_path in saved:
        if os.path.isfile(xml_path):
            with open(xml_path, "rb") as xml_file:
                code = base64.urlsafe_b64encode(zlib.compress(xml_file.read(), 9)).decode("ascii")
            code_path = xml_path[:-4] + ".code.txt"
            with open(code_path, "w", encoding="ascii") as code_file:
                code_file.write(code)
            print("Import code:  " + code_path)


def free_memory_gb():
    """Free physical memory in GB, or None where it can't be read."""
    if os.name != "nt":
        return None

    class MemoryStatus(ctypes.Structure):
        _fields_ = [("length", ctypes.c_ulong), ("load", ctypes.c_ulong), ("total", ctypes.c_ulonglong),
                    ("available", ctypes.c_ulonglong), ("totalPage", ctypes.c_ulonglong), ("availablePage", ctypes.c_ulonglong),
                    ("totalVirtual", ctypes.c_ulonglong), ("availableVirtual", ctypes.c_ulonglong), ("extended", ctypes.c_ulonglong)]

    status = MemoryStatus()
    status.length = ctypes.sizeof(MemoryStatus)
    if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
        return None
    return status.available / 2 ** 30


def run_batch(batch_file, parallel, out_dir):
    """Run every variant line of batch_file as its own optimiser process, several at once, and rank
    the results. A line holds the usual arguments; `name=<text>` at the start names the variant.
    Each optimiser process peaks at about 1 GB, so the default parallelism is limited by both the
    physical cores and the free memory."""
    import shlex
    import subprocess
    import time
    variants = []
    with open(batch_file, encoding="utf-8") as listing:
        for line in listing:
            line = line.strip()
            if line and not line.startswith("#"):
                args = shlex.split(line, posix=True)
                name = args.pop(0)[5:] if args and args[0].startswith("name=") else "variant%02d" % (len(variants) + 1)
                variants.append((name, args))
    if not parallel:
        cores = max(1, (os.cpu_count() or 2) // 2 - 1)
        memory = free_memory_gb()
        parallel = max(1, min(cores, int(memory // 1.2) if memory else cores))
    os.makedirs(out_dir, exist_ok=True)
    print("Running %d variants, %d at a time, into %s" % (len(variants), parallel, out_dir))
    started = time.time()
    pending, running, results = list(variants), [], []
    while pending or running:
        while pending and len(running) < parallel:
            name, args = pending.pop(0)
            log_path = os.path.join(out_dir, name + ".log")
            log = open(log_path, "wb")
            # The variants already fill the cores; tree workers inside each would only compete
            extra = [] if "--jobs" in args else ["--jobs", "1"]
            command = [sys.executable, os.path.abspath(__file__)] + args + extra + ["--name", name, "--out", out_dir]
            running.append((name, log_path, log, subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, cwd=SRC)))
        time.sleep(1)
        for entry in list(running):
            name, log_path, log, process = entry
            if process.poll() is not None:
                log.close()
                running.remove(entry)
                with open(log_path, encoding="utf-8", errors="replace") as text:
                    content = text.read()
                rares = re.search(r"Rare-only build: (\d+)", content)
                uniques = re.search(r"Build with uniques: (\d+)", content)
                results.append((name, int(rares.group(1)) if rares else None, int(uniques.group(1)) if uniques else None, process.returncode))
                print("[%6.0fs] %-40s %s" % (time.time() - started, name, "done" if process.returncode == 0 else "FAILED, see " + log_path))
    results.sort(key=lambda r: -(r[2] or r[1] or -1))
    lines = ["%-40s %14s %14s" % ("variant", "rares only", "with uniques")]
    for name, rares, uniques, code in results:
        lines.append("%-40s %14s %14s%s" % (name, "{:,}".format(rares) if rares else "-", "{:,}".format(uniques) if uniques else "-", "" if code == 0 else "  (failed)"))
    if results and (results[0][2] or results[0][1]):
        lines.append("")
        lines.append("Best: %s (files: %s)" % (results[0][0], os.path.join(out_dir, results[0][0] + " (...).xml / .txt / .code.txt")))
    report = "\n".join(lines)
    with open(os.path.join(out_dir, "batch-results.txt"), "w", encoding="utf-8") as summary:
        summary.write(report + "\n")
    print("\n" + report)
    print("\nTotal time: %.0fs" % (time.time() - started))
    return 0 if all(r[3] == 0 for r in results) else 1


def main():
    if "--batch" in sys.argv[1:]:
        argv = sys.argv[1:]

        def option(name, default=None):
            return argv[argv.index(name) + 1] if name in argv else default
        sys.exit(run_batch(option("--batch"), int(option("--parallel", 0)), option("--out", os.path.join(SRC, "..", "optimizer-batch"))))
    if "--run" in sys.argv[1:2]:
        # Child mode: Lua writes straight to the inherited stdout
        sys.exit(run("OptimizeBuild.lua", sys.argv[2:]))
    # Lua's output doesn't pass through Python, so run it in a child and tee its stdout
    import subprocess
    import tempfile
    with tempfile.NamedTemporaryFile("w+", suffix=".log", delete=False) as log:
        log_path = log.name
    # Tell the script how to start worker processes for the parallel parts of the search
    os.environ.setdefault("POB_OPTIMIZER_WORKER", '"%s" "%s" --run' % (sys.executable, os.path.abspath(__file__)))
    try:
        child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--run"] + sys.argv[1:],
                                 stdout=subprocess.PIPE, cwd=SRC)
        with open(log_path, "wb") as log:
            for line in child.stdout:
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
                log.write(line)
        code = child.wait()
        if code == 0:
            write_import_codes(log_path)
        sys.exit(code)
    finally:
        os.remove(log_path)


if __name__ == "__main__":
    main()
