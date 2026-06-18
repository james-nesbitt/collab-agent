# Local-model acceleration (deferred)

**Status:** TODO / not started. The VM stays `e2-standard-4` (CPU) until this is taken up.

## What runs locally today

`manager.sh setup`/`tune` configure three on-device housekeeping models. They are **local
ONNX** models (transformers.js + onnxruntime-node), not Ollama, and auto-download from the
Hugging Face Hub on first use:

| role | model | set by |
| --- | --- | --- |
| `providers.tinyModel` | `lfm2-350m` | `setup` |
| `providers.memoryModel` (mnemopi) | `qwen3-1.7b` | `tune --memory` |
| `providers.autoThinkingModel` | `qwen3-1.7b` | `tune --thinking` |

They run fine on CPU at these sizes. The primary chat/plan `modelRoles`
(`claude-sonnet-4-6` / `claude-opus-4-8` / `claude-haiku-4-5`) are remote Anthropic models
and do no local compute.

## What is deferred

Running **heavier local inference on a GPU instance** instead of CPU ONNX housekeeping
models — e.g.:

- larger ONNX tiny-model variants (bigger memory/thinking/title models) for higher quality;
- local (non-cloud) Ollama models for some `modelRoles`, to reduce remote API dependence.

## Why it is blocked today

- The bundled `onnxruntime-node` is the **CPU build**; GPU execution providers are not
  wired up.
- omp's worker forces GPU/WebGPU execution back to CPU, so even a GPU-capable runtime would
  not be used by the current code path.
- No Ollama daemon is installed on the VM, and `OLLAMA_API_KEY` is unset; `:cloud` model IDs
  need a local daemon signed in to Ollama cloud.

## GCP options to revisit

| Option | Notes |
| --- | --- |
| `g2-standard-4` + 1× **L4** | current-gen inference GPU; best price/perf for this size |
| `n1-standard-4` + 1× **T4** | cheaper, older; fine for small models |

Switching means setting `MACHINE_TYPE` (and an accelerator + GPU driver install in
`bootstrap`) in `administrator.sh`, plus a GPU-enabled onnxruntime / Ollama install and
unsetting omp's CPU fallback. None of that is done here.
