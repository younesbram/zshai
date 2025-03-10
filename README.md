# zshai
ai in your terminal

## Setup

```bash
# Install dependencies
brew install jq fzf  # or apt-get install jq fzf

# Set API keys
export GROQ_API_KEY='your_key' 
export OPENAI_API_KEY='your_key'

# Add to zshrc
echo "source /path/to/zshai/smartcomplete.zsh" >> ~/.zshrc
```

## TODO
add on first run ask user if zshai can see his .zshrc to know ALIASES

## Usage

- `Ctrl+H` - Get AI command suggestions
- `Ctrl+E` - Explain current command

## Config

- `SUGGEST_KEY` and `EXPLAIN_KEY` - Change keybindings
- `STREAMING_ENABLED` - Toggle typewriter effect
- `GROQ_MODEL` and `GPT4O_MODEL` - Change AI models

## License

none, free code
