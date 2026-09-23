# weft — agent notes

## Commits
- Never add `Co-Authored-By: Claude ...`, `Claude-Session: ...`, or any other
  AI co-authorship / session trailer to commit messages. No exceptions.
- A `commit-msg` hook enforces this and rejects offending messages.
- After cloning, enable the versioned hooks once:
  `git config core.hooksPath .githooks`

## Releases
- Every release is `0.9.*`: the next one after `v0.9.N` is `v0.9.(N+1)`
  (`0.9.12`, `0.9.13`, … `0.9.99`, `0.9.100`). Never bump to `1.0` — or to
  any version outside `0.9.*` — until the maintainer explicitly says so.
- The version lives in `Sources/WeftCore/Version.swift`; the tag is `v` plus
  that string, annotated, pushed after the commit it names.
