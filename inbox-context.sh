#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}
[[ -d $repo/inbox ]] || exit 0

# Process operator inbox files
while IFS= read -r -d '' item; do
    printf 'Operator inbox file: %q\n' "${item#"$repo/"}"
done < <(find "$repo/inbox" -maxdepth 1 -type f ! -name README.md ! -name 'agenda.md' -print0 | LC_ALL=C sort -z)

# Process agenda file
if [[ -f "$repo/inbox/agenda.md" ]]; then
    printf '\n'  # Separator
    printf 'Agenda file (pre-approved work): %q\n' "inbox/agenda.md"
fi
