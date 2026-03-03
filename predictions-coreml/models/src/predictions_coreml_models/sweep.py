import sys

from predictions_coreml_models.convert import Qwen25ConversionPipeline, download_model

SWEEP_MODEL_NAME_HF = "sweepai/sweep-next-edit-1.5B"

sweep_pipeline = Qwen25ConversionPipeline(
    prefix="sweep",
    architecture="qwen2",
    format="gguf",
    hidden_size=1536,
    intermediate_size=8960,
    num_attention_heads=12,
    num_hidden_layers=28,
    num_key_value_heads=2,
    vocab_size=43839,
    context_length=8192,
    batch_size=64,
    lut_embeddings=None,
    lut_ffn=(8, 8),
    lut_lmhead=(8, 8),
)


def main():
    try:
        model_path = download_model(SWEEP_MODEL_NAME_HF, allow_patterns=["*.gguf"])

        output = sweep_pipeline.convert(model_path)
        print(f"converted model: {output}")
    except KeyboardInterrupt:
        sys.exit(1)


if __name__ == "__main__":
    main()
