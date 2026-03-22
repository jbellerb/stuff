import json
from dataclasses import dataclass
from pathlib import Path

import coremltools as ct
import coremltools.optimize as cto
from anemll.models import qwen2_5_model
from huggingface_hub import snapshot_download

from predictions_coreml_models.models import qwen2

OUTPUT_DIR = Path("converted_models")


def download_model(
    hf_repo: str,
    revision: str | None = None,
    allow_patterns: list[str] | str | None = None,
) -> Path:
    model_path = Path(hf_repo)
    if not model_path.exists():
        model_path = Path(
            snapshot_download(
                hf_repo,
                revision=revision,
                allow_patterns=allow_patterns,
            )
        )

    return model_path


def linear_quantize_weights(
    mlmodel: ct.models.MLModel,
    overrides: dict[str, tuple[int, int]] | None = None,
) -> ct.models.MLModel:
    # int8 per_block with block_size=32 matches Q8_0 block quantization,
    # minimizing loss when the source weights were Q8_0
    global_config = cto.coreml.OpLinearQuantizerConfig(
        dtype="int8",
        granularity="per_block",
        block_size=32,
    )

    # op_name_configs requires exact MIL op names, so walk the program to find
    # ops whose names contain each override pattern.
    op_name_configs: dict[str, cto.coreml.OpLinearQuantizerConfig] = {}
    if overrides:
        prog = mlmodel._mil_program
        if prog:
            for op in prog.functions["main"].operations:
                op_name = op.name or ""
                for pattern, (dtype, block_size) in overrides.items():
                    if pattern in op_name:
                        op_name_configs[op_name] = cto.coreml.OpLinearQuantizerConfig(
                            dtype=dtype,
                            granularity="per_block",
                            block_size=block_size,
                        )
                        break

    op_config = cto.coreml.OptimizationConfig(
        global_config=global_config,
        op_name_configs=op_name_configs if op_name_configs else None,
    )
    return cto.coreml.linear_quantize_weights(mlmodel, op_config)


def combine_models(
    output_path: Path, models: dict[str, Path], default_model: str
) -> None:
    desc = ct.utils.MultiFunctionDescriptor()
    for name, path in models.items():
        desc.add_function(str(path), "main", name)
    desc.default_function_name = default_model
    ct.utils.save_multifunction(desc, str(output_path))


@dataclass
class Qwen25ConversionPipeline:
    prefix: str
    architecture: str
    format: str

    hidden_size: int
    intermediate_size: int
    num_attention_heads: int
    num_hidden_layers: int
    num_key_value_heads: int
    vocab_size: int

    context_length: int
    batch_size: int

    quantize: bool = False
    quantize_overrides: dict[str, tuple[str, int]] | None = (
        None  # pattern -> (dtype, block_size)
    )

    def convert(self, model_path: Path) -> Path:
        (OUTPUT_DIR / self.prefix).mkdir(parents=True, exist_ok=True)
        prefix = str(OUTPUT_DIR / self.prefix)

        config = qwen2_5_model.Qwen25Config(
            architectures=["Qwen2ForCausalLM"],
            model_type="qwen2",
            hidden_size=self.hidden_size,
            intermediate_size=self.intermediate_size,
            num_attention_heads=self.num_attention_heads,
            num_hidden_layers=self.num_hidden_layers,
            num_key_value_heads=self.num_key_value_heads,
            vocab_size=self.vocab_size,
            context_length=self.context_length,
            state_length=max(qwen2_5_model.STATE_LENGTH, self.context_length),
        )

        if self.format == "gguf":
            from predictions_coreml_models.gguf import GGUFModel

            gguf_files = list(model_path.glob("*.gguf"))
            if not gguf_files:
                raise FileNotFoundError(f"no GGUF files found in {model_path}")

            gguf = GGUFModel(gguf_files[0])
            with open(
                OUTPUT_DIR / self.prefix / "vocab.json", "w", encoding="utf-8"
            ) as f:
                json.dump(gguf.vocab, f, ensure_ascii=False)
            if (merges := gguf.merges) is not None:
                with open(
                    OUTPUT_DIR / self.prefix / "merges.txt", "w", encoding="utf-8"
                ) as f:
                    f.write("\n".join(merges))

            state_dict = gguf.load_weights()
            assert self.vocab_size == state_dict["model.embed_tokens.weight"].shape[0]

            # split lm_head into 16 chunks for CoreML mode
            lm_head_weight = state_dict.pop("lm_head.weight")
            vocab_size = lm_head_weight.shape[0]
            chunk_size = vocab_size // 16
            remainder = vocab_size % 16

            start_idx = 0
            for i in range(16):
                # distribute remainder across first chunks
                current_chunk_size = chunk_size + (1 if i < remainder else 0)
                end_idx = start_idx + current_chunk_size
                chunk = lm_head_weight[start_idx:end_idx]
                # reshape to Conv2d format: [out, in, 1, 1]
                chunk = chunk.unsqueeze(-1).unsqueeze(-1)
                state_dict[f"lm_head16_{i + 1}.weight"] = chunk
                start_idx = end_idx

            model = qwen2_5_model.Qwen25ForCausalLM(config, enable_coreml=True)
            result = model.load_state_dict(state_dict, strict=False)
            if result.missing_keys:
                print(f"warning: missing keys: {result.missing_keys}")
            if result.unexpected_keys:
                print(f"warning: unexpected keys: {result.unexpected_keys}")
        else:
            model = qwen2_5_model.Qwen25ForCausalLM(config, enable_coreml=True)
            # TODO: handle copying hugging face style tokenizer vocab and merges
            model.load_pretrained_weights(str(model_path))

        model.eval()
        for param in model.parameters():
            param.requires_grad = False

        suffix = "_int8" if self.quantize else ""
        infer_path = Path(f"{prefix}_infer{suffix}.mlpackage")
        prefill_path = Path(f"{prefix}_prefill{suffix}.mlpackage")
        combined_path = Path(f"{prefix}_full{suffix}.mlpackage")

        print("Converting infer model...")
        mlmodel_infer = qwen2.convert_infer(model, self.context_length)
        if self.quantize:
            mlmodel_infer = linear_quantize_weights(
                mlmodel_infer, self.quantize_overrides
            )
        mlmodel_infer.save(str(infer_path))

        print("Converting prefill model...")
        mlmodel_prefill = qwen2.convert_prefill(
            model, self.context_length, self.batch_size
        )
        if self.quantize:
            mlmodel_prefill = linear_quantize_weights(
                mlmodel_prefill, self.quantize_overrides
            )
        mlmodel_prefill.save(str(prefill_path))

        print("Combining models...")
        combine_models(
            combined_path,
            {"infer": infer_path, "prefill": prefill_path},
            default_model="infer",
        )

        return combined_path
