#!/usr/bin/env bash
# Generate a FournosJob YAML from a recipe or a `vllm serve` / `sglang serve` command.
#
# Usage:
#   ./gen-fournos-job.sh --from-serve 'vllm serve google/gemma-4-26B-A4B-it \
#       --enable-expert-parallel --tensor-parallel-size 8 --language-model-only' \
#       -o gemma.yaml
#
#   ./gen-fournos-job.sh --scenario low-latency --from-serve 'sglang serve \
#       --model-path google/gemma-4-26B-A4B-it --mem-fraction-static 0.85 \
#       --host 0.0.0.0 --port 30000' -o
#
#   ./gen-fournos-job.sh --recipe recipes/gemma-26b.env -o gemma.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Generate a FournosJob YAML for rhaiis recipe runs.

Required (one of):
  --from-serve 'CMD'      Parse `vllm serve MODEL ...` or `sglang serve --model-path ...`
  --model HF_ID           HuggingFace model id
  --recipe FILE           Bash env recipe (MODEL_ID, ENGINE_ARGS, …)

Optional:
  --engine NAME           vllm | sglang (auto-detected from --from-serve)
  --scenario NAME         low-latency | balanced | throughput
                          Tags tests.rhaiis.version (e.g. …-latency-oriented)
  --env NAME=VALUE       Model-server environment variable (repeatable)
  --arg KEY=VALUE         Engine arg (repeatable). Replaces same key if repeated.
  --tp N                  Shorthand: tensor-parallel-size (vllm) or tp-size (sglang)
  --gpu-count N           hardware.gpuCount (default: TP from serve cmd, else 1)
  --display-name NAME     spec.displayName
  --version STRING        tests.rhaiis.version
  --image IMAGE           Engine container image
  --sha COMMIT            PULL_PULL_SHA
  --workload KEY          Workload to run (repeatable; default: profile4 profile6)
  --rates LIST            e.g. '[1,2,4,8]' applied to each workload
  --max-seconds N         per-workload max_seconds (default: 450)
  -o, --output [FILE]     Write YAML to FILE; if FILE omitted, auto-name
                          from displayName (e.g. rhaiis-g4-26b-a4b-ll.yaml)
  -h, --help

Examples:
  ./gen-fournos-job.sh --scenario low-latency --from-serve 'vllm serve google/gemma-4-26B-A4B-it \
      --enable-expert-parallel --tensor-parallel-size 8 --language-model-only' \
      -o gemma-ll.yaml

  ./gen-fournos-job.sh --scenario low-latency --from-serve 'sglang serve \
      --model-path google/gemma-4-26B-A4B-it --mem-fraction-static 0.85 \
      --host 0.0.0.0 --port 30000' -o

  ./gen-fournos-job.sh --recipe recipes/gemma-26b.env --scenario throughput -o gemma-tp.yaml
EOF
}

# Normalize aliases → canonical scenario name
normalize_scenario() {
  case "$1" in
    low-latency|latency|ll) echo "low-latency" ;;
    balanced|bal) echo "balanced" ;;
    throughput|high-throughput|ht|tp) echo "throughput" ;;
    *)
      echo "ERROR: unknown scenario '$1' (use low-latency|balanced|throughput)" >&2
      return 1
      ;;
  esac
}

scenario_short() {
  case "$1" in
    low-latency) echo "ll" ;;
    balanced) echo "bal" ;;
    throughput) echo "thr" ;;
    *) echo "x" ;;
  esac
}

# Compact HF id → short model tag (e.g. google/gemma-4-26B-A4B-it → g4-26b-a4b)
model_short() {
  local name="${1##*/}"
  local max_model="${2:-24}"
  name="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  name="${name#nvidia-}"
  name="${name#google-}"
  name="${name#meta-llama-}"
  name="${name#meta-}"
  name="${name#openai-}"
  name="${name#redhatai-}"
  name="${name#deepseek-ai-}"
  name="${name#mistralai-}"
  name="${name#qwen-}"
  name="${name%-it}"
  name="${name%-instruct}"
  name="${name%-hf}"
  name="${name//./}"
  name="${name//nemotron/ntr}"
  name="${name//lightning/ltn}"
  name="${name//gemma-/g}"
  name="${name//gemma/g}"
  name="${name//llama-/l}"
  name="${name//llama/l}"
  name="${name//qwen/q}"
  name="${name//_/-}"
  while [[ "$name" == *--* ]]; do name="${name//--/-}"; done
  name="${name#-}"
  name="${name%-}"
  if [[ ${#name} -gt $max_model ]]; then
    name="${name:0:$max_model}"
    name="${name%-}"
  fi
  printf '%s' "$name"
}

# Apply scenario tag to tests.rhaiis.version only (unless --version was set).
apply_scenario() {
  local scenario="$1"
  local tag

  case "$scenario" in
    low-latency) tag="latency-oriented" ;;
    balanced) tag="balanced" ;;
    throughput) tag="throughput-oriented" ;;
  esac

  SCENARIO="$scenario"

  if [[ -z "$CLI_VERSION" ]]; then
    if [[ "$VERSION" =~ ^.+-recipe ]]; then
      VERSION="$(sed -E 's/^(.+-recipe).*/\1-'"$tag"'/' <<<"$VERSION")"
    else
      VERSION="${VERSION_PREFIX}-recipe-${tag}"
    fi
  fi
}

# Hard cap for K8s-friendly short names (target ≤45, never >50).
NAME_MAX=45

# Set short generateName / displayName from model + scenario (unless overridden).
set_job_names() {
  local m s prefix suffix room
  if [[ "$ENGINE" == "sglang" ]]; then
    prefix="rhaiis-sgl-"
  else
    prefix="rhaiis-"
  fi
  if [[ -n "$SCENARIO" ]]; then
    s="$(scenario_short "$SCENARIO")"
  else
    s="x"
  fi
  suffix="-${s}"
  # leave room for prefix + -{scenario}[+trailing - for generateName]
  room=$((NAME_MAX - ${#prefix} - ${#suffix} - 1))
  [[ $room -lt 8 ]] && room=8
  m="$(model_short "$MODEL_ID" "$room")"

  if [[ -z "$CLI_GENERATE_NAME" ]]; then
    GENERATE_NAME="${prefix}${m}${suffix}-"
    if [[ ${#GENERATE_NAME} -gt $NAME_MAX ]]; then
      GENERATE_NAME="${GENERATE_NAME:0:$((NAME_MAX - 1))}-"
    fi
  fi
  if [[ -z "$CLI_DISPLAY" ]]; then
    DISPLAY_NAME="${prefix}${m}${suffix}"
    if [[ ${#DISPLAY_NAME} -gt $NAME_MAX ]]; then
      DISPLAY_NAME="${DISPLAY_NAME:0:$NAME_MAX}"
      DISPLAY_NAME="${DISPLAY_NAME%-}"
    fi
  fi
}

# Keys that belong to the serve CLI / KServe wiring, not engine args.
is_skipped_serve_arg() {
  case "$1" in
    host|port|model-path|model|served-model-name) return 0 ;;
    *) return 1 ;;
  esac
}

# Detect engine from a serve command string.
detect_engine_from_serve() {
  local cmd="$1"
  cmd="${cmd//\\$'\n'/ }"
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  if [[ "$cmd" == sglang\ serve* || "$cmd" == python*\ -m\ sglang* ]]; then
    echo "sglang"
  elif [[ "$cmd" == vllm\ serve* || "$cmd" == python*\ -m\ vllm* ]]; then
    echo "vllm"
  else
    echo ""
  fi
}

# Parse `vllm serve MODEL [flags...]` or `sglang serve --model-path MODEL [flags...]`
# into SERVE_MODEL + SERVE_ENGINE_ARGS + SERVE_TP + SERVE_ENGINE
parse_serve() {
  local cmd="$1"
  # normalize: drop line continuations / extra whitespace
  cmd="${cmd//\\$'\n'/ }"
  cmd="${cmd//$'\n'/ }"

  SERVE_ENGINE="$(detect_engine_from_serve "$cmd")"
  if [[ -z "$SERVE_ENGINE" ]]; then
    echo "ERROR: serve command must start with 'vllm serve' or 'sglang serve'" >&2
    return 1
  fi

  if [[ "$SERVE_ENGINE" == "sglang" ]]; then
    cmd="$(sed -E 's/^[[:space:]]*(sglang[[:space:]]+serve|python3?[[:space:]]+-m[[:space:]]+sglang(\.launch_server)?)[[:space:]]+//' <<<"$cmd")"
  else
    cmd="$(sed -E 's/^[[:space:]]*(vllm[[:space:]]+serve|python3?[[:space:]]+-m[[:space:]]+vllm(\.entrypoints\.openai\.api_server)?)[[:space:]]+//' <<<"$cmd")"
  fi

  SERVE_MODEL=""
  SERVE_ENGINE_ARGS=()
  SERVE_TP=""

  local -a tokens=()
  # shell-split preserving quoted tokens
  eval "tokens=( $cmd )"

  local i=0 token key val
  while [[ $i -lt ${#tokens[@]} ]]; do
    token="${tokens[$i]}"
    if [[ "$token" == --* ]]; then
      if [[ "$token" == *=* ]]; then
        key="${token%%=*}"
        key="${key#--}"
        val="${token#*=}"
      else
        key="${token#--}"
        if [[ $((i + 1)) -lt ${#tokens[@]} && "${tokens[$((i + 1))]}" != --* ]]; then
          val="${tokens[$((i + 1))]}"
          i=$((i + 1))
        else
          val="true"
        fi
      fi

      if [[ "$key" == "model-path" || "$key" == "model" ]]; then
        SERVE_MODEL="$val"
      elif is_skipped_serve_arg "$key"; then
        : # host/port etc. — forge/KServe owns these
      elif [[ "$key" == "tensor-parallel-size" || "$key" == "tp-size" || "$key" == "tp" ]]; then
        SERVE_TP="$val"
        # normalize short --tp to engine-native key
        if [[ "$key" == "tp" ]]; then
          if [[ "$SERVE_ENGINE" == "sglang" ]]; then
            SERVE_ENGINE_ARGS+=("tp-size=${val}")
          else
            SERVE_ENGINE_ARGS+=("tensor-parallel-size=${val}")
          fi
        else
          SERVE_ENGINE_ARGS+=("${key}=${val}")
        fi
      else
        SERVE_ENGINE_ARGS+=("${key}=${val}")
      fi
    elif [[ -z "$SERVE_MODEL" ]]; then
      # positional model (vLLM style)
      SERVE_MODEL="$token"
    else
      echo "WARNING: ignoring unexpected serve token: $token" >&2
    fi
    i=$((i + 1))
  done

  if [[ -z "$SERVE_MODEL" ]]; then
    echo "ERROR: could not parse model id from serve command (need positional MODEL or --model-path)" >&2
    return 1
  fi
}

apply_engine_defaults() {
  # Set image / version / generateName defaults for ENGINE when not CLI-overridden.
  case "$ENGINE" in
    sglang)
      VERSION_PREFIX="sglang-0.5.18"
      [[ -z "$CLI_IMAGE" && -z "$IMAGE_SET_BY_RECIPE" ]] && ENGINE_IMAGE="lmsysorg/sglang:v0.5.18"
      [[ -z "$CLI_VERSION" && -z "$VERSION_SET_BY_RECIPE" ]] && VERSION="sglang-0.5.18-recipe-latency-oriented"
      [[ -z "$CLI_GENERATE_NAME" && "$GENERATE_NAME" == "rhaiis-nmiriyal-recipes-vllm-test-" ]] && \
        GENERATE_NAME="rhaiis-nmiriyal-recipes-sglang-test-"
      ;;
    vllm)
      VERSION_PREFIX="vLLM-0.28.0"
      [[ -z "$CLI_IMAGE" && -z "$IMAGE_SET_BY_RECIPE" ]] && ENGINE_IMAGE="vllm/vllm-openai:v0.28.0"
      [[ -z "$CLI_VERSION" && -z "$VERSION_SET_BY_RECIPE" ]] && VERSION="vLLM-0.28.0-recipe-latency-oriented"
      ;;
    *)
      echo "ERROR: unknown engine '$ENGINE' (use vllm|sglang)" >&2
      return 1
      ;;
  esac
  return 0
}

# ── defaults ─────────────────────────────────────────────────────────
OWNER="nmiriyal"
DISPLAY_NAME="rhaiis-zeus-recipes-"
PIPELINE="forge-full"
CLUSTER="zeus"
PRIORITY="manual"
GPU_TYPE="h200"
GPU_COUNT=1
GENERATE_NAME="rhaiis-nmiriyal-recipes-vllm-test-"

ENGINE="vllm"
ENGINE_IMAGE="vllm/vllm-openai:v0.28.0"
VERSION="vLLM-0.28.0-recipe-latency-oriented"
VERSION_PREFIX="vLLM-0.28.0"
PULL_PULL_SHA="d896e57f8097d1f275300d22114b4ca0a7686e85"
SLACK_USER="U08RXCZRRNF"
SCENARIO=""

MODEL_KEY="custom"
MODEL_ID=""
WORKLOAD_KEYS=(profile4 profile6)
RATES="[1,2,4,8,16,32,64,128,256]"
MAX_SECONDS=450
RAMPUP=0
ENGINE_ARGS=()

OUTPUT=""
RECIPE=""
FROM_SERVE=""
CLI_MODEL=""
CLI_DISPLAY=""
CLI_GENERATE_NAME=""
CLI_VERSION=""
CLI_IMAGE=""
CLI_SHA=""
CLI_GPU=""
CLI_RATES=""
CLI_MAX_SECONDS=""
CLI_SCENARIO=""
CLI_ENGINE=""
CLI_TP=""
CLI_WORKLOADS=()
CLI_ENGINE_ARGS=()
CLI_SERVER_ENVS=()
SERVE_MODEL=""
SERVE_ENGINE_ARGS=()
SERVE_TP=""
SERVE_ENGINE=""
IMAGE_SET_BY_RECIPE=""
VERSION_SET_BY_RECIPE=""

set_engine_arg_in() {
  # set_engine_arg_in ARRAY_NAME KEY=VALUE
  local -n _arr=$1
  local kv="$2"
  local key="${kv%%=*}"
  local i
  for i in "${!_arr[@]}"; do
    if [[ "${_arr[$i]}" == "${key}="* ]]; then
      _arr[$i]="$kv"
      return
    fi
  done
  _arr+=("$kv")
}

yaml_quote() {
  # Numbers and bools plain; all other values (strings) double-quoted.
  local v="$1"
  if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$v" == "true" || "$v" == "false" ]]; then
    printf '%s' "$v"
  else
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '"%s"' "$v"
  fi
}

emit_yaml() {
  local preset workload arg key val first
  local presets=(nvidia "$ENGINE" zeus "${WORKLOAD_KEYS[@]}")

  if [[ -n "$SCENARIO" ]]; then
    printf '# scenario: %s\n' "$SCENARIO"
  fi

  cat <<EOF
apiVersion: fournos.dev/v1
kind: FournosJob
metadata:
  generateName: ${GENERATE_NAME}
spec:
  owner: ${OWNER}
  displayName: ${DISPLAY_NAME}
  pipeline: ${PIPELINE}
  exclusive: false
  cluster: ${CLUSTER}
  priority: ${PRIORITY}
  hardware:
    gpuType: ${GPU_TYPE}
    gpuCount: ${GPU_COUNT}
  secretRefs:
  - psap-forge-dashboard-s3
  - psap-forge-notifications
  executionEngine:
    forge:
      project: rhaiis
      args:
EOF

  for preset in "${presets[@]}"; do
    printf '        - %s\n' "$preset"
  done

  cat <<EOF
      configOverrides:
        tests.rhaiis.run_benchmark: true
        tests.rhaiis.slack_user: $(yaml_quote "$SLACK_USER")
        tests.rhaiis.slack_notify_always: true
        caliper.postprocess.csv_dashboard.enabled: true
        rhaiis.profiler.enabled: true
        rhaiis.agent_analysis.enabled: false
        rhaiis.deploy.image_pull_secrets: ["npalaska-image-pull"]

        benchmarks.guidellm.fs_group: 0
        tests.rhaiis.warmup: true

        rhaiis.engines.${ENGINE}.images.nvidia: $(yaml_quote "$ENGINE_IMAGE")
        tests.rhaiis.version: $(yaml_quote "$VERSION")

        tests.rhaiis.model_key: ${MODEL_KEY}
        rhaiis.engine: ${ENGINE}
        models.custom.hf_model_id: $(yaml_quote "$MODEL_ID")
EOF

  for arg in "${ENGINE_ARGS[@]}"; do
    key="${arg%%=*}"
    val="${arg#*=}"
    printf '        rhaiis.engines.%s.args.%s: %s\n' "$ENGINE" "$key" "$(yaml_quote "$val")"
  done

  for arg in "${CLI_SERVER_ENVS[@]}"; do
    key="${arg%%=*}"
    val="${arg#*=}"
    # Always quote env values: Kubernetes environment values are strings.
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    printf '        rhaiis.env_vars.%s: "%s"\n' "$key" "$val"
  done

  printf '\n'
  printf '        tests.rhaiis.workload_keys: ['
  first=1
  for workload in "${WORKLOAD_KEYS[@]}"; do
    [[ $first -eq 1 ]] && first=0 || printf ','
    printf '"%s"' "$workload"
  done
  printf ']\n'

  for workload in "${WORKLOAD_KEYS[@]}"; do
    cat <<EOF
        workloads.${workload}.rates: ${RATES}
        workloads.${workload}.max_seconds: ${MAX_SECONDS}
        workloads.${workload}.rampup: ${RAMPUP}
EOF
  done

  cat <<EOF
  env:
    PULL_PULL_SHA: $(yaml_quote "$PULL_PULL_SHA")
EOF
}

# ── parse CLI (collect; apply after recipe) ──────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --recipe) RECIPE="$2"; shift 2 ;;
    --from-serve) FROM_SERVE="$2"; shift 2 ;;
    --model) CLI_MODEL="$2"; shift 2 ;;
    --engine) CLI_ENGINE="$2"; shift 2 ;;
    --env) CLI_SERVER_ENVS+=("$2"); shift 2 ;;
    --arg) CLI_ENGINE_ARGS+=("$2"); shift 2 ;;
    --tp) CLI_TP="$2"; shift 2 ;;
    --gpu-count) CLI_GPU="$2"; shift 2 ;;
    --display-name) CLI_DISPLAY="$2"; shift 2 ;;
    --generate-name) CLI_GENERATE_NAME="$2"; shift 2 ;;
    --version) CLI_VERSION="$2"; shift 2 ;;
    --image) CLI_IMAGE="$2"; shift 2 ;;
    --sha) CLI_SHA="$2"; shift 2 ;;
    --workload) CLI_WORKLOADS+=("$2"); shift 2 ;;
    --rates) CLI_RATES="$2"; shift 2 ;;
    --max-seconds) CLI_MAX_SECONDS="$2"; shift 2 ;;
    --scenario) CLI_SCENARIO="$2"; shift 2 ;;
    -o|--output)
      if [[ -n "${2:-}" && "$2" != -* ]]; then
        OUTPUT="$2"
        shift 2
      else
        OUTPUT="AUTO"
        shift 1
      fi
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# ── load recipe as base ──────────────────────────────────────────────
if [[ -n "$RECIPE" ]]; then
  if [[ ! -f "$RECIPE" && -f "$SCRIPT_DIR/$RECIPE" ]]; then
    RECIPE="$SCRIPT_DIR/$RECIPE"
  fi
  if [[ ! -f "$RECIPE" ]]; then
    echo "Recipe not found: $RECIPE" >&2
    exit 1
  fi
  # Capture pre-source image/version so we know if recipe set them
  _pre_image="${ENGINE_IMAGE:-}"
  _pre_version="${VERSION:-}"
  # shellcheck disable=SC1090
  source "$RECIPE"
  # Back-compat: recipes may set VLLM_ARGS / VLLM_IMAGE
  if [[ ${#ENGINE_ARGS[@]} -eq 0 ]] && declare -p VLLM_ARGS &>/dev/null && [[ ${#VLLM_ARGS[@]} -gt 0 ]]; then
    ENGINE_ARGS=("${VLLM_ARGS[@]}")
  fi
  if [[ -n "${VLLM_IMAGE:-}" && "$ENGINE_IMAGE" == "vllm/vllm-openai:v0.28.0" ]]; then
    ENGINE_IMAGE="$VLLM_IMAGE"
  fi
  [[ "$ENGINE_IMAGE" != "$_pre_image" ]] && IMAGE_SET_BY_RECIPE=1
  [[ "$VERSION" != "$_pre_version" ]] && VERSION_SET_BY_RECIPE=1
fi

# ── parse serve command (overrides recipe model/args) ───────────────
if [[ -n "$FROM_SERVE" ]]; then
  parse_serve "$FROM_SERVE"
  ENGINE="$SERVE_ENGINE"
  MODEL_ID="$SERVE_MODEL"
  ENGINE_ARGS=()
  for arg in "${SERVE_ENGINE_ARGS[@]+"${SERVE_ENGINE_ARGS[@]}"}"; do
    set_engine_arg_in ENGINE_ARGS "$arg"
  done
  if [[ -z "$CLI_GPU" && -n "$SERVE_TP" ]]; then
    GPU_COUNT="$SERVE_TP"
  fi
fi

# Explicit --engine overrides detection / recipe
[[ -n "$CLI_ENGINE" ]] && ENGINE="$CLI_ENGINE"

apply_engine_defaults

# ── CLI overrides recipe / serve ─────────────────────────────────────
[[ -n "$CLI_MODEL" ]] && MODEL_ID="$CLI_MODEL"
[[ -n "$CLI_DISPLAY" ]] && DISPLAY_NAME="$CLI_DISPLAY"
[[ -n "$CLI_GENERATE_NAME" ]] && GENERATE_NAME="$CLI_GENERATE_NAME"
[[ -n "$CLI_VERSION" ]] && VERSION="$CLI_VERSION"
[[ -n "$CLI_IMAGE" ]] && ENGINE_IMAGE="$CLI_IMAGE"
[[ -n "$CLI_SHA" ]] && PULL_PULL_SHA="$CLI_SHA"
[[ -n "$CLI_GPU" ]] && GPU_COUNT="$CLI_GPU"
[[ -n "$CLI_RATES" ]] && RATES="$CLI_RATES"
[[ -n "$CLI_MAX_SECONDS" ]] && MAX_SECONDS="$CLI_MAX_SECONDS"

if [[ ${#CLI_WORKLOADS[@]} -gt 0 ]]; then
  WORKLOAD_KEYS=("${CLI_WORKLOADS[@]}")
fi

for arg in "${CLI_ENGINE_ARGS[@]+"${CLI_ENGINE_ARGS[@]}"}"; do
  set_engine_arg_in ENGINE_ARGS "$arg"
done

# --tp after engine is known
if [[ -n "$CLI_TP" ]]; then
  if [[ "$ENGINE" == "sglang" ]]; then
    set_engine_arg_in ENGINE_ARGS "tp-size=$CLI_TP"
  else
    set_engine_arg_in ENGINE_ARGS "tensor-parallel-size=$CLI_TP"
  fi
  [[ -z "$CLI_GPU" ]] && GPU_COUNT="$CLI_TP"
fi

# Scenario from CLI or recipe (SCENARIO=...)
if [[ -n "$CLI_SCENARIO" ]]; then
  apply_scenario "$(normalize_scenario "$CLI_SCENARIO")"
elif [[ -n "${SCENARIO:-}" ]]; then
  apply_scenario "$(normalize_scenario "$SCENARIO")"
fi

if [[ -z "$MODEL_ID" ]]; then
  echo "ERROR: MODEL_ID required (--from-serve, --model, or MODEL_ID in recipe)" >&2
  exit 1
fi

for server_env in "${CLI_SERVER_ENVS[@]}"; do
  if [[ ! "$server_env" =~ ^[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./:-]+$ ]]; then
    echo "ERROR: --env requires literal NAME=value" >&2
    exit 1
  fi
done

set_job_names

# Default TP arg if none present
has_tp=0
for arg in "${ENGINE_ARGS[@]+"${ENGINE_ARGS[@]}"}"; do
  key="${arg%%=*}"
  if [[ "$key" == "tensor-parallel-size" || "$key" == "tp-size" ]]; then
    has_tp=1
    break
  fi
done
if [[ $has_tp -eq 0 ]]; then
  if [[ "$ENGINE" == "sglang" ]]; then
    set_engine_arg_in ENGINE_ARGS "tp-size=1"
  else
    set_engine_arg_in ENGINE_ARGS "tensor-parallel-size=1"
  fi
fi

if [[ "$OUTPUT" == "AUTO" ]]; then
  OUTPUT="${DISPLAY_NAME}.yaml"
fi

if [[ -n "$OUTPUT" ]]; then
  emit_yaml >"$OUTPUT"
  echo "Wrote $OUTPUT" >&2
else
  emit_yaml
fi
