"""A stand-in local TTS service for the speech retry tests.

model "flaky": the first request answers 500 (like the real service's SOURCE_MISMATCH), the next
one returns audio. model "broken": always 500. Listens on 127.0.0.1 and writes its port to argv[1].
"""
import http.server
import json
import struct
import sys

counts = {}


def silent_wav(seconds=0.3, rate=16000):
    samples = int(rate * seconds)
    data = b"\x00\x00" * samples
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(data))
    return header + data


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        model = body.get("model", "")
        counts[model] = counts.get(model, 0) + 1
        if self.path != "/v1/audio/speech" or model == "broken" or (model == "flaky" and counts[model] == 1):
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            payload = b'{"error":"SOURCE_MISMATCH"}'
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        audio = silent_wav()
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(audio)))
        self.end_headers()
        self.wfile.write(audio)


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
