from pathlib import Path

import numpy as np
import torch
from gguf import GGUFReader
from numpy.typing import NDArray


class GGUFModel:
    def __init__(self, path: Path) -> None:
        self.reader = GGUFReader(path)
        self.state_dict = {}

    @property
    def vocab(self) -> dict[str, int]:
        tokens = {}
        tokens_field = self.reader.fields["tokenizer.ggml.tokens"]
        for i, offset in enumerate(tokens_field.data):
            tokens[bytes(tokens_field.parts[offset]).decode("utf-8")] = i

        return tokens

    @property
    def merges(self) -> list[str] | None:
        if "tokenizer.ggml.merges" not in self.reader.fields:
            return None

        merges = []
        merges_field = self.reader.fields["tokenizer.ggml.merges"]
        for offset in merges_field.data:  # can we assume sorted?
            merges.append(bytes(merges_field.parts[offset]).decode("utf-8"))

        return merges

    def _dequantize_q8_0(self, data: bytes, shape: NDArray[np.uint32]) -> np.ndarray:
        block_size = 32
        # each block is 2 bytes (fp16 scale) + 32 bytes (int8 values)
        bytes_per_block = 34

        data_array = np.frombuffer(data, dtype=np.uint8)
        n_elements = np.prod(shape)
        n_blocks = (n_elements + block_size - 1) // block_size

        result = np.zeros(n_elements, dtype=np.float32)
        for block_idx in range(n_blocks):
            block_offset = block_idx * bytes_per_block

            # read scale factor (fp16)
            scale_bytes = data_array[block_offset : block_offset + 2]
            scale = np.frombuffer(scale_bytes.tobytes(), dtype=np.float16)[0]

            # read int8 values
            values_offset = block_offset + 2
            values = data_array[values_offset : values_offset + block_size].view(
                np.int8
            )

            # dequantize
            start_idx = block_idx * block_size
            end_idx = min(start_idx + block_size, n_elements)
            actual_size = end_idx - start_idx

            result[start_idx:end_idx] = values[:actual_size].astype(np.float32) * float(
                scale
            )

        return result.reshape(shape)

    def load_weights(self) -> dict[str, torch.Tensor]:
        if self.state_dict != {}:
            return self.state_dict

        for tensor in self.reader.tensors:
            pytorch_name = map_gguf_name_to_pytorch(tensor.name)

            if tensor.tensor_type == 0:
                np_array = np.frombuffer(tensor.data, dtype=np.float32).reshape(
                    tensor.shape
                )
            elif tensor.tensor_type == 1:
                np_array = (
                    np.frombuffer(tensor.data, dtype=np.float16)
                    .reshape(tensor.shape)
                    .astype(np.float32)
                )
            elif tensor.tensor_type == 8:
                np_array = self._dequantize_q8_0(bytes(tensor.data), tensor.shape)
            else:
                print(
                    f"warning: unsupported tensor type {tensor.tensor_type} for {tensor.name}"
                )
                continue

            torch_tensor = torch.from_numpy(np_array.copy())
            if (
                "embed_tokens.weight" in pytorch_name
                or "lm_head.weight" in pytorch_name
            ):
                torch_tensor = torch_tensor.transpose(0, 1).contiguous()
            elif ".weight" in pytorch_name and len(torch_tensor.shape) == 2:
                torch_tensor = torch_tensor.transpose(0, 1).contiguous()
                torch_tensor = torch_tensor.unsqueeze(-1).unsqueeze(-1)

            self.state_dict[pytorch_name] = torch_tensor

            print(f"loaded {pytorch_name}: {torch_tensor.shape} from {tensor.name}")

        return self.state_dict


def map_gguf_name_to_pytorch(gguf_name: str) -> str:
    # TODO: are these qwen-specific?
    if gguf_name == "token_embd.weight":
        return "model.embed_tokens.weight"
    elif gguf_name == "output.weight":
        return "lm_head.weight"
    elif gguf_name == "output_norm.weight":
        return "model.norm.weight"

    # layer-specific tensors
    if gguf_name.startswith("blk."):
        parts = gguf_name.split(".")
        layer_num = parts[1]
        component = ".".join(parts[2:])

        component_map = {
            "attn_norm.weight": "input_layernorm.weight",
            "attn_k.weight": "self_attn.k_proj.weight",
            "attn_k.bias": "self_attn.k_proj.bias",
            "attn_q.weight": "self_attn.q_proj.weight",
            "attn_q.bias": "self_attn.q_proj.bias",
            "attn_v.weight": "self_attn.v_proj.weight",
            "attn_v.bias": "self_attn.v_proj.bias",
            "attn_output.weight": "self_attn.o_proj.weight",
            "ffn_norm.weight": "post_attention_layernorm.weight",
            "ffn_gate.weight": "mlp.gate_proj.weight",
            "ffn_up.weight": "mlp.up_proj.weight",
            "ffn_down.weight": "mlp.down_proj.weight",
        }

        if component in component_map:
            return f"model.layers.{layer_num}.{component_map[component]}"

    print(f"warning: no mapping found for GGUF tensor: {gguf_name}")
    return gguf_name
