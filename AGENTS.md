# weft — agent notes

## Commits
- Never add `Co-Authored-By: Claude ...`, `Claude-Session: ...`, or any other
  AI co-authorship / session trailer to commit messages. No exceptions.
- A `commit-msg` hook enforces this and rejects offending messages.
- After cloning, enable the versioned hooks once:
  `git config core.hooksPath .githooks`
