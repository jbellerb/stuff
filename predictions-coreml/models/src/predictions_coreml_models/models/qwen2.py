import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from anemll.models.qwen2_5_model import Qwen25ForCausalLM

_DEVICE = "cpu"


def kv_cache_states(
    model: Qwen25ForCausalLM, prefix: str = "model.model."
) -> list[ct.StateType]:
    config = model.config
    head_dim = getattr(
        config, "head_dim", config.hidden_size // config.num_attention_heads
    )
    # num_hidden_layers * 2 for interleaved K and V entries
    n = config.num_hidden_layers * 2
    return [
        ct.StateType(
            wrapped_type=ct.TensorType(
                shape=(n, config.num_key_value_heads, config.state_length, head_dim),
                dtype=np.float16,
            ),
            name=f"{prefix}kv_cache_0",
        )
    ]


def _reset_kv_cache(module: nn.Module | torch.jit.ScriptModule) -> None:
    for name, buf in module.named_buffers():
        if "kv_cache_" in name:
            buf.zero_()


def _logit_outputs(n: int = 16) -> list[ct.TensorType]:
    return [ct.TensorType(name=f"logits{i}", dtype=np.float16) for i in range(1, n + 1)]


class _InferWrapper(nn.Module):
    def __init__(self, m: Qwen25ForCausalLM, state_length: int) -> None:
        super().__init__()
        self.model = m
        self._state_length = state_length

    def forward(
        self,
        input_ids: torch.Tensor,
        position_ids: torch.Tensor,
        causal_mask: torch.Tensor,
        current_pos: torch.Tensor,
    ) -> tuple:
        # update_mask is accepted by the model signature but unused in
        # computation. Pass a fixed zeros tensor so it's baked as a constant
        # and eliminated during CoreML conversion.
        update_mask = torch.zeros(
            (1, 1, self._state_length, 1), dtype=torch.float16, device=_DEVICE
        )
        return self.model(
            input_ids=input_ids,
            update_mask=update_mask,
            position_ids=position_ids,
            causal_mask=causal_mask,
            current_pos=current_pos,
            IN_PREFILL=False,
        )


def convert_infer(model: Qwen25ForCausalLM, context_length: int) -> ct.models.MLModel:
    wrapper = _InferWrapper(model, model.config.state_length).eval()
    sample = (
        torch.zeros((1, 1), dtype=torch.int32, device=_DEVICE),
        torch.zeros((1,), dtype=torch.int32, device=_DEVICE),
        torch.zeros((1, 1, 1, context_length), dtype=torch.float16, device=_DEVICE),
        torch.zeros((1,), dtype=torch.int32, device=_DEVICE),
    )

    _reset_kv_cache(wrapper)
    traced = torch.jit.trace(wrapper, sample)
    _reset_kv_cache(wrapper)
    _reset_kv_cache(traced)

    return ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, 1), dtype=np.int32),
            ct.TensorType(name="position_ids", shape=(1,), dtype=np.int32),
            ct.TensorType(
                name="causal_mask", shape=(1, 1, 1, context_length), dtype=np.float16
            ),
            ct.TensorType(name="current_pos", shape=(1,), dtype=np.int32),
        ],
        outputs=_logit_outputs(),
        states=kv_cache_states(model),
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
    )


class _PrefillWrapper(nn.Module):
    def __init__(self, m: Qwen25ForCausalLM, num_layers: int, batch_size: int) -> None:
        super().__init__()
        # keep as self.model so the buffer path "model.model.kv_cache_0" matches
        # what kv_cache_states() declares for ct.StateType
        self.model = m
        self._num_layers = num_layers
        self._batch_size = batch_size

    def forward(
        self,
        input_ids: torch.Tensor,
        position_ids: torch.Tensor,
        causal_mask: torch.Tensor,
        current_pos: torch.Tensor,
        update_mask: torch.Tensor,
    ) -> tuple:
        # update_mask: [1, 1, state_length, batch_size]
        transformer = self.model.model
        hidden_states = transformer.embed_tokens(input_ids)
        # hidden_states: [1, batch_size, hidden_size]
        rotary_emb = transformer.get_rotary_embedding_prefill(position_ids)

        # keep: [1, 1, state_length, 1] (zeros at written positions)
        keep = 1.0 - update_mask.sum(dim=-1, keepdim=True)

        for layer_idx in range(self._num_layers):
            layer = transformer.layers[layer_idx]
            normed = layer.input_layernorm(hidden_states)

            # q: [1, num_heads,    batch_size, head_dim]
            # k: [1, num_kv_heads, batch_size, head_dim]
            # v: [1, num_kv_heads, batch_size, head_dim]
            q, k, v = layer.self_attn.get_new_kv_cache_prefill(
                normed, current_pos, rotary_emb
            )

            # scatter k/v into the unified KV cache via update_mask matmul.
            # update_mask: [1, 1,            state_length, batch_size]
            # k/v:         [1, num_kv_heads, batch_size,   head_dim]
            # result:      [1, num_kv_heads, state_length, head_dim]
            kv_cache = transformer.kv_cache_0
            ki = layer_idx
            vi = layer_idx + self._num_layers

            kv_cache[ki : ki + 1] = kv_cache[ki : ki + 1] * keep + torch.matmul(
                update_mask, k
            )
            kv_cache[vi : vi + 1] = kv_cache[vi : vi + 1] * keep + torch.matmul(
                update_mask, v
            )

            # read back full K/V for attention (squeeze layer dim)
            k_full = kv_cache[ki : ki + 1].squeeze(0)
            v_full = kv_cache[vi : vi + 1].squeeze(0)

            attn_out = layer.self_attn.forward_prefill(
                hidden_states=normed,
                query_states=q,
                kv_cache_layer=(k_full, v_full),
                causal_mask=causal_mask,
            )
            hidden_states = hidden_states + attn_out
            hidden_states = hidden_states + layer.mlp(
                layer.post_attention_layernorm(hidden_states)
            )

        hidden_states = transformer.norm(hidden_states)

        # extract last token position for logits
        last = hidden_states[:, self._batch_size - 1 : self._batch_size, :]
        x = last.permute(0, 2, 1).unsqueeze(2).to(torch.float16)
        return tuple(
            getattr(self.model, f"lm_head16_{i}")(x).squeeze(2).transpose(1, 2)
            for i in range(1, 17)
        )


def convert_prefill(
    model: Qwen25ForCausalLM, context_length: int, batch_size: int
) -> ct.models.MLModel:
    state_length = model.config.state_length
    num_layers = model.config.num_hidden_layers

    wrapper = _PrefillWrapper(model, num_layers, batch_size).eval()
    sample = (
        torch.zeros((1, batch_size), dtype=torch.int32, device=_DEVICE),
        torch.zeros((batch_size,), dtype=torch.int32, device=_DEVICE),
        torch.zeros(
            (1, 1, batch_size, context_length), dtype=torch.float16, device=_DEVICE
        ),
        torch.zeros((1,), dtype=torch.int32, device=_DEVICE),
        torch.zeros(
            (1, 1, state_length, batch_size), dtype=torch.float16, device=_DEVICE
        ),
    )

    _reset_kv_cache(wrapper)
    traced = torch.jit.trace(wrapper, sample)
    _reset_kv_cache(wrapper)
    _reset_kv_cache(traced)

    return ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, batch_size), dtype=np.int32),
            ct.TensorType(name="position_ids", shape=(batch_size,), dtype=np.int32),
            ct.TensorType(
                name="causal_mask",
                shape=(1, 1, batch_size, context_length),
                dtype=np.float16,
            ),
            ct.TensorType(name="current_pos", shape=(1,), dtype=np.int32),
            # update_mask has 1.0 at [0, 0, start_pos + i, i] for each token i
            # in the batch. This scatter approach avoids the dynamic-start slice
            # write that gets baked at trace time.
            ct.TensorType(
                name="update_mask",
                shape=(1, 1, state_length, batch_size),
                dtype=np.float16,
            ),
        ],
        outputs=_logit_outputs(),
        states=kv_cache_states(model),
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
    )
