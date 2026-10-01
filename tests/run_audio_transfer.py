"""Exercise the real Swift URLSession delegate against a loopback HTTP fixture."""
import http.server
import subprocess
import sys
import threading
import time

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        assert self.headers.get('Range') == 'bytes=0-'
        assert not self.headers.get('Authorization')
        assert not self.headers.get('Cookie')
        route = self.path.strip('/')
        if route in ('stall', 'cancel'):
            time.sleep(4)
            return
        status = 429 if route == 'limited' else 403 if route == 'denied' else 206 if route in ('ok206', 'partial') else 200
        self.send_response(status)
        self.send_header('Content-Type', 'audio/mp4')
        self.send_header('Content-Length', str(200_000_000 if route == 'large' else 4096))
        if route == 'ok206':
            self.send_header('Content-Range', 'bytes 0-4095/4096')
        if route == 'partial':
            self.send_header('Content-Range', 'bytes 0-4095/8192')
        self.end_headers()
        try:
            self.wfile.write(b'A' * (2048 if route == 'truncated' else 4096))
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    subprocess.run([sys.argv[1], f'http://127.0.0.1:{server.server_port}'], check=True, timeout=30)
finally:
    server.shutdown()
