#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}
[[ -d $repo/queue ]] || exit 0
while IFS= read -r -d '' item; do
    printf 'Queue file: %q\n' "${item#"$repo/"}"
done < <(find "$repo/queue" -maxdepth 1 -type f ! -name README.md -print0 | LC_ALL=C sort -z)
