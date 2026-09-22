#!/usr/bin/env bash
set -euo pipefail

repo=${1:?repository path is required}

# Import the agenda processing function
import_function() {
    # Read and import just the process_agenda function
    while IFS= read -r line; do
        [[ $line == "process_agenda() {" ]] && start_import=1
        [[ $start_import == 1 ]] && echo "$line"
        [[ $line == "}" && $start_import == 1 ]] && break
    done < "$repo/inbox-context.sh"
}

# Parse agenda and convert to queue items
convert_agenda_to_queue() {
    local repo_path=$1
    
    # Check if agenda exists
    if [[ ! -f "$repo_path/inbox/agenda.md" ]]; then
        return 0
    fi
    
    local agenda_content
    agenda_content=$(cat "$repo_path/inbox/agenda.md")
    
    # Find all agenda items with their content
    while IFS= read -r line; do
        if [[ $line == "###"* ]]; then
            # Extract item name
            local item_name="${line#### }"
            item_name="${item_name%% *}"
            
            # Get the item content (next lines until next ### or blank line)
            printf "%q" "$item_name" | sed 's/\\n/ /g' > /tmp/agenda-item-name.txt
            
            # Extract content for this item
            local item_content=""
            while IFS= read -r content_line; do
                [[ $content_line == "###"* ]] && break
                [[ -z $content_line ]] && continue
                item_content+=("$content_line")
            done <<< "$agenda_content"
            
            # Create queue file
            local queue_file="$repo_path/queue/${item_name// /-}-from-agenda.md"
            queue_file="${queue_file,,}"  # lowercase
            
            cat <<EOF > "$queue_file"
# Agenda Item: $(< /tmp/agenda-item-name.txt)

## Source
- inbox/agenda.md
- Agenda item: $(< /tmp/agenda-item-name.txt)

## Objective
Agenda objective: $(< /tmp/agenda-item-name.txt)

## Context
EOF
            
            # Add the item content if any
            if [[ ${#item_content[@]} -gt 0 ]]; then
                printf "
## Agenda Item Content\n" >> "$queue_file"
                printf "%s\n" "${item_content[*]}" >> "$queue_file"
            fi
            
            # Add processing note
            printf "\n---\nQueued from agenda.md during session startup\n" >> "$queue_file"
        fi
    done <<< "$agenda_content"
}

# Main execution
convert_agenda_to_queue "$repo"
