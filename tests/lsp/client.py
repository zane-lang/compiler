"""A small Language Server Protocol client that drives `zanec --lsp`.

It speaks JSON-RPC over the server's standard input and output, keeps every
notification the server sends, and answers the requests a server may send a
client (`client/registerCapability`) with an empty result.
"""

import json
import os
import pathlib
import subprocess
import threading
import queue

ROOT = pathlib.Path(__file__).resolve().parents[2]
ZANEC = ROOT / "_build" / "default" / "bin" / "zanec" / "zanec.exe"


def uri(path):
    # Absolute, but with symbolic links kept, as an editor names a file.
    return pathlib.Path(path).absolute().as_uri()


class Client:
    def __init__(self, args=(), cwd=None, env=None):
        self.process = subprocess.Popen(
            [str(ZANEC), "--lsp", *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd,
            env=env,
        )
        self.messages = queue.Queue()
        self.notifications = []
        self.next_id = 0
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        stream = self.process.stdout
        while True:
            length = None
            while True:
                line = stream.readline()
                if not line:
                    self.messages.put(None)
                    return
                line = line.decode().strip()
                if not line:
                    break
                name, _, value = line.partition(":")
                if name.lower() == "content-length":
                    length = int(value)
            self.messages.put(json.loads(stream.read(length)))

    def _send(self, message):
        body = json.dumps(message).encode()
        self.process.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.process.stdin.flush()

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def _next(self, timeout):
        message = self.messages.get(timeout=timeout)
        if message is None:
            raise EOFError("the server closed its output")
        if "method" in message and "id" in message:
            self._send({"jsonrpc": "2.0", "id": message["id"], "result": None})
            return None
        if "method" in message:
            self.notifications.append(message)
            return None
        return message

    def request(self, method, params, timeout=60):
        self.next_id += 1
        ident = self.next_id
        self._send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        while True:
            message = self._next(timeout)
            if message is not None and message.get("id") == ident:
                if "error" in message:
                    raise ResponseError(message["error"])
                return message.get("result")

    def diagnostics(self, path, timeout=60):
        """The last diagnostics published for `path`, after a round trip
        that makes sure the server has checked what it was sent."""
        self.request("textDocument/documentSymbol", {"textDocument": {"uri": uri(path)}}, timeout)
        found = None
        for n in self.notifications:
            if n["method"] == "textDocument/publishDiagnostics" and n["params"]["uri"] == uri(path):
                found = n["params"]["diagnostics"]
        return found

    def initialize(self, root, builds=None, encodings=("utf-16",)):
        options = {"builds": builds} if builds is not None else None
        result = self.request(
            "initialize",
            {
                "processId": os.getpid(),
                "rootUri": uri(root),
                "capabilities": {"general": {"positionEncodings": list(encodings)}},
                "initializationOptions": options,
            },
        )
        self.notify("initialized", {})
        return result

    def open(self, path, text=None):
        path = pathlib.Path(path)
        if text is None:
            text = path.read_text()
        self.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": uri(path), "languageId": "zane", "version": 1, "text": text}},
        )
        return text

    def change(self, path, text, version=2):
        self.notify(
            "textDocument/didChange",
            {"textDocument": {"uri": uri(path), "version": version}, "contentChanges": [{"text": text}]},
        )

    def at(self, method, path, line, character, **extra):
        params = {"textDocument": {"uri": uri(path)}, "position": {"line": line, "character": character}}
        params.update(extra)
        return self.request(method, params)

    def close(self):
        try:
            self.request("shutdown", None, timeout=10)
            self.notify("exit", None)
            self.process.wait(timeout=10)
        except Exception:
            self.process.kill()
        finally:
            self.process.stdin.close()
            self.process.stdout.close()
            self.process.stderr.close()


class ResponseError(Exception):
    def __init__(self, error):
        super().__init__(error.get("message"))
        self.error = error


def position_of(text, needle, occurrence=0, offset=0):
    """The (line, character) of `needle`'s occurrence in `text`, in UTF-16
    units, moved `offset` characters into it."""
    index = -1
    for _ in range(occurrence + 1):
        index = text.index(needle, index + 1)
    index += offset
    before = text[:index]
    line = before.count("\n")
    column = before[before.rfind("\n") + 1 :]
    return line, len(column.encode("utf-16-le")) // 2
