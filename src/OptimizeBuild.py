"""Runs OptimizeBuild.lua inside the LuaJIT that ships in ../runtime (Windows), so no separate
Lua installation is needed. All arguments are passed through:

    python OptimizeBuild.py --class Ranger --ascendancy Deadeye --skill "Lightning Arrow"

For every build file that gets saved, a matching ".code.txt" with the import code for
"Import/Export Build -> Import from website or code" is written next to it.
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


def main():
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
