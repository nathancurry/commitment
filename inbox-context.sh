#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}
[[ -d $repo/inbox ]] || exit 0
while IFS= read -r -d '' item; do
    printf 'Operator inbox file: %q\n' "${item#"$repo/"}"
done < <(find "$repo/inbox" -maxdepth 1 -type f ! -name README.md -print0 | LC_ALL=C sort -z)
