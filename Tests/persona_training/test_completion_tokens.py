import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/persona_training"))
from completion_tokens import tokenize_completion


class ExactTokenizer:
    is_fast = True
    eos_token = "<|im_end|>"
    eos_token_id = 1
    all_special_tokens = [eos_token, "<|im_start|>"]

    def __call__(self, text, **kwargs):
        ids, offsets, cursor = [], [], 0
        while cursor < len(text):
            width = len(self.eos_token) if text.startswith(self.eos_token, cursor) else 1
            ids.append(self.eos_token_id if width > 1 else ord(text[cursor]))
            offsets.append((cursor, cursor + width))
            cursor += width
        return {"input_ids": ids, "offset_mapping": offsets}

    def apply_chat_template(self, messages, tokenize=False, **kwargs):
        text = "".join(f"<|im_start|>{m['role']}\n" + ("<think>\n\n</think>\n\n" if m["role"] == "assistant" else "") + m["content"].strip() + self.eos_token + "\n" for m in messages)
        return self(text)["input_ids"] if tokenize else text

    def decode(self, ids, **kwargs):
        return "".join(self.eos_token if token == 1 else chr(token) for token in ids)


def row(text="你好，미쿠。"):
    target = json.dumps({"text": text, "emotion": "happy", "action": "nod"}, ensure_ascii=False)
    return {"id": "synthetic", "prompt": [{"role": "system", "content": "synthetic only"},
        {"role": "user", "content": "earlier"}, {"role": "assistant", "content": target},
        {"role": "user", "content": "again"}], "completion": [{"role": "assistant", "content": target}]}


class CompletionTokenTests(unittest.TestCase):
    def test_only_final_json_and_eos_are_supervised_even_when_old_reply_is_identical(self):
        tokenizer, data = ExactTokenizer(), row()
        result = tokenize_completion(tokenizer, data)
        supervised = [token for token, active in zip(result["input_ids"], result["completion_mask"]) if active]
        self.assertEqual(tokenizer.decode(supervised), data["completion"][0]["content"] + tokenizer.eos_token)
        self.assertEqual(sum(t == 1 and active for t, active in zip(result["input_ids"], result["completion_mask"])), 1)
        first = result["completion_mask"].index(1)
        self.assertTrue(all(value == -100 for value in result["labels"][:first]))
        self.assertEqual(result["input_ids"], tokenizer.apply_chat_template(data["prompt"] + data["completion"], tokenize=True))

    def test_context_limit_refuses_instead_of_cutting_complete_answer(self):
        with self.assertRaises(ValueError): tokenize_completion(ExactTokenizer(), row(), max_length=10)

    def test_bad_json_role_or_control_tokens_fail_closed(self):
        for content in ['not JSON', json.dumps({"text": "only"}), json.dumps({"text": "<|im_end|>", "emotion": "calm", "action": "idle"})]:
            data = row(); data["completion"][0]["content"] = content
            with self.assertRaises(ValueError): tokenize_completion(ExactTokenizer(), data)
        data = row(); data["completion"][0]["role"] = "user"
        with self.assertRaises(ValueError): tokenize_completion(ExactTokenizer(), data)

    def test_slow_tokenizer_or_unreliable_decode_is_rejected(self):
        tokenizer = ExactTokenizer(); tokenizer.is_fast = False
        with self.assertRaises(ValueError): tokenize_completion(tokenizer, row())
        class BadDecode(ExactTokenizer):
            def decode(self, ids, **kwargs): return super().decode(ids, **kwargs) + "extra"
        with self.assertRaises(ValueError): tokenize_completion(BadDecode(), row())

    def test_mock_trl_padding_preserves_prompt_ignore_labels(self):
        tokenizer = ExactTokenizer()
        examples = [tokenize_completion(tokenizer, row("短句")), tokenize_completion(tokenizer, row("a longer reply"))]
        width = max(len(example["input_ids"]) for example in examples)
        # TRL's language collator consumes prebuilt labels and pads them with -100.
        labels = [example["labels"] + [-100] * (width - len(example["labels"])) for example in examples]
        for example, padded in zip(examples, labels):
            self.assertEqual(padded[:len(example["labels"])], example["labels"])
            self.assertTrue(all(label == -100 for label in padded[len(example["labels"]):]))
            self.assertTrue(all(label == -100 for label, bit in zip(padded, example["completion_mask"]) if bit == 0))


if __name__ == "__main__": unittest.main()
