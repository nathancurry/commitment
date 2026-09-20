#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}

# Build agenda context
agenda_context=""
if [[ -f "$repo/inbox/agenda.md" ]]; then
    agenda_items=$(grep -A 1000 "## Active Agenda Items" "$repo/inbox/agenda.md" | grep -B 1000 "## Completed Items" | tail -n +3 | head -n -3)
    if [[ -n "$agenda_items" ]]; then
        agenda_context="# Active Agenda from inbox/agenda.md\n\n$agenda_items\n\n"
    fi
fi

# Build parked questions summary
parked_context=""
parked_count=0
if [[ -d "$repo/parked-questions" ]]; then
    parked_count=$(find "$repo/parked-questions" -maxdepth 1 -type f ! -name README.md | wc -l)
    if (( parked_count > 0 )); then
        parked_context="## Parked Questions ($parked_count)\n\n"
        parked_context+="The following questions are parked, awaiting operator input:\n\n"
        while IFS= read -r -d '' item; do
            basename="${item#"$repo/parked-questions/"}"
            parked_context+="- $basename\n"
        done < <(find "$repo/parked-questions" -maxdepth 1 -type f ! -name README.md -print0 | LC_ALL=C sort -z)
        parked_context+="\n"
    fi
fi

# Build session continuity context
if [[ $parked_count -gt 0 || -n "$agenda_context" ]]; then
    echo "# Ongoing Session Context"
    echo ""
    echo "## Session Continuity"
    echo "This is a long-running session with preserved context."
    echo ""
    
    [[ -n "$agenda_context" ]] && echo "$agenda_context"
    [[ -n "$parked_context" ]] && echo "$parked_context"
    
    echo "## Next Moves"
    echo "1. Review active agenda items"
    echo "2. Check parked questions for actionable items"
    echo "3. Continue with productive work from queue/ or agenda"
    echo ""
else
    echo "" >&2
fi