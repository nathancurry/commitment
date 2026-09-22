#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}

# Parse agenda and convert to queue items
convert_agenda_to_queue() {
    local repo_path=$1
    
    # Check if agenda exists
    if [[ ! -f "$repo_path/inbox/agenda.md" ]]; then
        return 0
    fi
    
    # Read the entire agenda file
    local agenda_content
    agenda_content=$(cat "$repo_path/inbox/agenda.md")
    
    # Find all agenda items with their content
    local process_state=0  # 0=reading, 1=in item, 2=done
    local current_item=""
    local current_content=""
    
    while IFS= read -r line; do
        if [[ $line == "### "* ]]; then
            # Save previous item if exists
            if [[ -n $current_item ]]; then
                create_queue_item "$repo_path" "$current_item" "$current_content"
                current_item=""
                current_content=""
            fi
            
            # Extract item name (remove the ### prefix and trim)
            current_item="${line#??? }"
            # Remove any trailing markers like "PENDING" or "IN-PROGRESS"
            current_item="${current_item%% *}"
        elif [[ $line == "---" ]]; then
            # Save item before separator
            if [[ -n $current_item ]]; then
                create_queue_item "$repo_path" "$current_item" "$current_content"
                current_item=""
                current_content=""
            fi
        elif [[ -n $line && -n $current_item ]]; then
            # Add to current content
            current_content+="$line"
            current_content+=$'\n'
        fi
    done <<< "$agenda_content"
    
    # Save last item
    if [[ -n $current_item ]]; then
        create_queue_item "$repo_path" "$current_item" "$current_content"
    fi
}

create_queue_item() {
    local repo_path=$1
    local item_name=$2
    local item_content=$3
    
    # Create filename (replace spaces and special chars with dashes)
    local filename="${item_name//[^a-zA-Z0-9 _\-]/-}"
    filename="${filename// /-}"
    filename="${filename,,}"
    local queue_file="$repo_path/queue/${filename}-from-agenda.md"
    
    # Create queue file
    cat <<EOF > "$queue_file"
# Agenda Item: $item_name

## Source
- inbox/agenda.md
- Agenda item: $item_name

## Objective
Agenda objective: $item_name

## Context
Agenda-based work item for long-running session

## Agenda Details
EOF
    
    if [[ -n $item_content ]]; then
        # Add the actual agenda content
        echo "" >> "$queue_file"
        echo "$item_content" >> "$queue_file"
    fi
    
    # Add processing note
    printf "\n---\nQueued from agenda.md during session startup\n" >> "$queue_file"
}

# Main execution
convert_agenda_to_queue "$repo"
