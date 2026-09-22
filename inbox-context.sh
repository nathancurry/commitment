#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}
[[ -d $repo/inbox ]] || exit 0

generate_morning_report() {
    local outcome=$1
    local summary=$2
    local repo_path=$3
    
    local parked_count=0
    
    # Count parked questions
    if [[ -d "$repo_path/parked-questions" ]]; then
        parked_count=$(find "$repo_path/parked-questions" -maxdepth 1 -type f ! -name README.md | wc -l)
    fi
    
    cat <<EOF
# Session Morning Report

## Session Overview
- **Outcome**: $outcome
- **Summary**: $summary
- **Generated**: $(date -Iseconds)

## Work Summary
EOF
    
    printf "%s\n" "- Completed tasks: TDB"
    printf "%s\n" "- Changes to commitment repository: TDB"
    printf "%s\n" "- Changes to lab repository: TDB"
    


    cat <<EOF

## Agenda Progress
EOF
    
    # List active agenda items
    process_agenda "$repo_path" | while read -r line; do
        printf "  - %s\n" "$line"
    done 2>/dev/null || true

    cat <<EOF

## Parked Questions
EOF
    
    printf "%s\n" "- Total parked: ${parked_count}"
    
    # List parked questions
    if (( parked_count > 0 )); then
        printf "\nParked Questions:\n"
        while IFS= read -r -d '' item; do
            basename="${item#"$repo_path/parked-questions/"}"
            printf "  - %s\n" "$basename"
        done < <(find "$repo_path/parked-questions" -maxdepth 1 -type f ! -name README.md -print0 | LC_ALL=C sort -z) 2>/dev/null || true
    fi

    cat <<EOF

## Session Resources
- CPU usage: TDB (requires tracking)
- Memory usage: TDB (requires tracking)
- External API calls: TDB (requires tracking)
- Session duration: TDB (requires tracking)

## Next Steps
- Review parked questions for operator input
- Continue with active agenda items
- Identify new useful work opportunities
EOF
}

generate_session_morning_report() {
    local outcome=$1
    local summary=$2
    
    echo "# Morning Report"
    echo ""
    echo "## Session Summary"
    echo "- Outcome: $outcome"
    echo "- Summary: $summary"
    
    echo ""
    echo "## Work Completed"
    echo "- List of accomplished tasks from CURRENT.md"
    echo "- Changes made to repositories"
    
    echo ""
    echo "## Active Agenda Items"
    echo "- Agenda items with status"
    echo "- Progress toward goals"
    
    echo ""
    echo "## Parked Questions"
    echo "- Number of parked questions"
    echo "- Questions awaiting input"
    
    echo ""
    echo "## Resource Usage"
    echo "- CPU time: TODO"
    echo "- Memory usage: TODO"
    echo "- API calls: TODO"
    
    echo ""
    echo "## Recommendations"
    echo "- Next steps based on current state"
    echo "- Blockers requiring operator input"
}



process_agenda() {
    local repo_path=$1
    
    # Check if agenda exists and has content
    if [[ ! -f "$repo_path/inbox/agenda.md" ]]; then
        return
    fi
    
    # Read agenda content
    local agenda_content
    agenda_content=$(cat "$repo_path/inbox/agenda.md")
    
    # Look for agenda items marked as PENDING
    # This is a simplified parser that looks for "### " headers
    while IFS= read -r line; do
        if [[ $line == "### "* ]]; then
            # Extract the agenda item name
            local item_name="${line#### }"
            # Remove trailing markers
            item_name="${item_name%% *}"
            
            # Look for status indicators in next few lines
            local status="PENDING"
            while IFS= read -r status_line && [[ $status_line != "### "* ]]; do
                if [[ $status_line == *" Status: "* ]]; then
                    status="${status_line#*:}"
                    status="${status%% *}"
                    break
                fi
            done <<< "$agenda_content"
            
            # Only output pending items
            if [[ "$status" == "PENDING" ]]; then
                printf ' Agenda Item: %q (Status: %s)\n' "$item_name" "$status"
            fi
        fi
    done <<< "$agenda_content"
}

# Process operator inbox files
while IFS= read -r -d '' item; do
    printf 'Operator inbox file: %q\n' "${item#"$repo/"}"
done < <(find "$repo/inbox" -maxdepth 1 -type f ! -name README.md ! -name 'agenda.md' -print0 | LC_ALL=C sort -z)

# Process agenda file
if [[ -f "$repo/inbox/agenda.md" ]]; then
    printf '\n'  # Separator
    printf 'Agenda file (pre-approved work): %q\n' "inbox/agenda.md"
    
    # Parse agenda and extract actionable items
    process_agenda "$repo"
fi
