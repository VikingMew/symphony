#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

annotation() {
  local level=$1 message=$2
  message=${message//%/%25}
  message=${message//$'\r'/%0D}
  message=${message//$'\n'/%0A}
  printf '::%s::%s\n' "$level" "$message"
}

fail() {
  printf 'docs-drift: %s\n' "$1" >&2
  annotation error "$1"
  exit 2
}

base= head= body=
while (($#)); do
  case "$1" in
    --base|--head|--body)
      flag=$1
      (($# >= 2)) || fail "Missing value for $flag."
      [[ -n $2 && $2 != --* ]] || fail "Missing value for $flag."
      case "$flag" in
        --base) base=$2 ;;
        --head) head=$2 ;;
        --body) body=$2 ;;
      esac
      shift 2
      ;;
    *) fail "Unknown argument; expected --base, --head, or --body." ;;
  esac
done

[[ -n $base ]] || fail "Missing required flag --base."
[[ -n $head ]] || fail "Missing required flag --head."
base=$(git rev-parse --verify --end-of-options "${base}^{commit}" 2>/dev/null) ||
  fail "Cannot resolve --base to a local commit."
head=$(git rev-parse --verify --end-of-options "${head}^{commit}" 2>/dev/null) ||
  fail "Cannot resolve --head to a local commit."

changed=$(git -c core.quotePath=false diff --name-only --diff-filter=ACDMRTUXB "$base...$head" 2>/dev/null) ||
  fail "Cannot diff --base...--head; a local merge base is required."

implementation=()
documentation=false
while IFS= read -r path; do
  # Git quotes paths containing control characters; retain that printable form.
  case "$path" in
    lib/*|config/*|\"lib/*|\"config/*)
      index=${#implementation[@]}
      while ((index > 0)) && [[ ${implementation[index-1]} > "$path" ]]; do
        implementation[index]=${implementation[index-1]}
        index=$((index - 1))
      done
      implementation[index]=$path
      ;;
    docs/*|\"docs/*|README.md|AGENTS.md) documentation=true ;;
  esac
done <<< "$changed"

if ((${#implementation[@]} == 0)); then
  annotation notice "Docs drift linkage: no implementation paths changed."
  exit 0
fi
if [[ $documentation == true ]]; then
  annotation notice "Docs drift linkage: implementation and documentation paths changed."
  exit 0
fi

reason=
if [[ -n $body ]]; then
  [[ -f $body && -r $body ]] || fail "Cannot read --body file."
  # Recognize top-level Markdown fences, including longer fences and tildes.
  reason=$(awk '
    {
      line = $0
      sub(/\r$/, "", line)
      fence_line = line
      sub(/^   ? ?/, "", fence_line)
      if (match(fence_line, /^```+|^~~~+/)) {
        marker = substr(fence_line, 1, 1)
        width = RLENGTH
        tail = substr(fence_line, width + 1)
        if (fence == "") {
          fence = marker
          fence_width = width
        } else if (marker == fence && width >= fence_width && tail ~ /^[[:space:]]*$/) {
          fence = ""
        }
        pending = 0
        next
      }
      if (fence != "") next
      if (pending && line !~ /^[[:space:]]*$/) {
        if (line ~ /^Reason: /) {
          value = substr(line, 9)
          if (value ~ /[^[:space:]]/) {
            print value
            exit
          }
        }
        pending = 0
      }
      if (line == "#### Docs Drift Exemption") pending = 1
    }
  ' "$body") || fail "Cannot parse --body file."
fi

if [[ -n $reason ]]; then
  annotation notice "Docs drift linkage exemption: $reason"
else
  annotation warning "Docs drift linkage: implementation changed without documentation: ${implementation[*]}"
fi
