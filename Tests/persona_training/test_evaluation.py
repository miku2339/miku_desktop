import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from urllib.error import HTTPError

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/"scripts/persona_training"))
from evaluation import check_reply, color_check, endpoint_url, evaluate, image_png, language_check, request_reply, summarize_blind_review, validate_heldout, verify_model_availability, vision_comparison


def case(index=0):
    return {"id":f"blind-{index}","family":f"unseen-{index//5}","language":["zh-TW","ja","en","yue","ko"][index%5],"mode":"text" if index//5%2==0 else "voice","context":{},"selection_policy":"never_use_for_training_or_checkpoint_selection","messages":[{"role":"user","content":f"first {index}"},{"role":"assistant","content":"prior"},{"role":"user","content":f"current {index}"}],"expected_assertions":{"json_schema":True}}


class EndpointTests(unittest.TestCase):
    def test_loopback_only_and_no_embedded_credentials(self):
        self.assertEqual(endpoint_url("http://127.0.0.1:8000/v1"),"http://127.0.0.1:8000/v1/chat/completions")
        self.assertEqual(endpoint_url("http://[::1]:8000/v1"),"http://[::1]:8000/v1/chat/completions")
        for value in ["https://example.com/v1","http://localhost:8000/v1","http://user:pass@127.0.0.1:8000/v1","http://127.0.0.1/v1?key=secret"]:
            with self.assertRaises(ValueError): endpoint_url(value)

    def test_real_stub_http_request_and_no_external_redirect(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                body=json.dumps({"data":[{"id":"stub"}]}).encode();self.send_response(200);self.end_headers();self.wfile.write(body)
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if body.get("redirect"):
                    self.send_response(302);self.send_header("Location","https://example.com/not-allowed");self.end_headers();return
                content=json.dumps({"text":"我有在聽。","emotion":"calm","action":"idle"},ensure_ascii=False)
                self.send_response(200);self.end_headers();self.wfile.write(json.dumps({"choices":[{"message":{"content":content},"finish_reason":"stop"}]}).encode())
        server=ThreadingHTTPServer(("127.0.0.1",0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        endpoint=f"http://127.0.0.1:{server.server_port}/v1"
        try:
            response=request_reply(endpoint,{"messages":[]})
            self.assertEqual(json.loads(response["content"])["text"],"我有在聽。")
            verify_model_availability({"baseline":{"endpoint":endpoint,"model":"stub"}})
            with self.assertRaises(ValueError): verify_model_availability({"candidate":{"endpoint":endpoint,"model":"missing"}})
            with self.assertRaises(HTTPError) as caught: request_reply(endpoint,{"redirect":True})
            caught.exception.close()
        finally:
            server.shutdown();server.server_close();thread.join()


class EvaluationTests(unittest.TestCase):
    def test_invalid_json_never_gets_claimed_as_verified(self):
        result=check_reply("friendly plain text",case())
        self.assertFalse(result["json"])
        self.assertEqual(result["honesty"],"needs_human_review")
        for response in [{"text":"你好。","emotion":{},"action":"idle"},{"text":"你好。","emotion":"calm","action":"idle","extra":"unexpected"}]:
            self.assertFalse(check_reply(json.dumps(response),case())["json"])

    def test_language_checks_keep_human_review_boundary(self):
        self.assertEqual(language_check("係呀，我聽緊你講。","zh-TW")["status"],"fail")
        self.assertTrue(language_check("我有在聽。","zh-TW")["native_review_required"])
        self.assertEqual(language_check("我們的關係不會因為這件事改變。","zh-TW")["status"],"pass")
        self.assertEqual(language_check("你好。","yue")["status"],"needs_review")

    def test_dating_denial_is_flagged_not_semantically_certified(self):
        row=case();row["context"]={"relationship":"dating"}
        response=json.dumps({"text":"我們只是朋友。","emotion":"calm","action":"idle"})
        checked=check_reply(response,row)
        self.assertIn("possible_established_relationship_denial",checked["flags"])
        self.assertEqual(checked["relationship"],"needs_human_review")

    def test_false_tool_claim_is_flagged(self):
        row=case();row["family"]="blind-no_tool_result"
        response=json.dumps({"text":"照片已經保存了。","emotion":"happy","action":"nod"})
        self.assertIn("possible_false_saved_photo_claim",check_reply(response,row)["flags"])

    def test_synthetic_vision_fixture_and_color_regression(self):
        self.assertTrue(image_png("red","blue").startswith(b"\x89PNG"))
        self.assertTrue(color_check('{"text":"紅色"}',"red"))
        self.assertFalse(color_check('{"text":"藍色"}',"red"))

    def test_vision_delta_is_a_fixture_result_not_visual_acceptance(self):
        stats={"baseline":{"vision_checks":15,"vision_color_correct":15},"candidate":{"vision_checks":15,"vision_color_correct":14}}
        report=vision_comparison(stats)
        self.assertFalse(report["full_visual_quality_verified"])
        self.assertFalse(report["variants"]["candidate"]["fixture_regression_target_met"])
        self.assertAlmostEqual(report["variants"]["candidate"]["delta_percentage_points"],-100/15)

    def test_full_suite_rejects_family_and_prompt_leakage(self):
        cases=[case(i) for i in range(250)]
        self.assertEqual(validate_heldout(cases,[],[])["cases"],250)
        with self.assertRaises(ValueError): validate_heldout(cases,[{"family":"unseen-1","messages":[]}],[])
        with self.assertRaises(ValueError): validate_heldout(cases,[],[{"family":"calibration","user":"current 0"}])
        cases[0]["language"]="ko"
        with self.assertRaises(ValueError): validate_heldout(cases,[],[])

    def variants(self):
        return {name:{"endpoint":"http://127.0.0.1:8000/v1","model":name,"system_prompt":"Synthetic evaluation only"} for name in ["baseline","candidate"]}

    def transport(self,endpoint,body):
        return {"content":json.dumps({"text":"我有在聽。","emotion":"calm","action":"idle"}),"finish_reason":"stop"}

    def test_blind_review_never_invents_preference_score(self):
        with tempfile.TemporaryDirectory() as temp:
            output=Path(temp)/"run"
            report=evaluate([case()],self.variants(),output,transport=self.transport,include_vision=False)
            self.assertFalse(report["acceptance_passed"])
            self.assertIsNone(report["persona_preference_rate"])
            review=json.loads((output/"blind-review.jsonl").read_text())
            self.assertNotIn("baseline",review["answers"])
            self.assertIsNone(review["preferred"])
            summary=summarize_blind_review(output,"baseline","candidate")
            self.assertEqual(summary["pending"],1)
            self.assertFalse(summary["target_met"])
            with self.assertRaises(ValueError): summarize_blind_review(output,"unknown","candidate")

    def test_resource_change_stops_before_another_request(self):
        calls=[]
        def resources(): return {"allowed":len(calls)==0,"reasons":["voice_call_active"]}
        def transport(endpoint,body): calls.append(body);return self.transport(endpoint,body)
        with tempfile.TemporaryDirectory() as temp:
            output=Path(temp)/"run"
            with self.assertRaises(RuntimeError): evaluate([case()],self.variants(),output,transport=transport,include_vision=False,resource_check=resources)
            self.assertEqual(len(calls),1)
            self.assertEqual(json.loads((output/"summary.json").read_text())["status"],"paused_resource_gate")

    def test_manual_ties_count_half_and_third_model_is_not_a_tie(self):
        with tempfile.TemporaryDirectory() as temp:
            output=Path(temp)
            rows=[];mapping={}
            for i in range(250):
                rows.append({"case_id":str(i),"preferred":"A" if i<125 else "tie" if i<225 else "B"})
                mapping[str(i)]={"A":"candidate","B":"baseline"}
            (output/"blind-review.jsonl").write_text("".join(json.dumps(r)+"\n" for r in rows))
            (output/"blind-map.json").write_text(json.dumps(mapping))
            report=summarize_blind_review(output,"baseline","candidate")
            self.assertEqual(report["candidate_score"],175)
            self.assertEqual(report["preference_rate"],0.7)
            self.assertTrue(report["target_met"])
            self.assertFalse(report["acceptance_passed"])
            mapping["0"]["C"]="prompt_only"
            rows[0]["preferred"]="C"
            (output/"blind-map.json").write_text(json.dumps(mapping))
            (output/"blind-review.jsonl").write_text("".join(json.dumps(r)+"\n" for r in rows))
            report=summarize_blind_review(output,"baseline","candidate")
            self.assertEqual(report["pending"],1)
            self.assertIsNone(report["preference_rate"])
            rows[0]["pairwise_preferences"]={"A:B":"tie"}
            (output/"blind-review.jsonl").write_text("".join(json.dumps(r)+"\n" for r in rows))
            self.assertEqual(summarize_blind_review(output,"baseline","candidate")["pending"],0)


if __name__=="__main__": unittest.main()
