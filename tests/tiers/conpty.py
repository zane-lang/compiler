"""A program run on a Windows pseudo-console (ConPTY, Windows 10 and later),
which Python's `pty` module, POSIX's alone, does not give: the program's
stdout is a terminal, so it writes each line as it prints it, as
tests/runtime/output.c's terminal case runs one. Its stderr is a pipe of
its own. What the console writes is its screen, drawn with escape
sequences, which are taken out, leaving the lines the program printed."""

import ctypes
from ctypes import wintypes
import re
import threading

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

EXTENDED_STARTUPINFO_PRESENT = 0x00080000
CREATE_UNICODE_ENVIRONMENT = 0x00000400
STARTF_USESTDHANDLES = 0x00000100
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
HANDLE_FLAG_INHERIT = 0x00000001
INFINITE = 0xFFFFFFFF


class COORD(ctypes.Structure):
    _fields_ = [("X", wintypes.SHORT), ("Y", wintypes.SHORT)]


class SECURITY_ATTRIBUTES(ctypes.Structure):
    _fields_ = [("nLength", wintypes.DWORD), ("lpSecurityDescriptor", wintypes.LPVOID),
                ("bInheritHandle", wintypes.BOOL)]


class STARTUPINFOW(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR), ("lpDesktop", wintypes.LPWSTR),
                ("lpTitle", wintypes.LPWSTR), ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD),
                ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD), ("dwXCountChars", wintypes.DWORD),
                ("dwYCountChars", wintypes.DWORD), ("dwFillAttribute", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD),
                ("lpReserved2", ctypes.POINTER(ctypes.c_byte)), ("hStdInput", wintypes.HANDLE),
                ("hStdOutput", wintypes.HANDLE), ("hStdError", wintypes.HANDLE)]


class STARTUPINFOEXW(ctypes.Structure):
    _fields_ = [("StartupInfo", STARTUPINFOW), ("lpAttributeList", wintypes.LPVOID)]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE), ("dwProcessId", wintypes.DWORD),
                ("dwThreadId", wintypes.DWORD)]


kernel32.CreatePseudoConsole.argtypes = [COORD, wintypes.HANDLE, wintypes.HANDLE, wintypes.DWORD,
                                         ctypes.POINTER(wintypes.HANDLE)]
kernel32.CreatePseudoConsole.restype = ctypes.c_long
kernel32.ClosePseudoConsole.argtypes = [wintypes.HANDLE]
kernel32.ClosePseudoConsole.restype = None
kernel32.CreatePipe.argtypes = [ctypes.POINTER(wintypes.HANDLE), ctypes.POINTER(wintypes.HANDLE),
                                ctypes.POINTER(SECURITY_ATTRIBUTES), wintypes.DWORD]
kernel32.SetHandleInformation.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD]
kernel32.InitializeProcThreadAttributeList.argtypes = [wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD,
                                                       ctypes.POINTER(ctypes.c_size_t)]
kernel32.UpdateProcThreadAttribute.argtypes = [wintypes.LPVOID, wintypes.DWORD, ctypes.c_size_t, wintypes.LPVOID,
                                               ctypes.c_size_t, wintypes.LPVOID, wintypes.LPVOID]
kernel32.DeleteProcThreadAttributeList.argtypes = [wintypes.LPVOID]
kernel32.CreateProcessW.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, wintypes.LPVOID, wintypes.LPVOID,
                                    wintypes.BOOL, wintypes.DWORD, wintypes.LPVOID, wintypes.LPCWSTR,
                                    ctypes.POINTER(STARTUPINFOW), ctypes.POINTER(PROCESS_INFORMATION)]
kernel32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                              wintypes.LPVOID]
kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]

# The console's own drawing: control sequences, operating-system commands,
# and the two-byte escapes, as ECMA-48 spells them.
ESCAPES = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")


def _check(ok, what):
    if not ok:
        raise OSError(ctypes.get_last_error(), what)


def _pipe(inherit_write=False):
    read, write = wintypes.HANDLE(), wintypes.HANDLE()
    attributes = SECURITY_ATTRIBUTES(ctypes.sizeof(SECURITY_ATTRIBUTES), None, inherit_write)
    _check(kernel32.CreatePipe(ctypes.byref(read), ctypes.byref(write), ctypes.byref(attributes), 0), "CreatePipe")
    if inherit_write:
        _check(kernel32.SetHandleInformation(read, HANDLE_FLAG_INHERIT, 0), "SetHandleInformation")
    return read, write


def _drain(handle, into, seen=None):
    buffer = ctypes.create_string_buffer(4096)
    got = wintypes.DWORD()
    while kernel32.ReadFile(handle, buffer, len(buffer), ctypes.byref(got), None) and got.value:
        into.append(buffer.raw[:got.value])
        if seen:
            seen(b"".join(into))


def lines(screen):
    """The text the console drew, without its escape sequences or the
    blanks it pads its screen's lines with, each line ended by `\\n`."""
    text = ESCAPES.sub(b"", screen).replace(b"\r\n", b"\n").replace(b"\r", b"")
    drawn = [line.rstrip() for line in text.split(b"\n")]
    while drawn and not drawn[-1]:
        drawn.pop()
    return b"".join(line + b"\n" for line in drawn)


def run(args, env, first_line=None):
    """Runs `args` with environment `env` on a pseudo-console: its exit code,
    what it printed, and what it wrote to stderr. `first_line` is called
    once the console has drawn the program's first line."""
    in_read, in_write = _pipe()
    out_read, out_write = _pipe()
    err_read, err_write = _pipe(inherit_write=True)
    console = wintypes.HANDLE()
    # Wide enough that no line of the program's wraps.
    result = kernel32.CreatePseudoConsole(COORD(512, 64), in_read, out_write, 0, ctypes.byref(console))
    if result != 0:
        raise OSError(result, "CreatePseudoConsole")
    kernel32.CloseHandle(in_read)
    kernel32.CloseHandle(out_write)
    size = ctypes.c_size_t()
    kernel32.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(size))
    attributes = ctypes.create_string_buffer(size.value)
    _check(kernel32.InitializeProcThreadAttributeList(attributes, 1, 0, ctypes.byref(size)),
           "InitializeProcThreadAttributeList")
    _check(kernel32.UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console,
                                              ctypes.sizeof(wintypes.HANDLE), None, None),
           "UpdateProcThreadAttribute")
    start = STARTUPINFOEXW()
    start.StartupInfo.cb = ctypes.sizeof(STARTUPINFOEXW)
    # Stdin and stdout null, so the program opens the console's; stderr the
    # pipe, the one handle it inherits.
    start.StartupInfo.dwFlags = STARTF_USESTDHANDLES
    start.StartupInfo.hStdError = err_write
    start.lpAttributeList = ctypes.cast(attributes, wintypes.LPVOID)
    block = ctypes.create_unicode_buffer("".join(f"{k}={v}\0" for k, v in env.items()) + "\0")
    command = ctypes.create_unicode_buffer(" ".join(f'"{a}"' for a in args))
    info = PROCESS_INFORMATION()
    try:
        _check(kernel32.CreateProcessW(None, command, None, None, True,
                                       EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, block, None,
                                       ctypes.byref(start.StartupInfo), ctypes.byref(info)), "CreateProcessW")
    finally:
        kernel32.CloseHandle(err_write)
        kernel32.DeleteProcThreadAttributeList(attributes)
    kernel32.CloseHandle(info.hThread)
    called = []

    def seen(screen):
        if first_line and not called and b"\n" in lines(screen):
            called.append(True)
            first_line()

    out, err = [], []
    readers = [threading.Thread(target=_drain, args=(out_read, out, seen)),
               threading.Thread(target=_drain, args=(err_read, err))]
    for reader in readers:
        reader.start()
    kernel32.WaitForSingleObject(info.hProcess, INFINITE)
    code = wintypes.DWORD()
    kernel32.GetExitCodeProcess(info.hProcess, ctypes.byref(code))
    kernel32.CloseHandle(info.hProcess)
    # Closing the console ends its output, once the reader has drained it.
    kernel32.ClosePseudoConsole(console)
    for reader in readers:
        reader.join(30)
    kernel32.CloseHandle(out_read)
    kernel32.CloseHandle(err_read)
    kernel32.CloseHandle(in_write)
    return code.value, lines(b"".join(out)).decode(), b"".join(err).decode()
