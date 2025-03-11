# code is really bad, but it works for me, feel free to fork this and fix the ctrl h part better on fzf but for my usecase it accelerates so much
autoload -Uz add-zsh-hook

# Hardcoded settings
SUGGEST_KEY='^H'  # Ctrl+H
EXPLAIN_KEY='^E'  # Ctrl+E
GROQ_MODEL="llama-3.1-8b-instant"
GPT4O_MODEL="gpt-4o-2024-08-06"
CLAUDE_MODEL="claude-3-7-sonnet-20250219"
GROQ_API_KEY=${GROQ_API_KEY:-""}
OPENAI_API_KEY=${OPENAI_API_KEY:-""}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-""}
STREAMING_ENABLED=false  # Set to false to disable typewriter effect

# Variables to store previous suggestions
PREV_GROQ_SUGGESTIONS=""
PREV_GPT4O_SUGGESTIONS=""
PREV_CLAUDE_SUGGESTIONS=""

# Dependency check
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required. Install it with 'brew install jq' (macOS) or 'sudo apt-get install jq' (Ubuntu)."
  return 1
fi
if ! command -v fzf >/dev/null 2>&1; then
  echo "Error: fzf is required. Install it with 'brew install fzf' (macOS) or 'sudo apt-get install fzf' (Ubuntu)."
  return 1
fi

# API key check
if [[ -z "$GROQ_API_KEY" || -z "$OPENAI_API_KEY" || -z "$ANTHROPIC_API_KEY" ]]; then
  echo "Error: Please set GROQ_API_KEY, OPENAI_API_KEY, and ANTHROPIC_API_KEY in your environment."
  echo "Example: export GROQ_API_KEY='your_groq_key' && export OPENAI_API_KEY='your_openai_key' && export ANTHROPIC_API_KEY='your_anthropic_key'"
  return 1
fi

# First-run keybinding check
FIRST_RUN_FILE=~/.smartcomplete_first_run
if [[ ! -f "$FIRST_RUN_FILE" ]]; then
  for key in "$SUGGEST_KEY" "$EXPLAIN_KEY"; do
    local current_binding=$(bindkey "$key" | awk '{print $2}')
    if [[ -n "$current_binding" && "$current_binding" != "suggest_ai" && "$current_binding" != "explain_command" ]]; then
      echo "Key '$key' is currently bound to '$current_binding'."
      echo -n "Override? (y/n): "
      read -r answer
      if [[ "$answer" =~ ^[Yy]$ ]]; then
        bindkey -r "$key"
      else
        echo "Skipping override for '$key'. Pick a new key manually (e.g., edit script)."
      fi
    fi
  done
  touch "$FIRST_RUN_FILE"
fi

# Global variables
typeset -A EXPLANATIONS  # Cache for command explanations

# Get history matches for a prefix
get_history_matches() {
  local prefix="$1"
  local max_matches="${2:-10}"
  
  # Skip if prefix is empty
  [[ -z "$prefix" ]] && return
  
  # Get raw history, filter for prefix, sort and get unique entries
  fc -ln 1 | grep "^$prefix" | sort -u | tail -n "$max_matches"
}

# AI suggestions via Groq
suggest_ai() {
  local buffer="$BUFFER"
  local temp_file=$(mktemp)
  
  # Clear previous suggestions when starting a new session
  PREV_GROQ_SUGGESTIONS=""
  PREV_GPT4O_SUGGESTIONS=""
  PREV_CLAUDE_SUGGESTIONS=""
  
  # Get FZF-style history matches first (just like ctrl-r behavior)
  if [[ -n "$buffer" ]]; then
    get_history_matches "$buffer" 15 > "$temp_file"
  else
    # If buffer is empty, show recent commands
    fc -ln 1 | tail -n 15 | sort -u > "$temp_file"
  fi
  
  # Now add refresh options at the BOTTOM
  echo "Refresh with Llama-8b-instant" >> "$temp_file"
  echo "Refresh with GPT-4o" >> "$temp_file"
  echo "Refresh with Claude" >> "$temp_file"
  
  # Present initial suggestions - just like ctrl-r
  local selection=$(cat "$temp_file" | fzf --height=15 --prompt="Pick a command> " --reverse)
  
  if [[ -n "$selection" ]]; then
    if [[ "$selection" == "Refresh with GPT-4o" ]]; then
      rm -f "$temp_file" 2>/dev/null
      refresh_gpt4o
      return
    elif [[ "$selection" == "Refresh with Llama-8b-instant" ]]; then
      rm -f "$temp_file" 2>/dev/null
      refresh_groq
      return
    elif [[ "$selection" == "Refresh with Claude" ]]; then
      rm -f "$temp_file" 2>/dev/null
      refresh_claude
      return
    else
      BUFFER="$selection"
      CURSOR=${#BUFFER}
    fi
  fi
  
  rm -f "$temp_file" 2>/dev/null
  zle redisplay
}

# Groq refresh with complete context
refresh_groq() {
  local buffer="$BUFFER"
  local temp_file=$(mktemp)
  local json_file=$(mktemp)
  local suggestions_file=$(mktemp)
  
  # First get FZF-style history matches (just like ctrl-r)
  if [[ -n "$buffer" ]]; then
    get_history_matches "$buffer" 15 > "$temp_file"
  else
    # If buffer is empty, show recent commands
    fc -ln 1 | tail -n 15 | sort -u > "$temp_file"
  fi
  
  # Build the do-not-suggest list
  local avoid_list=""
  if [[ -n "$PREV_GROQ_SUGGESTIONS" ]]; then
    avoid_list="DO NOT suggest these previous commands: $PREV_GROQ_SUGGESTIONS"
  fi
  
  # Escape buffer for JSON
  local escaped_buffer=$(echo "$buffer" | sed 's/"/\\"/g')
  
  # Create a sanitized API payload - explicitly asking for FULL commands
  cat > "$json_file" << EOL
{"model": "$GROQ_MODEL", "messages": [{"role": "user", "content": "Generate 4-5 realistic shell commands starting with '$escaped_buffer'. Include multiple arguments and ensure they are full commands that are useful according to the developers context. He is on a macos zsh. $avoid_list Return ONLY a JSON array format: {\"suggestions\":[\"$escaped_buffer command1\",\"$escaped_buffer command2\",...]}. Make sure each suggestion is a complete, runnable command that starts with '$escaped_buffer'."}], "response_format": {"type": "json_object"}, "max_tokens": 1050}
EOL
  
  # Make API call
  local result_file=$(mktemp)
  curl -s -m 5 https://api.groq.com/openai/v1/chat/completions \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$json_file" 2>/dev/null | 
    jq -r '.choices[0].message.content' 2>/dev/null | 
    jq -r '.suggestions[]' 2>/dev/null > "$result_file"
  
  # Save suggestions for next refresh
  PREV_GROQ_SUGGESTIONS=$(cat "$result_file" | tr '\n' ',' | sed 's/,$//')
  
  # Append results to temp file
  if [[ -s "$result_file" ]]; then
    cat "$result_file" >> "$temp_file"
  fi
  
  # Add refresh options at the BOTTOM
  echo "Refresh with Llama-8b-instant" >> "$temp_file"
  echo "Refresh with GPT-4o" >> "$temp_file"
  echo "Refresh with Claude" >> "$temp_file"
  
  # Present all suggestions
  local selection=$(cat "$temp_file" | fzf --height=15 --prompt="Llama suggestions> " --reverse)
  
  # Handle selection
  if [[ -n "$selection" ]]; then
    if [[ "$selection" == "Refresh with GPT-4o" ]]; then
      rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
      refresh_gpt4o
      return
    elif [[ "$selection" == "Refresh with Llama-8b-instant" ]]; then
      rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
      refresh_groq
      return
    elif [[ "$selection" == "Refresh with Claude" ]]; then
      rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
      refresh_claude
      return
    else
      BUFFER="$selection"
      CURSOR=${#BUFFER}
    fi
  fi
  
  # Clean up
  rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
  zle redisplay
}

# GPT-4o refresh with full context
refresh_gpt4o() {
  local buffer="$BUFFER"
  local temp_file=$(mktemp)
  local json_file=$(mktemp)
  
  # First get FZF-style history matches (just like ctrl-r)
  if [[ -n "$buffer" ]]; then
    get_history_matches "$buffer" 15 > "$temp_file"
  else
    # If buffer is empty, show recent commands
    fc -ln 1 | tail -n 15 | sort -u > "$temp_file"
  fi
  
  # Build the do-not-suggest list
  local avoid_list=""
  if [[ -n "$PREV_GPT4O_SUGGESTIONS" ]]; then
    avoid_list="DO NOT suggest these previous commands: $PREV_GPT4O_SUGGESTIONS"
  fi
  
  # Escape buffer for JSON
  local escaped_buffer=$(echo "$buffer" | sed 's/"/\\"/g')
  
  # Create a sanitized API payload - explicitly asking for FULL commands
  # TO DO : add context like ```tree``` and pwd and whoami and echo $SHELL blablabal
  cat > "$json_file" << EOL
{"model": "$GPT4O_MODEL", "messages": [{"role": "user", "content": "Generate 8 realistic shell commands starting with '$escaped_buffer'. Include multiple arguments and full commands. $avoid_list Return ONLY a JSON array format: {\"suggestions\":[\"$escaped_buffer command1\",\"$escaped_buffer command2\",...]}. Make sure each suggestion is a complete, runnable command that starts with '$escaped_buffer'."}], "response_format": {"type": "json_object"}, "max_tokens": 900}
EOL
  
  # Make API call
  local result_file=$(mktemp)
  curl -s -m 5 https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$json_file" 2>/dev/null | 
    jq -r '.choices[0].message.content' 2>/dev/null | 
    jq -r '.suggestions[]' 2>/dev/null > "$result_file"
  
  # Save suggestions for next refresh
  PREV_GPT4O_SUGGESTIONS=$(cat "$result_file" | tr '\n' ',' | sed 's/,$//')
  
  # Append results to temp file
  if [[ -s "$result_file" ]]; then
    cat "$result_file" >> "$temp_file"
  fi
  
  # Add refresh options at the BOTTOM
  echo "Refresh with Llama-8b-instant" >> "$temp_file"
  echo "Refresh with GPT-4o" >> "$temp_file"
  echo "Refresh with Claude" >> "$temp_file"
  
  # Present all suggestions
  local selection=$(cat "$temp_file" | fzf --height=15 --prompt="GPT-4o suggestions> " --reverse)
  
  # Handle selection
  if [[ -n "$selection" ]]; then
    if [[ "$selection" == "Refresh with GPT-4o" ]]; then
      rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
      refresh_gpt4o
      return
    elif [[ "$selection" == "Refresh with Llama-8b-instant" ]]; then
      rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
      refresh_groq
      return
    elif [[ "$selection" == "Refresh with Claude" ]]; then
      rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
      refresh_claude
      return
    else
      BUFFER="$selection"
      CURSOR=${#BUFFER}
    fi
  fi
  
  # Clean up
  rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
  zle redisplay
}

# Claude refresh with full context
refresh_claude() {
  local buffer="$BUFFER"
  local temp_file=$(mktemp)
  local json_file=$(mktemp)
  
  # First get FZF-style history matches (just like ctrl-r)
  if [[ -n "$buffer" ]]; then
    get_history_matches "$buffer" 15 > "$temp_file"
  else
    # If buffer is empty, show recent commands
    fc -ln 1 | tail -n 15 | sort -u > "$temp_file"
  fi
  
  # Build the do-not-suggest list
  local avoid_list=""
  if [[ -n "$PREV_CLAUDE_SUGGESTIONS" ]]; then
    avoid_list="DO NOT suggest these previous commands: $PREV_CLAUDE_SUGGESTIONS"
  fi
  
  # Escape buffer for JSON
  local escaped_buffer=$(echo "$buffer" | sed 's/"/\\"/g')
  
  # Create a sanitized API payload - explicitly asking for FULL commands
  cat > "$json_file" << EOL
{"model": "$CLAUDE_MODEL", "messages": [{"role": "user", "content": "Generate 8 realistic shell commands starting with '$escaped_buffer'. Include multiple arguments and full commands. $avoid_list Return ONLY a JSON array format: {\"suggestions\":[\"$escaped_buffer command1\",\"$escaped_buffer command2\",...]}. Make sure each suggestion is a complete, runnable command that starts with '$escaped_buffer'."}], "max_tokens": 900}
EOL
  
  # Make API call
  local result_file=$(mktemp)
  curl -s -m 5 https://api.anthropic.com/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d @"$json_file" 2>/dev/null | 
    jq -r '.content[0].text' 2>/dev/null | 
    jq -r '.suggestions[]' 2>/dev/null > "$result_file"
  
  # Save suggestions for next refresh
  PREV_CLAUDE_SUGGESTIONS=$(cat "$result_file" | tr '\n' ',' | sed 's/,$//')
  
  # Append results to temp file
  if [[ -s "$result_file" ]]; then
    cat "$result_file" >> "$temp_file"
  fi
  
  # Add refresh options at the BOTTOM
  echo "Refresh with Llama-8b-instant" >> "$temp_file"
  echo "Refresh with GPT-4o" >> "$temp_file"
  echo "Refresh with Claude" >> "$temp_file"
  
  # Present all suggestions
  local selection=$(cat "$temp_file" | fzf --height=15 --prompt="Claude suggestions> " --reverse)
  
  # Handle selection
  if [[ -n "$selection" ]]; then
    if [[ "$selection" == "Refresh with GPT-4o" ]]; then
      rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
      refresh_gpt4o
      return
    elif [[ "$selection" == "Refresh with Llama-8b-instant" ]]; then
      rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
      refresh_groq
      return
    elif [[ "$selection" == "Refresh with Claude" ]]; then
      rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
      refresh_claude
      return
    else
      BUFFER="$selection"
      CURSOR=${#BUFFER}
    fi
  fi
  
  # Clean up
  rm -f "$temp_file" "$json_file" "$result_file" 2>/dev/null
  zle redisplay
}

# Command explanation function
explain_command() {
  local buffer="$BUFFER"
  
  if [[ -n "${EXPLANATIONS[$buffer]}" ]]; then
    echo ""
    if [[ "$STREAMING_ENABLED" == "true" ]]; then
      # Show with typewriter effect
      for (( i=0; i<${#EXPLANATIONS[$buffer]}; i++ )); do
        echo -n "${EXPLANATIONS[$buffer]:$i:1}"
        sleep 0.003
      done
      echo
    else
      # Just show the full explanation
      echo "${EXPLANATIONS[$buffer]}"
    fi
    zle redisplay
    return
  fi
  
  # Create temporary file for API request
  local json_file=$(mktemp)
  
  # Properly escape the buffer for JSON
  local escaped_buffer=$(echo "$buffer" | sed 's/"/\\"/g')
  
  # Create a sanitized API payload with escaped buffer
  cat > "$json_file" << EOL
{"model": "$GROQ_MODEL", "messages": [{"role": "user", "content": "You are a terminal assistant. Explain what this command does or answer the programmer if he asks you anything: '${escaped_buffer}'. Be concise and natural."}], "max_tokens": 300}
EOL
  
  # Make API call
  local response=$(curl -s -m 5 https://api.groq.com/openai/v1/chat/completions \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$json_file" 2>/dev/null | 
    jq -r '.choices[0].message.content' 2>/dev/null)
  
  rm -f "$json_file" 2>/dev/null
  
  if [[ -n "$response" && "$response" != "null" ]]; then
    EXPLANATIONS[$buffer]="$response"
    
    echo ""
    if [[ "$STREAMING_ENABLED" == "true" ]]; then
      # Show with typewriter effect
      for (( i=0; i<${#response}; i++ )); do
        echo -n "${response:$i:1}"
        sleep 0.003
      done
      echo
    else
      # Just show the full explanation
      echo "$response"
    fi
  else
    echo ""
    echo "Couldn't get an explanation."
  fi
  zle redisplay
}

# Define ZLE widgets
zle -N suggest_ai
zle -N explain_command

# Force remove potential existing bindings
bindkey -r '^H'
bindkey -r '^E'

# Bind the keys directly
bindkey '^H' suggest_ai      # Ctrl+H triggers Groq AI
bindkey '^E' explain_command # Ctrl+E explains command
