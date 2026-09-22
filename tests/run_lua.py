#!/usr/bin/env python3
"""Execute the real Lua 5.4 code with mocked FXServer APIs and Python-backed test JSON.
Uses liblua5.4 through ctypes so no pip package or Lua JSON dependency is required.
This is a test harness, not a runtime component of the FiveM resource.
"""
from __future__ import annotations
import ctypes as c
import ctypes.util
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
name = ctypes.util.find_library('lua5.4')
if not name:
    raise SystemExit('Install Lua 5.4 shared library (Debian/Ubuntu: apt install liblua5.4-0).')
lua = c.CDLL(name)
P = c.c_void_p

def bind(name: str, result, *args):
    fn = getattr(lua, name)
    fn.restype = result
    fn.argtypes = list(args)
    return fn

new = bind('luaL_newstate', P)
openlibs = bind('luaL_openlibs', None, P)
close = bind('lua_close', None, P)
gettop = bind('lua_gettop', c.c_int, P)
settop = bind('lua_settop', None, P, c.c_int)
typeof = bind('lua_type', c.c_int, P, c.c_int)
string = bind('lua_tolstring', P, P, c.c_int, c.POINTER(c.c_size_t))
number = bind('lua_tonumberx', c.c_double, P, c.c_int, P)
integer = bind('lua_tointegerx', c.c_longlong, P, c.c_int, P)
isinteger = bind('lua_isinteger', c.c_int, P, c.c_int)
boolean = bind('lua_toboolean', c.c_int, P, c.c_int)
pushnil = bind('lua_pushnil', None, P)
pushbool = bind('lua_pushboolean', None, P, c.c_int)
pushint = bind('lua_pushinteger', None, P, c.c_longlong)
pushnum = bind('lua_pushnumber', None, P, c.c_double)
pushstr = bind('lua_pushlstring', P, P, c.c_char_p, c.c_size_t)
createtable = bind('lua_createtable', None, P, c.c_int, c.c_int)
settable = bind('lua_settable', None, P, c.c_int)
setfield = bind('lua_setfield', None, P, c.c_int, c.c_char_p)
getfield = bind('lua_getfield', c.c_int, P, c.c_int, c.c_char_p)
nextitem = bind('lua_next', c.c_int, P, c.c_int)
getmeta = bind('lua_getmetatable', c.c_int, P, c.c_int)
setmeta = bind('lua_setmetatable', c.c_int, P, c.c_int)
setglobal = bind('lua_setglobal', None, P, c.c_char_p)
loadfile = bind('luaL_loadfilex', c.c_int, P, c.c_char_p, c.c_char_p)
loadstring = bind('luaL_loadstring', c.c_int, P, c.c_char_p)
pcall = bind('lua_pcallk', c.c_int, P, c.c_int, c.c_int, c.c_int, c.c_longlong, P)
CALLBACK = c.CFUNCTYPE(c.c_int, P)
pushcallback = bind('lua_pushcclosure', None, P, CALLBACK, c.c_int)


def pop(L, count=1):
    settop(L, -count - 1)


def read_string(L, idx):
    length = c.c_size_t()
    ptr = string(L, idx, c.byref(length))
    return c.string_at(ptr, length.value).decode('utf-8') if ptr else ''


def read_value(L, idx, depth=0):
    if depth > 24:
        raise ValueError('Test JSON depth exceeded')
    idx = idx if idx > 0 else gettop(L) + idx + 1
    kind = typeof(L, idx)
    if kind == 0:
        return None
    if kind == 1:
        return bool(boolean(L, idx))
    if kind == 3:
        return integer(L, idx, None) if isinteger(L, idx) else number(L, idx, None)
    if kind == 4:
        return read_string(L, idx)
    if kind != 5:
        raise ValueError(f'Unsupported test JSON type: {kind}')
    array = False
    if getmeta(L, idx):
        getfield(L, -1, b'__jsontype')
        array = read_string(L, -1) == 'array'
        pop(L, 2)
    output = {}
    pushnil(L)
    while nextitem(L, idx):
        key = read_value(L, -2, depth + 1)
        output[key] = read_value(L, -1, depth + 1)
        pop(L)
    if array or (output and all(type(k) is int for k in output) and set(output) == set(range(1, len(output) + 1))):
        return [output.get(i) for i in range(1, len(output) + 1)]
    return output


def write_value(L, value):
    if value is None:
        pushnil(L)
    elif isinstance(value, bool):
        pushbool(L, value)
    elif isinstance(value, int):
        pushint(L, value)
    elif isinstance(value, float):
        pushnum(L, value)
    elif isinstance(value, str):
        raw = value.encode('utf-8')
        pushstr(L, raw, len(raw))
    elif isinstance(value, (dict, list)):
        createtable(L, len(value) if isinstance(value, list) else 0, len(value) if isinstance(value, dict) else 0)
        for k, v in (enumerate(value, 1) if isinstance(value, list) else value.items()):
            write_value(L, k)
            write_value(L, v)
            settable(L, -3)
        if isinstance(value, list):
            createtable(L, 0, 1)
            write_value(L, 'array')
            setfield(L, -2, b'__jsontype')
            setmeta(L, -2)
    else:
        raise TypeError(type(value))


@CALLBACK
def encode(L):
    try:
        value = json.dumps(read_value(L, 1), ensure_ascii=False, separators=(',', ':'), allow_nan=False)
        write_value(L, value)
        return 1
    except Exception as exc:
        pushnil(L)
        write_value(L, str(exc))
        return 2


@CALLBACK
def decode(L):
    try:
        write_value(L, json.loads(read_string(L, 1)))
        return 1
    except Exception as exc:
        pushnil(L)
        write_value(L, str(exc))
        return 2


L = new()
openlibs(L)
try:
    for name, callback in [(b'_json_encode', encode), (b'_json_decode', decode)]:
        pushcallback(L, callback, 0)
        setglobal(L, name)
    bootstrap = b'''json={encode=function(v) local a,b=_json_encode(v); if b then error(b) end; return a end,
        decode=function(v) local a,b=_json_decode(v); if b then error(b) end; return a end}'''
    if loadstring(L, bootstrap) or pcall(L, 0, 0, 0, 0, None):
        raise RuntimeError(read_string(L, -1))
    files = list((ROOT / 'resource').rglob('*.lua'))
    for file in files:
        if loadfile(L, str(file).encode(), None):
            raise RuntimeError(f'{file}: {read_string(L, -1)}')
        pop(L)
    print(f'Lua 5.4 syntax: {len(files)} files passed', flush=True)
    if loadfile(L, b'tests/test_bridge.lua', None) or pcall(L, 0, 0, 0, 0, None):
        raise RuntimeError(read_string(L, -1))
finally:
    close(L)
