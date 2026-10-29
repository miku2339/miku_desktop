"""Opt-in CPU checks for adapter math; never load model weights."""
import os
import unittest


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
