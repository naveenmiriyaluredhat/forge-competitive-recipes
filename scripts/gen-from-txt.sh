#!/usr/bin/env bash
# Read plain-text recipe(s) (scenario + vllm/sglang serve) and generate FournosJob YAML(s).
# Optionally launch them with oc create.
#
# Usage:
#   ./gen-from-txt.sh recipes/gemma-ll.txt
#   ./gen-from-txt.sh recipes/*.txt
#   ./gen-from-txt.sh recipes/a.txt recipes/b.txt --launch
#   ./gen-from-txt.sh recipes/gemma-ll.txt -o              # auto-named yaml
#   ./gen-from-txt.sh recipes/gemma-ll.txt --launch -n psap-automation
#
# Recipe file format:
#   scenario: low-latency          # or balanced / throughput  (required)
#   # optional: sha / image / version / gpu-count
#   vllm serve org/model \
#     --tensor-parallel-size 8 \
#     --language-model-only
#
#   # or SGLang:
#   sglang serve --model-path org/model \
#     --mem-fraction-static 0.85 \
#     --tp-size 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/gen-fournos-job.sh"

NAMESPACE="psap-automation"
LAUNCH=0
OC_BIN="${OC_BIN:-oc}"

usage() {
  cat <<'EOF'
Generate FournosJob YAML(s) from text recipe file(s).

  ./gen-from-txt.sh RECIPE.txt [RECIPE2.txt ...] [options]

Options:
  -l, --launch            oc create each generated job (default ns: psap-automation)
  -n, --namespace NS      Namespace for --launch (default: psap-automation)
  -o, --output [FILE]     Output path (auto-name if FILE omitted).
                          With multiple recipes, FILE is ignored — each is auto-named.
  -h, --help

Recipe file:
  scenario: low-latency|balanced|throughput
  vllm serve MODEL --flag ...
  # or:
  sglang serve --model-path MODEL --flag ...

Optional recipe headers:
  sha: <commit>
  image: <engine-image>
  version: <tests.rhaiis.version>
  gpu-count: <N>

Examples:
  ./gen-from-txt.sh recipes/gemma-ll.txt recipes/nemotron-bal.txt
  ./gen-from-txt.sh recipes/gemma-sglang-ll.txt
  ./gen-from-txt.sh recipes/*.txt --launch
EOF
}

RECIPE_FILES=()
PASSTHRU=()
EXPLICIT_OUTPUT=""
HAS_OUTPUT_FLAG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -l|--launch) LAUNCH=1; shift ;;
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -o|--output)
      HAS_OUTPUT_FLAG=1
      if [[ -n "${2:-}" && "$2" != -* && "$2" != *.txt ]]; then
        EXPLICIT_OUTPUT="$2"
        shift 2
      else
        EXPLICIT_OUTPUT=""
        shift 1
      fi
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do RECIPE_FILES+=("$1"); shift; done
      break
      ;;
    -*)
      # forward unknown flags to gen-fournos-job.sh
      PASSTHRU+=("$1")
      if [[ -n "${2:-}" && "$2" != -* && "$2" != *.txt ]]; then
        PASSTHRU+=("$2")
        shift 2
      else
        shift 1
      fi
      ;;
    *)
      RECIPE_FILES+=("$1")
      shift
      ;;
  esac
done

if [[ ${#RECIPE_FILES[@]} -eq 0 ]]; then
  usage >&2
  exit 1
fi

parse_recipe() {
  local recipe_txt="$1"
  SCENARIO=""
  SHA=""
  IMAGE=""
  VERSION=""
  GPU_COUNT=""
  SERVE_LINES=()
  local IN_SERVE=0 line trimmed key

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"

    if [[ $IN_SERVE -eq 0 ]]; then
      [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
    fi

    key="$(echo "$trimmed" | sed -E 's/^([^:]+:).*/\1/' | tr '[:upper:]' '[:lower:]')"
    if [[ $IN_SERVE -eq 0 && "$key" == scenario:* ]]; then
      SCENARIO="$(echo "$trimmed" | sed -E 's/^[Ss]cenario:[[:space:]]*//')"
      continue
    fi
    if [[ $IN_SERVE -eq 0 && "$key" == sha:* ]]; then
      SHA="$(echo "$trimmed" | sed -E 's/^[Ss]ha:[[:space:]]*//')"
      continue
    fi
    if [[ $IN_SERVE -eq 0 && "$key" == image:* ]]; then
      IMAGE="$(echo "$trimmed" | sed -E 's/^[Ii]mage:[[:space:]]*//')"
      continue
    fi
    if [[ $IN_SERVE -eq 0 && "$key" == version:* ]]; then
      VERSION="$(echo "$trimmed" | sed -E 's/^[Vv]ersion:[[:space:]]*//')"
      continue
    fi
    if [[ $IN_SERVE -eq 0 && "$key" == gpu-count:* ]]; then
      GPU_COUNT="$(echo "$trimmed" | sed -E 's/^[Gg]pu-[Cc]ount:[[:space:]]*//')"
      continue
    fi

    if [[ "$trimmed" == vllm\ serve* || "$trimmed" == python*\ -m\ vllm* \
       || "$trimmed" == sglang\ serve* || "$trimmed" == python*\ -m\ sglang* ]]; then
      IN_SERVE=1
    fi
    if [[ $IN_SERVE -eq 1 ]]; then
      SERVE_LINES+=("$line")
    fi
  done <"$recipe_txt"

  if [[ -z "$SCENARIO" ]]; then
    echo "ERROR: $recipe_txt: missing 'scenario: ...'" >&2
    return 1
  fi
  if [[ ${#SERVE_LINES[@]} -eq 0 ]]; then
    echo "ERROR: $recipe_txt: missing 'vllm serve ...' or 'sglang serve ...' command" >&2
    return 1
  fi

  SERVE_CMD=""
  local sline
  for sline in "${SERVE_LINES[@]}"; do
    sline="${sline%"${sline##*[![:space:]]}"}"
    if [[ "$sline" == *\\ ]]; then
      sline="${sline%\\}"
      sline="${sline%"${sline##*[![:space:]]}"}"
    fi
    SERVE_CMD+="${sline} "
  done
  SERVE_CMD="${SERVE_CMD%"${SERVE_CMD##*[![:space:]]}"}"
}

launch_job() {
  local yaml="$1"
  echo "Launching $yaml → namespace/$NAMESPACE" >&2
  "$OC_BIN" create -f "$yaml" -n "$NAMESPACE"
}

process_one() {
  local recipe_txt="$1"
  local multi="$2"

  if [[ ! -f "$recipe_txt" ]]; then
    echo "ERROR: recipe file not found: $recipe_txt" >&2
    return 1
  fi

  parse_recipe "$recipe_txt"

  local ARGS=(--scenario "$SCENARIO" --from-serve "$SERVE_CMD")
  [[ -n "$SHA" ]] && ARGS+=(--sha "$SHA")
  [[ -n "$IMAGE" ]] && ARGS+=(--image "$IMAGE")
  [[ -n "$VERSION" ]] && ARGS+=(--version "$VERSION")
  [[ -n "$GPU_COUNT" ]] && ARGS+=(--gpu-count "$GPU_COUNT")
  ARGS+=("${PASSTHRU[@]+"${PASSTHRU[@]}"}")

  # Always write a file (needed for launch); auto-name unless single explicit -o FILE
  if [[ "$multi" -eq 0 && -n "$EXPLICIT_OUTPUT" ]]; then
    ARGS+=(-o "$EXPLICIT_OUTPUT")
  else
    ARGS+=(-o)
  fi

  local err tmp_out
  err="$(mktemp)"
  # stdout is the yaml only when -o not used; with -o, yaml goes to file and "Wrote" on stderr
  if ! "$GEN" "${ARGS[@]}" 2>"$err"; then
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
  cat "$err" >&2
  tmp_out="$(sed -n 's/^Wrote //p' "$err" | tail -n1)"
  rm -f "$err"

  if [[ -z "$tmp_out" || ! -f "$tmp_out" ]]; then
    echo "ERROR: could not determine output YAML for $recipe_txt" >&2
    return 1
  fi

  echo "Generated $tmp_out (from $recipe_txt)" >&2

  if [[ $LAUNCH -eq 1 ]]; then
    launch_job "$tmp_out"
  fi
}

MULTI=0
[[ ${#RECIPE_FILES[@]} -gt 1 ]] && MULTI=1
if [[ $MULTI -eq 1 && -n "$EXPLICIT_OUTPUT" ]]; then
  echo "NOTE: multiple recipes — ignoring explicit -o $EXPLICIT_OUTPUT; auto-naming each" >&2
  EXPLICIT_OUTPUT=""
fi

FAIL=0
for f in "${RECIPE_FILES[@]}"; do
  if ! process_one "$f" "$MULTI"; then
    FAIL=1
  fi
done

exit "$FAIL"
