"""Opt-in CPU checks for adapter math; never load model weights."""
import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/persona_training"))


@unittest.skipUnless(os.environ.get("MIKU_TEST_MLX") == "1", "Use the isolated Mac environment for CPU operator checks")
class MLXOperatorTests(unittest.TestCase):
    def setUp(self):
        import mlx.core as mx
        mx.set_default_device(mx.cpu)

    def test_float_adapter_fuse_preserves_output(self):
        import mlx.core as mx
        import mlx.nn as nn
        from mlx_vlm.trainer.peft.lora_layers import LoRALinear
        base = nn.Linear(32, 16, bias=False)
        base.freeze()
        adapter = LoRALinear.from_base(base, r=4, scale=2)
        x = mx.ones((1, 32))
        before, after = adapter(x), adapter.fuse()(x)
        mx.eval(before, after)
        self.assertTrue(mx.allclose(before, after).item())

    def test_prepared_vlm_batches_supervise_only_final_reply_and_eos(self):
        import mlx.core as mx
        from types import SimpleNamespace
        from mlx_vlm.trainer import Trainer, VLMTrainingArgs
        from completion_tokens import mlx_completion
        from test_completion_tokens import ExactTokenizer, row

        tokenizer = ExactTokenizer()
        rows = [row("你好。"), row("A longer reply with different padding.")]
        prepared = [mlx_completion(tokenizer, item, 1024) for item in rows]
        args = VLMTrainingArgs(iters=1, batch_size=2, max_seq_length=1024)
        trainer = Trainer(SimpleNamespace(config={}), args, train_dataset=prepared,
            processing_class=SimpleNamespace(tokenizer=tokenizer), prepared=True)
        batch = next(iter(trainer.task.batches(trainer.train_dataset, train=False)))
        self.assertIs(trainer.train_dataset, prepared)
        actual = []
        for ids, mask in zip(batch["input_ids"].tolist(), batch["completion_mask"].tolist()):
            actual.append(tokenizer.decode([token for token, active in zip(ids, mask) if active]))
        expected = [item["completion"][0]["content"] + tokenizer.eos_token for item in rows]
        self.assertCountEqual(actual, expected)
        self.assertTrue(mx.all(batch["completion_mask"] <= batch["attention_mask"]).item())

    def test_nvfp4_frozen_base_passes_finite_input_gradient(self):
        import mlx.core as mx
        import mlx.nn as nn
        from mlx.utils import tree_flatten
        from mlx_vlm.trainer.peft.lora_layers import LoRALinear

        class Tiny(nn.Module):
            def __init__(self):
                super().__init__()
                self.first = LoRALinear.from_base(nn.Linear(64, 64, bias=False), r=4, scale=2)
                self.first.linear.freeze()
                self.second = nn.QuantizedLinear.from_linear(nn.Linear(64, 64, bias=False), group_size=16, bits=4, mode="nvfp4")

            def __call__(self, x): return self.second(self.first(x))

        model = Tiny()
        x = mx.ones((2, 64))
        loss, grads = nn.value_and_grad(model, lambda m: mx.mean(m(x) ** 2))(model)
        flat = tree_flatten(grads)
        mx.eval(loss, [g for _, g in flat])
        self.assertEqual(len(flat), 2)
        self.assertTrue(mx.isfinite(loss).item())
        self.assertTrue(all(mx.all(mx.isfinite(g)).item() for _, g in flat))


if __name__ == "__main__": unittest.main()
