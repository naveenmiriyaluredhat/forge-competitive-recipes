# Forge competitive recipes

Generate FournosJobs for vLLM and SGLang recipes, select benchmark profiles, and submit batches using `oc create`. Generation is the default; cluster submission requires `--launch` or `--resume`.

## Setup

Requires Bash, Python 3.9+, Git, and PyYAML. Launching also requires `oc` logged into the intended OpenShift cluster, permission to create FournosJobs, and the Forge CRD installed.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
./scripts/run.sh --help
```

Run the commands below from this repository. Relative configuration and recipe paths resolve from the repository root.

## Select recipes by family, runtime, model, or scenario

```bash
# Inspect the selection first; no SHA or cluster access needed.
./scripts/run.sh --family gemma --list
./scripts/run.sh --family nemotron --runtime sglang --list

# Generate only vLLM Gemma low-latency recipes.
./scripts/run.sh --family gemma --runtime vllm --scenario low-latency \
  --sha <forge-commit-sha>

# Narrow to a model variant (case-insensitive model-ID substring).
./scripts/run.sh --family gemma --model gemma-4-31b-it-fp8 \
  --sha <forge-commit-sha>

# Select exact recipes; --recipe can be repeated.
./scripts/run.sh \
  --recipe recipes/vllm/gemma/gemma-4-26b-a4b-it/h200-8gpu/low-latency.txt \
  --sha <forge-commit-sha>
```

Supported families: `gemma`, `nemotron`, `qwen`, `laguna`, `glm`, `muse`. Runtime choices are `vllm` and `sglang`; scenarios are `low-latency`, `balanced`, and `throughput`. Omit a filter to include all values. Filters combine; no matches is an error. Family and runtime are inferred from recipe contents. Add new family mappings in `scripts/run.py` when introducing a new family.

**An unfiltered invocation generates all text recipes, including preserved variants.** Use `--list` or exact `--recipe` selection before large launches.

## Launch jobs

```bash
oc whoami
oc config current-context

./scripts/run.sh --family gemma --runtime sglang \
  --profile profiles/standard/profile4-profile6.yaml \
  --environment environments/zeus.yaml \
  --sha <forge-commit-sha> \
  --namespace psap-automation \
  --launch
```

All selected YAMLs are generated first. The launcher validates every pending job using `oc create --dry-run=server`, then submits each with:

```bash
oc create -f <job.yaml> -n psap-automation -o name
```

This records the actual resource names produced by `generateName`. Submission is sequential; Forge controls scheduling and GPU allocation. The command does not wait for benchmarks to finish. A batch is not an atomic transaction.

To submit a previously generated run:

```bash
./scripts/run.sh --resume runs/<run-id>
```

Created jobs are skipped. If a create call fails or is interrupted, the job remains `submitting`, since the server may have accepted it. Inspect the cluster using the run label:

```bash
oc get fournosjobs -n psap-automation -l recipes.forge/run-id=<lowercase-run-id>
```

Reconcile that entry in `run.yaml`: record its `resource` and set `status: created` if it exists, or set `status: generated` only after confirming it was not created. Then resume. Do not launch/resume the same run concurrently. Resume checks the recorded oc context; it never switches context automatically.

## Benchmark profiles and custom workloads

Serving scenarios describe engine tuning. Benchmark profiles independently select the workloads used to evaluate those settings.

Copy `profiles/standard/profile4-profile6.yaml` into `profiles/custom/` and edit it:

```yaml
workloads: [profile4, profile6]
rates: [1, 4, 16, 64]
max_seconds: 300
rampup: 0
warmup: true
config_overrides:
  workloads.profile4.max_seconds: 600
  workloads.profile6.rates: [1, 2, 4]
```

Then use `--profile profiles/custom/my-profile.yaml`. Each invocation selects one profile; repeat with another profile to create another independent run. `config_overrides` accepts flat Forge `workloads.*`, `benchmarks.*`, and warmup settings. It is applied after common rate/duration settings, so individual workloads can differ.

Custom workload names must be defined in the Forge revision selected by `--sha`, or fully configured using keys supported by that revision. This repository does not invent workload definitions. Server dry-run validates the CRD, not whether a benchmark configuration will execute successfully.

## Environments, SHA, and images

`environments/zeus.yaml` supplies cluster, cluster preset, namespace, GPU type, owner, and runtime-specific images. Create another environment file for another target.

- `--sha` is required, either on the CLI or in the experiment. It becomes `spec.env.PULL_PULL_SHA`.
- `--cluster` changes both the job cluster and the Forge cluster preset by default; use `--cluster-preset` if their names differ.
- `--namespace` chooses the namespace passed to `oc`.
- `--image` overrides the image for all selected jobs; use a runtime filter when overriding a runtime-specific image.
- `--version` overrides the benchmark version label. Otherwise the runner derives it from the selected image and scenario.
- GPU count follows the recipe's `gpu-count` header or tensor-parallel setting, with a default of 1. GPU type comes from the environment.

The oc context determines which API server receives jobs; `spec.cluster` is the Forge execution target. These are separate settings.

Precedence: CLI selection/settings override experiment settings. Environment images override recipe image headers; a CLI image overrides both. Profile workload settings override generator defaults. The runner always uses the explicitly selected SHA.

## Reusable experiments

`experiments/gemma-runtime-comparison.yaml` selects Gemma low-latency recipes across both runtimes:

```bash
./scripts/run.sh --experiment experiments/gemma-runtime-comparison.yaml --list
./scripts/run.sh --experiment experiments/gemma-runtime-comparison.yaml \
  --sha <forge-commit-sha> --launch
```

An experiment accepts the same configuration keys as the runner, using underscores for hyphenated keys, such as `cluster_preset`. Use `recipe: [path1, path2]` for a curated exact selection. CLI flags override experiment fields. Each invocation produces one job per selected recipe with the chosen profile.

## Directory and filename conventions

```text
recipes/<runtime>/<family>/<model-variant>/<gpu-type>-<count>gpu/<scenario>.txt
profiles/standard/<purpose>.yaml
profiles/custom/<purpose>.yaml
experiments/<comparison-purpose>.yaml
environments/<target>.yaml
scripts/
runs/<UTC-timestamp>-<unique-id>/
  run.yaml
  inputs/                  # exact recipe snapshots
  jobs/                    # resolved FournosJob YAMLs
archive/imported-jobs/     # original imported YAMLs, preserved unchanged
examples/legacy-env/       # original shell-format examples
```

Use lowercase, hyphens between words, and full scenario names. Preserve model version numbers, architecture sizes, and quantization in the model directory, e.g. `gemma-4-26b-a4b-it-fp8-dynamic`. Retain dots in version numbers such as `3.5`. Runtime and family need not be repeated in the recipe filename.

Hardware folders reflect the imported recipes' tensor parallelism and the current H200 default. Verify compatibility when selecting another environment. If multiple recipes share a model, hardware, and scenario, use `<scenario>--<meaningful-variant>.txt`, such as `low-latency--prefix-caching.txt`.

Imported collisions retain their old basename as the variant suffix until reviewed. No recipes were discarded. `archive/recipe-migration.txt` maps original recipe filenames to their new locations. Existing YAMLs were archived because they can differ from the text recipes; they are not assumed to be reproducible outputs of those recipes.

Run job filenames include an ordinal, runtime, family, and scenario. `run.yaml` maps each job to its full model and source path, and captures selection, resolved environment/profile, Git revision, dirty status, submission context, and resource names. Exact generated YAMLs remain authoritative even when inputs later change. Runs are ignored by Git; keep any benchmark evidence you need in durable storage.

## Existing generators

The root `gen-from-txt.sh` and `gen-fournos-job.sh` remain compatibility entry points; maintained implementations live in `scripts/`. They support individual recipes and advanced engine arguments. Prefer `scripts/run.sh` for tracked batches, environment/profile resolution, and preflight validation.

Recipe files are trusted local inputs: the legacy generator evaluates serve arguments and sources `.env` recipes. Review recipes before running them.

## Verification

```bash
python3 -m unittest discover -s tests -v
bash -n scripts/*.sh
```

Tests use a fake oc client; they do not create cluster jobs.

Generated jobs follow the YAML layout in `archive/imported-jobs/rhaiis-g4-26b-a4b-bal.yaml`: scenario comment, indented Forge arguments, inline workload/rate lists, quoted configuration strings, and separated setting groups. Selected profile values and run-tracking labels are retained.
