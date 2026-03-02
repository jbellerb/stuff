import json
from dataclasses import dataclass
from pathlib import Path

from anemll.ane_converter.qwen2_5_converter import Qwen25Converter
from anemll.models import qwen2_5_model
from anemll.utils.combine_models import combine_monolithic
from anemll.utils.compile_models import compile_part
from huggingface_hub import snapshot_download

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

    lut_embeddings: tuple[int, int] | None = None
    lut_ffn: tuple[int, int] | None = None
    lut_lmhead: tuple[int, int] | None = None

    def convert(self, model_path: Path) -> Path:
        (OUTPUT_DIR / self.prefix).mkdir(parents=True, exist_ok=True)
        prefix = str(OUTPUT_DIR / self.prefix)

        lut_bits, per_channel = self.lut_ffn if self.lut_ffn else (None, 8)
        lut_embeddings_bits, lut_embeddings_per_channel = (
            self.lut_embeddings if self.lut_embeddings else (None, 8)
        )
        lut_lmhead_bits, lut_lmhead_per_channel = (
            self.lut_lmhead if self.lut_lmhead else (None, 8)
        )

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

        converter = Qwen25Converter(
            model=model,
            context_length=self.context_length,
            batch_size=self.batch_size,
            lut_bits=lut_bits,
            per_channel=per_channel,
            num_chunks=1,
            argmax_in_model=False,
            lut_embeddings_bits=lut_embeddings_bits,
            lut_embeddings_per_channel=lut_embeddings_per_channel,
            lut_lmhead_bits=lut_lmhead_bits,
            lut_lmhead_per_channel=lut_lmhead_per_channel,
        )

        lut_suffix = f"_lut{lut_bits}" if lut_bits else ""
        mlmodel = converter.convert(part="monolithic")
        mlmodel = mlmodel[0] if isinstance(mlmodel, list) else mlmodel
        mlmodel.save(f"{prefix}_monolithic{lut_suffix}.mlpackage")
        mlmodel_prefill = converter.convert(part="monolithic_prefill")
        mlmodel_prefill = (
            mlmodel_prefill[0] if isinstance(mlmodel_prefill, list) else mlmodel_prefill
        )
        mlmodel_prefill.save(f"{prefix}_monolithic_prefill{lut_suffix}.mlpackage")

        combined = combine_monolithic(
            lut_bits=lut_bits,
            prefix=self.prefix,
            input_dir=prefix,
            output_dir=prefix,
            dedup_weights=True,
        )
        if not combined:
            raise Exception("failed to combine model packages")

        compiled = compile_part(
            part="monolithic",
            lut_bits=lut_bits,
            prefix=self.prefix,
            target_dir=prefix,
            force_mlprogram=False,
        )
        if not compiled:
            raise Exception("failed to compile monolithic model package")

        return OUTPUT_DIR / f"{self.prefix}_monolithic_full{lut_suffix}.mlmodelc"
