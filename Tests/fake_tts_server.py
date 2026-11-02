"""A stand-in local TTS service for the speech retry tests.

model "flaky": the first request answers 500 (like the real service's SOURCE_MISMATCH), the next
one returns audio. model "broken": always 500. Listens on 127.0.0.1 and writes its port to argv[1].
"""
import http.server
import json
import struct
import sys
import threading
import time
import urllib.parse

counts = {}
request_options = {}
counts_lock = threading.Lock()


def silent_wav(seconds=0.3, rate=16000):
    samples = int(rate * seconds)
    data = b"\x00\x00" * samples
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(data))
    return header + data


def pcm_frame(kind, seq, payload=b"", **extra):
    header = dict(v=1, type=kind, id="test-pcm", seq=seq, language="en", seed=42,
                  sample_rate=16000, channels=1, format="pcm_s16le", payload_bytes=len(payload))
    header.update(extra)
    encoded = json.dumps(header).encode()
    return struct.pack(">I", len(encoded)) + encoded + payload


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        query = urllib.parse.urlparse(self.path)
        model = urllib.parse.parse_qs(query.query).get("model", [""])[0]
        if query.path == "/v1/audio/capabilities" and model.startswith(("pcm-", "style-")):
            streaming = [] if model in {"pcm-no-stream", "style-both"} else ["en"]
            styles = ["neutral", "happy", "gentle", "sleepy"] if model == "style-both" else ["neutral"]
            payload = json.dumps(dict(version=1, model="wrong" if model == "pcm-wrong-model" else model,
                                      languages=["en"], formats=["wav", "pcm_s16le"], styles=styles,
                                      streaming_languages=streaming)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if query.path not in {"/counts", "/options"}:
            self.send_error(404)
            return
        with counts_lock:
            value = {"count": counts.get(model, 0)} if query.path == "/counts" else request_options.get(model, {})
            payload = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        model = body.get("model", "")
        with counts_lock:
            counts[model] = counts.get(model, 0) + 1
            count = counts[model]
            request_options[model] = {key: body[key] for key in ("style", "stream", "response_format") if key in body}
        if model.startswith("pcm-") and body.get("response_format") == "pcm_s16le":
            first = pcm_frame("audio", 0, b"\0\0" * 2000)
            second = pcm_frame("audio", 2 if model == "pcm-sequence" else 1, b"\0\0" * 2000)
            ending = pcm_frame("end", 2, total_samples=4000)
            if model == "pcm-error":
                second = pcm_frame("error", 1, code="SOURCE_MISMATCH")
                ending = b""
            if model == "pcm-truncated":
                ending = b""
            if model == "pcm-end-junk":
                ending += b"invalid trailing bytes"
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.qimake.miku-pcm")
            self.send_header("Content-Length", str(len(first) + len(second) + len(ending)))
            self.end_headers()
            try:
                self.wfile.write(first[:3]); self.wfile.flush()
                self.wfile.write(first[3:]); self.wfile.flush()
                time.sleep(0.5 if model == "pcm-delayed" else 0.15)
                self.wfile.write(second); self.wfile.flush()
                self.wfile.write(ending); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if model == "voice-reply-slow":
            time.sleep(0.4)
        if model == "voice-reply-oversized":
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(17 * 1024 * 1024))
            self.end_headers()
            return
        if self.path != "/v1/audio/speech" or model == "broken" or (model == "korean-check" and body.get("language") != "ko") or (model == "flaky" and count == 1) or (model == "voice-reply-fails-second" and count > 1):
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
        try:
            self.wfile.write(audio)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
