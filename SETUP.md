# Buck — Setup Guide

Complete instructions for building and running Buck from scratch.

## Prerequisites

| Requirement | Why |
|-------------|-----|
| **macOS 14.0+** | Minimum deployment target |
| **Xcode 15+** | Build the Swift/SwiftUI project |
| **ChatGPT desktop app** | Buck automates it via Accessibility API |
| **python3** | buck-review.sh uses it for JSON escaping |

## Step 1: Clone / copy the project

```bash
cd ~/Mac\ Projects
# If cloning from git:
git clone <repo-url> buck
# Or if you already have it, just cd into it:
cd buck
```

## Step 2: Build and deploy

### Option A: Xcode GUI

1. Open `Buck/Buck.xcodeproj` in Xcode
2. Select the **Buck** scheme, target **My Mac**
3. Press **Cmd+R** (Run)

The build includes a Run Script phase that automatically:
- Copies `Buck.app` to `/Applications/`
- Ad-hoc code signs it
- Clears extended attributes

### Option B: Command line

```bash
cd ~/Mac\ Projects/buck
xcodebuild -project Buck/Buck.xcodeproj -scheme Buck -configuration Debug build
```

The same Run Script phase runs during `xcodebuild`, so the app is deployed to `/Applications/Buck.app` automatically.

## Step 3: Grant Accessibility permission

Buck uses the macOS Accessibility API to interact with ChatGPT. On first launch, macOS will prompt you to grant permission. If it doesn't:

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click the **+** button
3. Navigate to `/Applications/Buck.app` and add it
4. Ensure the toggle is **ON**

> **Important:** If you rebuild Buck, the binary signature changes and macOS revokes the permission. You'll need to toggle Buck **off then on** in the Accessibility list after each rebuild. You do NOT need to remove and re-add it — just toggle.

### Verify permission

Check the log after launching:
```bash
tail -5 ~/.buck/logs/buck.log
```

If you see `AXIsProcessTrusted=false`, the permission isn't granted yet.

## Step 4: Set up ChatGPT

1. Install the [ChatGPT desktop app](https://openai.com/chatgpt/desktop/) if you haven't
2. Open it and sign in
3. Make sure a chat window is **visible** (not minimized)

Buck finds ChatGPT by its bundle ID (`com.openai.chat`) and interacts with the focused window. If no window is visible, Buck can't send messages.

## Step 5: Create runtime directories

Buck creates these automatically on first use, but you can create them manually:

```bash
mkdir -p ~/.buck/inbox ~/.buck/outbox ~/.buck/logs
```

## Step 6: Make the review script executable

```bash
chmod +x ~/Mac\ Projects/buck/buck-review.sh
```

## Step 7: Configure Claude Code integration

Buck works with Claude Code via CLAUDE.md instruction files.

### Project-level (per project)

The `CLAUDE.md` in the Buck repo teaches Claude Code the basic mechanics (how to call the script, parse JSON, handle retries). For other projects that should use Buck, copy it:

```bash
cp ~/Mac\ Projects/buck/CLAUDE.md /path/to/your-project/CLAUDE.md
```

### Global (all projects)

To make Claude Code use Buck as an automatic reviewer everywhere — GPT reviews every plan and every edit:

```bash
# If you don't have a global CLAUDE.md yet:
cp ~/Mac\ Projects/buck/examples/global-claude-md.md ~/.claude/CLAUDE.md

# If you already have one, append:
cat ~/Mac\ Projects/buck/examples/global-claude-md.md >> ~/.claude/CLAUDE.md
```

> **Path note:** If you cloned Buck somewhere other than `~/Mac Projects/buck/`, update the `buck-review.sh` path in both CLAUDE.md files.

## Step 8: Test

```bash
# Ensure Buck is running
pgrep -x Buck > /dev/null || open /Applications/Buck.app

# Send a simple test
~/Mac\ Projects/buck/buck-review.sh --stdin <<'BUCKEOF'
Say exactly: APPROVED
BUCKEOF
```

You should see:
1. Buck's menu bar icon fills (processing)
2. ChatGPT receives the message and responds
3. JSON output appears in your terminal with `"status": "approved"`

If nothing happens, check:
```bash
tail -20 ~/.buck/logs/buck.log
```

## Troubleshooting

### "Accessibility permission denied"

Toggle Buck off/on in System Settings → Privacy & Security → Accessibility. This is needed after every rebuild.

### "ChatGPT is not running"

Open the ChatGPT desktop app. Ensure it has a visible (not minimized) window.

### "Send button not found"

ChatGPT's UI may have changed, or the window isn't focused. Try clicking on the ChatGPT window to bring it to the front, then retry.

### "Another message is in flight"

Buck processes one request at a time. Wait for the current request to finish, or restart Buck:
```bash
pkill -x Buck; sleep 1; open /Applications/Buck.app
```

### buck-review.sh returns empty output

Check the script is executable and non-empty:
```bash
ls -la ~/Mac\ Projects/buck/buck-review.sh
wc -c ~/Mac\ Projects/buck/buck-review.sh
```

If 0 bytes, restore from git or recreate it.

### Timeout waiting for response

- Is the ChatGPT window visible and not behind other windows?
- Is GPT actually generating a response? Look at the ChatGPT window.
- Check `~/.buck/logs/buck.log` for poll details — look for `sendBtn=` state and `len=` values.

### Menu bar icon shows X

An error occurred. Check:
```bash
tail -5 ~/.buck/logs/buck.log
```

Common causes: AX permission revoked, ChatGPT quit, window closed mid-request.

## Integration with AI coding tools

Buck ships with instruction files for AI coding assistants:

| File | For |
|------|-----|
| `CLAUDE.md` | Claude Code — auto-review workflow |
| `AGENTS.md` | OpenAI Codex and other agents |

These files tell the coding assistant how to call `buck-review.sh`, interpret the JSON response, and handle retries. The assistants use Buck automatically when configured — no manual copy-paste needed.

## Uninstall

```bash
# Stop Buck
pkill -x Buck

# Remove the app
rm -rf /Applications/Buck.app

# Remove runtime data
rm -rf ~/.buck

# Remove Accessibility entry
# System Settings → Privacy & Security → Accessibility → select Buck → click -
```
