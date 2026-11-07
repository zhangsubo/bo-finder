"""Run Chat Completions contract checks against an ephemeral loopback-only server."""
import http.server
import json
from pathlib import Path
import subprocess
import threading

root = Path(__file__).resolve().parent.parent
requests = []
get_requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        get_requests.append((self.path, self.headers.get("Authorization")))
        kind = self.path.split("/")[1]
        status = 401 if kind == "unauthorized" else 302 if kind == "redirect" else 200
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if kind == "redirect":
            self.send_header("Location", "/leaked/models")
        self.end_headers()
        data = {"object": "list", "data": [{"id": "mimo-v2.6-flash"}, {"id": "mimo-v2-omni"}]}
        self.wfile.write(json.dumps(data).encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append((self.path, body, self.headers.get("Authorization")))
        kind = self.path.split("/")[1]
        status = 401 if kind == "unauthorized" else 302 if kind == "redirect" else 200
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if kind == "redirect":
            self.send_header("Location", "/leaked/chat/completions")
        self.end_headers()
        is_empty = kind in ("empty", "reasoning-truncated")
        is_trunc = kind in ("truncated", "reasoning-truncated")
        data = {"choices": [{"message": {"content": "" if is_empty else "测试纪要"}, "finish_reason": "length" if is_trunc else "stop"}]}
        self.wfile.write(json.dumps(data).encode())


if __name__ == "__main__":
    import platform
    output = root / "build/run_meeting_cloud_tests"
    output.parent.mkdir(exist_ok=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    target = f"{platform.machine()}-apple-macos26.0"
    subprocess.run([
        "xcrun", "swiftc",
        "-sdk", sdk,
        "-target", target,
        "-parse-as-library",
        str(root / "BoFinderApp/MeetingModels.swift"),
        str(root / "BoFinderApp/MeetingServices.swift"),
        str(root / "Tests/MeetingCloudTests.swift"),
        "-o", str(output),
    ], check=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        subprocess.run([str(output), f"http://127.0.0.1:{server.server_port}"], check=True)
        assert len(requests) == 6, "Redirect must not forward credentials"
        for path, body, authorization in requests:
            assert path.endswith("/chat/completions")
            assert body == {"model": "test-model", "messages": [{"role": "user", "content": "测试转录"}], "stream": False}
            assert authorization == "Bearer test-only"
        assert len(get_requests) == 3, "Redirect on /models must not forward credentials"
        for path, authorization in get_requests:
            assert path.endswith("/models")
            assert authorization == "Bearer test-only"
        print("Request schema and no-redirect credential protection passed")
    finally:
        server.shutdown()
        server.server_close()
