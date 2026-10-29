"""Owner-local preference review. No conversations or audio are imported."""

from __future__ import annotations

import argparse
import hashlib
import json
import secrets
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HTML = """<!doctype html><html lang="zh-Hant-TW"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Miku 的說話方式</title><style>
:root{color-scheme:dark;font:17px/1.7 -apple-system,BlinkMacSystemFont,sans-serif;background:#0d1f22;color:#eaf7f6}
body{max-width:850px;margin:auto;padding:32px 20px 120px}h1{font-size:30px;margin-bottom:0}p{color:#a8c5c5}
header{position:sticky;top:0;background:#0d1f22ed;padding:12px 0;z-index:1;backdrop-filter:blur(12px)}
article{border:1px solid #315352;border-radius:18px;margin:22px 0;padding:22px;background:#142b2e}
h2{font-size:18px;margin:0;color:#8edbd4}.user{color:#eef9f8;margin:10px 0 18px}
.options{display:grid;grid-template-columns:1fr 1fr;gap:12px}button{font:inherit;border-radius:12px;border:1px solid #416963;padding:14px;color:inherit;background:#1b3739;cursor:pointer;text-align:left}
button:hover{border-color:#83d8cc}button[aria-pressed=true]{border-color:#92e7d9;background:#24574f;box-shadow:0 0 0 1px #92e7d9}
.small{font-size:14px;padding:7px 14px;margin-top:12px;margin-right:10px;color:#b8d1cf}.label{display:block;font-size:13px;color:#94b9b6;margin-bottom:5px}
footer{position:fixed;bottom:0;left:0;right:0;background:#112a2eec;border-top:1px solid #315352;padding:14px 20px;display:flex;justify-content:center;align-items:center;gap:20px}
#finish{background:#83ddd0;color:#10312b;font-weight:650;text-align:center}#status{font-size:14px;color:#a8c5c5}button:disabled{opacity:.45;cursor:default}
@media(max-width:600px){.options{grid-template-columns:1fr}body{padding-top:12px}h1{font-size:25px}}
</style><header><h1>Miku 的說話方式</h1><p>選比較像你心目中的 Miku。可以略過，也可以稍後繼續。</p><div id="progress"></div></header>
<main id="questions"></main><footer><span id="status" role="status">正在載入…</span><button id="finish">完成校準</button></footer>
<script>
const token=__TOKEN__;let choices={},rows=[];let saving=Promise.resolve();
function progress(){document.querySelector('#progress').textContent=`已選 ${Object.keys(choices).length} / ${rows.length} 題`;document.querySelector('#finish').disabled=Object.keys(choices).length===0;}
function save(completed=false){const snapshot={choices:{...choices},completed};saving=saving.catch(()=>{}).then(async()=>{const r=await fetch('/selection',{method:'POST',headers:{'Content-Type':'application/json','X-Review-Token':token},body:JSON.stringify(snapshot)});if(!r.ok)throw Error('save');document.querySelector('#status').textContent=completed?'校準已儲存，謝謝你！':'已儲存';}).catch(()=>{document.querySelector('#status').textContent='儲存失敗，請再試一次';});return saving;}
function choose(row,value,card){choices[row.id]=value;for(const b of card.querySelectorAll('[data-value]'))b.setAttribute('aria-pressed',String(b.dataset.value===value));progress();save();}
async function load(){const r=await fetch('/data');if(!r.ok)throw Error('load');const d=await r.json();rows=d.rows;choices=d.choices;const main=document.querySelector('#questions');rows.forEach((row,i)=>{const card=document.createElement('article');const h=document.createElement('h2');h.textContent=`${String(i+1).padStart(2,'0')} · ${row.scenario}`;card.append(h);const u=document.createElement('div');u.className='user';u.textContent=row.user;card.append(u);const options=document.createElement('div');options.className='options';for(const value of ['A','B']){const b=document.createElement('button');b.dataset.value=value;b.setAttribute('aria-pressed',String(choices[row.id]===value));const label=document.createElement('span');label.className='label';label.textContent=value;const text=document.createElement('span');text.textContent=row[value];b.append(label,text);b.onclick=()=>choose(row,value,card);options.append(b);}card.append(options);for(const [value,title] of [['both','都可以'],['neither','都不喜歡']]){const b=document.createElement('button');b.className='small';b.dataset.value=value;b.textContent=title;b.setAttribute('aria-pressed',String(choices[row.id]===value));b.onclick=()=>choose(row,value,card);card.append(b);}main.append(card);});progress();document.querySelector('#status').textContent='選擇會自動儲存';}
document.querySelector('#finish').onclick=()=>save(true);load().catch(()=>document.querySelector('#status').textContent='載入失敗，請重新整理');
</script></html>"""


def serve(root: Path, port: int) -> None:
    data_dir = root / "data"
    dataset = data_dir / "calibration.jsonl"
    raw = dataset.read_bytes()
    rows = [json.loads(line) for line in raw.splitlines() if line.strip()]
    allowed = {row["id"] for row in rows}
    if len(allowed) != len(rows) or len(rows) != 50:
        raise ValueError("Expected 50 unique review items")
    selection_path = data_dir / "calibration-selections.json"
    token = secrets.token_urlsafe(32)
    page = HTML.replace("__TOKEN__", json.dumps(token)).encode()

    def choices() -> dict:
        try:
            value = json.loads(selection_path.read_text())
            return {k: v for k, v in value.items() if k in allowed and v in {"A", "B", "both", "neither"}}
        except (OSError, ValueError, AttributeError):
            return {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def respond(self, status: int, body: bytes, content_type: str = "application/json") -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/":
                self.respond(200, page, "text/html; charset=utf-8")
            elif self.path == "/data":
                visible = [{k: row[k] for k in ("id", "scenario", "user", "A", "B")} for row in rows]
                self.respond(200, json.dumps({"rows": visible, "choices": choices()}, ensure_ascii=False).encode())
            else:
                self.respond(404, b"{}")

        def do_POST(self):
            expected_origin = f"http://127.0.0.1:{self.server.server_port}"
            if self.path != "/selection" or self.headers.get("Origin") != expected_origin or not secrets.compare_digest(self.headers.get("X-Review-Token", ""), token):
                self.respond(403, b"{}")
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 16_384:
                    raise ValueError("length")
                value = json.loads(self.rfile.read(length))
                selected = value["choices"]
                completed = value["completed"]
                if not isinstance(selected, dict) or not isinstance(completed, bool) or not all(k in allowed and v in {"A", "B", "both", "neither"} for k, v in selected.items()):
                    raise ValueError("choices")
                if completed and not selected:
                    raise ValueError("empty review")
                staging = selection_path.with_suffix(".tmp")
                staging.write_text(json.dumps(selected, ensure_ascii=False, indent=2) + "\n")
                staging.chmod(0o600)
                staging.replace(selection_path)
                review = {"version": 1, "completed": completed, "dataset_sha256": hashlib.sha256(raw).hexdigest(), "selected_count": len(selected), "updated_at": datetime.now(timezone.utc).isoformat()}
                (data_dir / "calibration-review.json").write_text(json.dumps(review, indent=2) + "\n")
                self.respond(200, b'{"saved":true}')
            except (KeyError, ValueError, TypeError, OSError):
                self.respond(400, b"{}")

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    (root / "runtime").mkdir(parents=True, exist_ok=True)
    (root / "runtime/calibration-url.json").write_text(json.dumps({"url": f"http://127.0.0.1:{server.server_port}/", "pid": __import__("os").getpid()}) + "\n")
    print(f"http://127.0.0.1:{server.server_port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.home() / "Library/Application Support/MikuTraining")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    serve(args.root, args.port)
