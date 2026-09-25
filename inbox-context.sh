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

# Generate morning report for long-running sessions
generate_morning_report() {
    local outcome=$1
    local summary=$2
    local repo_path=$3
    
    echo "# Morning Report for Long-Running Session"
    echo ""
    echo "## Session Summary"
    echo "- Outcome: $outcome"
    echo "- Summary: $summary"
    
    echo ""
    echo "## Work Completed"
    echo "- Session work tracked through CURRENT.md"
    
    # Check work directory for active items
    if [[ -d "$repo_path/work" && -n "$(find "$repo_path/work" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' 2>/dev/null)" ]]; then
        echo "- Work items tracked in work/ directory:"
        while IFS= read -r -d '' workfile; do
            basename="${workfile##*/}"
            echo "  - $basename"
        done < <(find "$repo_path/work" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' -print0 | sort -z)
    fi
    
    echo ""
    echo "## Active Agenda Items"
    # List agenda items with status
    if [[ -f "$repo_path/inbox/agenda.md" ]]; then
/bin/true
        process_agenda "$repo_path"
    fi
    
    echo ""
    echo "## Parked Questions"
    # List number of parked questions
    parked_count=0
    if [[ -d "$repo_path/parked-questions" ]]; then
        parked_count=$(find "$repo_path/parked-questions" -maxdepth 1 -type f ! -name 'README.md' 2>/dev/null | wc -l)
        if (( parked_count > 0 )); then
            echo "- Parked questions awaiting operator input: $parked_count"
            echo ""
            echo "  Files:"
            while IFS= read -r -d '' item; do
                basename="${item##*/}"
                echo "  - $basename"
            done < <(find "$repo_path/parked-questions" -maxdepth 1 -type f ! -name 'README.md' -print0 | LC_ALL=C sort -z)
        else
            echo "- No parked questions"
        fi
    else
        echo "- Parked questions directory not yet created"
    fi
    
    echo ""
    echo "## Resource Usage"
    echo "- CPU time: Session duration via timeout mechanism"
    echo "- Memory usage: Container limit 8GB"
    echo "- API calls: Tracked via runlog.jsonl"
    
    echo ""
    echo "## Recommendations"
    echo "- Continue with actionable agenda items"
    if (( parked_count > 0 )); then
        echo "- Review parked questions for operator clarification"
    fi
    echo "- Update CURRENT.md with progress"
}

