import sys
import threading
import http.server
import socketserver
import ctypes
import json
import os
import urllib.parse
from pathlib import Path

import webview


def resource_dir() -> Path:
    if getattr(sys, "_MEIPASS", None):
        return Path(sys._MEIPASS)
    return Path(__file__).resolve().parent


RES = resource_dir()

PORT = 8765

try:
    ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("jirmaic.Schedy.App")
except Exception:
    pass

try:
    ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
except Exception:
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        pass


DATA_FILE = None
try:
    base = Path(os.environ.get('LOCALAPPDATA') or str(Path.home())) / 'Schedy'
    base.mkdir(parents=True, exist_ok=True)
    DATA_FILE = base / 'schedy-data.json'
except Exception:
    DATA_FILE = Path.home() / 'Schedy' / 'schedy-data.json'
    try:
        DATA_FILE.parent.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

    def log_message(self, *args):
        pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/load':
            try:
                data = None
                if DATA_FILE and DATA_FILE.exists():
                    raw = DATA_FILE.read_text(encoding='utf-8')
                    try:
                        data = json.loads(raw) if raw.strip() else None
                    except Exception:
                        data = None
                body = json.dumps(data if data is not None else None).encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception:
                self.send_response(500)
                self.send_header('Content-Length', '0')
                self.end_headers()
            return
        return super().do_GET()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/save':
            length = int(self.headers.get('Content-Length', '0') or 0)
            body = self.rfile.read(length) if length > 0 else b'{}'
            if DATA_FILE:
                DATA_FILE.write_text(body.decode('utf-8', errors='replace'), encoding='utf-8')
            resp = b'{"ok":true}'
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return
        if parsed.path == '/api/export':
            length = int(self.headers.get('Content-Length', '0') or 0)
            body = self.rfile.read(length) if length > 0 else b'{}'
            try:
                window = webview.windows[0] if webview.windows else None
                if window is not None:
                    result = window.create_file_dialog(
                        webview.SAVE_DIALOG,
                        directory=str(DATA_FILE.parent if DATA_FILE else Path.home()),
                        save_filename='blockboard-schedule.json',
                        file_types=('JSON Files (*.json)', 'All files (*.*)')
                    )
                    if result:
                        path = result[0] if isinstance(result, (list, tuple)) else result
                        Path(path).write_text(body.decode('utf-8', errors='replace'), encoding='utf-8')
                        self.send_response(200)
                        self.send_header('Content-Type', 'application/json')
                        self.send_header('Content-Length', '2')
                        self.end_headers()
                        self.wfile.write(b'{"ok":true}')
                        return
            except Exception:
                pass
            if DATA_FILE:
                p = DATA_FILE.parent / 'blockboard-schedule.json'
                p.write_text(body.decode('utf-8', errors='replace'), encoding='utf-8')
            resp = b'{"ok":true}'
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)
            return
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def set_window_icon():
    try:
        import time
        icon_path = RES / "Schedy.ico"
        if not icon_path.exists():
            return
        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32
        my_pid = kernel32.GetCurrentProcessId()
        hwnds = []
        WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
        def enum_proc(hwnd, lparam):
            pid = ctypes.c_ulong()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if pid.value == my_pid and user32.IsWindowVisible(hwnd):
                hwnds.append(hwnd)
            return True
        for _ in range(60):
            hwnds.clear()
            user32.EnumWindows(WNDENUMPROC(enum_proc), 0)
            if hwnds:
                break
            time.sleep(0.05)
        if not hwnds:
            return
        cx_big = user32.GetSystemMetrics(11)
        cy_big = user32.GetSystemMetrics(12)
        cx_small = user32.GetSystemMetrics(49)
        cy_small = user32.GetSystemMetrics(50)
        def load(cx, cy):
            return user32.LoadImageW(None, str(icon_path), 1, cx, cy, 0x00000010)
        WM_SETICON = 0x0080
        for hwnd in hwnds:
            try:
                dpi = user32.GetDpiForWindow(hwnd) or 96
            except Exception:
                dpi = 96
            scale = dpi / 96.0
            small_px = max(16, round(16 * scale))
            big_px = max(32, round(32 * scale))
            hicon_small = load(small_px, small_px)
            hicon_big = load(big_px, big_px)
            if hicon_small:
                user32.SendMessageW(hwnd, WM_SETICON, 0, hicon_small)
            if hicon_big:
                user32.SendMessageW(hwnd, WM_SETICON, 1, hicon_big)
    except Exception:
        pass


def main():
    server = None
    try:
        server = Server(("127.0.0.1", PORT), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    except OSError:
        server = None

    threading.Thread(target=set_window_icon, daemon=True).start()

    try:
        user_data = Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'Schedy' / 'WebView2'
        user_data.mkdir(parents=True, exist_ok=True)
        webview.create_window(
            "Schedy",
            f"http://127.0.0.1:{PORT}/schedy.html",
            width=1280,
            height=900,
            resizable=True,
            min_size=(900, 650),
            storage_path=str(user_data),
        )
    except Exception:
        webview.create_window(
            "Schedy",
            f"http://127.0.0.1:{PORT}/schedy.html",
            width=1280,
            height=900,
            resizable=True,
            min_size=(900, 650),
        )
    webview.start()
    if server:
        server.shutdown()


if __name__ == "__main__":
    main()
