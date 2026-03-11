# Contributing to Buck

Thanks for your interest in improving Buck.

## Quick start

1. Fork the repo and clone it
2. Open `Buck/Buck.xcodeproj` in Xcode
3. Build and run (Cmd+R) — auto-deploys to `/Applications/Buck.app`
4. Grant Accessibility permission (System Settings > Privacy & Security > Accessibility)
5. Make your changes, test with `buck-review.sh`

## What to work on

Check the [Issues](https://github.com/rjamesy/buck/issues) tab. Good first issues are labeled `good first issue`.

High-impact areas:
- **Response detection** — the hardest problem. Better heuristics for knowing when GPT is done generating.
- **AX tree resilience** — ChatGPT updates can break the AX path. Making navigation more robust.
- **New AI targets** — supporting other chat apps beyond ChatGPT (Gemini, local models, etc.)
- **Pre-built releases** — distributing a signed `.app` so users don't need Xcode

## How to submit changes

1. Create a branch from `main`
2. Make your changes
3. Test manually — send a few reviews, check the logs at `~/.buck/logs/buck.log`
4. Open a PR with a clear description of what changed and why

## Code style

- Swift: follow existing patterns in the codebase
- Shell: `set -euo pipefail`, quote variables
- Keep it simple — Buck's value is that it's small and understandable

## Reporting bugs

Open an issue with:
- What you did
- What you expected
- What happened
- Relevant lines from `~/.buck/logs/buck.log`

## AX tree changes

ChatGPT's desktop app updates frequently and can change its Accessibility tree structure. If Buck breaks after a ChatGPT update, the diagnostic approach is:

1. Run the AX tree inspector (Accessibility Inspector.app in Xcode)
2. Compare the current tree to the path documented in README.md
3. Update `ChatGPTBridge.swift` navigation methods accordingly

These fixes are always welcome as PRs.
