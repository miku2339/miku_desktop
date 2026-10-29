"""Exact final-assistant loss spans using the unchanged official chat template."""

from __future__ import annotations

import json

COMPLETION_MASK_VERSION = "official_json_eos_v1"


def tokenize_completion(tokenizer, row: dict, max_length: int | None = None) -> dict:
    prompt, completion = row["prompt"], row["completion"]
    if not getattr(tokenizer, "is_fast", False): raise ValueError("Exact completion masks require a fast tokenizer")
    if not prompt or prompt[-1]["role"] != "user" or len(completion) != 1 or completion[0]["role"] != "assistant":
        raise ValueError("A final user turn and exactly one target assistant are required")
    target = completion[0]["content"].strip()
    value = json.loads(target)
    if not isinstance(value, dict) or set(value) != {"text", "emotion", "action"}:
        raise ValueError("Target must be the complete reply JSON")
    eos, eos_id = tokenizer.eos_token, tokenizer.eos_token_id
    if not isinstance(eos, str) or type(eos_id) is not int: raise ValueError("A unique EOS token is required")
    if any(token in target for token in tokenizer.all_special_tokens):
        raise ValueError("Reply JSON must not inject chat control tokens")
    messages = prompt + completion
    rendered = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=False, enable_thinking=False)
    start = rendered.rfind(target)
    if start < 0: raise ValueError("Official template did not preserve the target JSON")
    end = start + len(target)
    eos_start = rendered.find(eos, end)
    if eos_start < 0 or rendered[end:eos_start].strip() or rendered[eos_start + len(eos):].strip():
        raise ValueError("Final assistant JSON must end at the official EOS boundary")
    encoded = tokenizer(rendered, add_special_tokens=False, return_offsets_mapping=True, truncation=False)
    ids, offsets = list(encoded["input_ids"]), encoded["offset_mapping"]
    official = tokenizer.apply_chat_template(messages, tokenize=True, return_dict=False,
        add_generation_prompt=False, enable_thinking=False)
    if ids != list(official): raise ValueError("Offset tokenization differs from the official full-dialogue template")
    if max_length is not None and len(ids) > max_length:
        raise ValueError(f"Complete dialogue exceeds the configured context: {row.get('id', 'unknown')}")
    mask = []
    for token, (left, right) in zip(ids, offsets):
        inside = start <= left < right <= end
        final_eos = token == eos_id and left == eos_start and right == eos_start + len(eos)
        if (left < start < right or left < end < right) and not inside:
            raise ValueError("A token crosses the assistant JSON boundary")
        mask.append(int(inside or final_eos))
    if len(mask) != len(ids) or sum(token == eos_id and active for token, active in zip(ids, mask)) != 1:
        raise ValueError("Completion mask must contain exactly the final EOS")
    decoded = tokenizer.decode([token for token, active in zip(ids, mask) if active],
        skip_special_tokens=False, clean_up_tokenization_spaces=False)
    if decoded != target + eos:
        raise ValueError("Supervised tokens do not exactly reconstruct the final JSON and EOS")
    return {"input_ids": ids, "completion_mask": mask,
        "labels": [token if active else -100 for token, active in zip(ids, mask)]}


def mlx_completion(tokenizer, row: dict, max_length: int) -> dict:
    import mlx.core as mx

    encoded = tokenize_completion(tokenizer, row, max_length)
    return {"input_ids": mx.array(encoded["input_ids"], dtype=mx.int32),
        "attention_mask": mx.ones((len(encoded["input_ids"]),), dtype=mx.int32),
        "completion_mask": mx.array(encoded["completion_mask"], dtype=mx.int32)}
