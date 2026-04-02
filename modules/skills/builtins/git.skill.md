---
package: git
version: "2.44"
capabilities: [version-control, collaboration, code-management]
requires: []
---

# git

## What it does
Distributed version control system for tracking changes in source code and coordinating work among developers.

## Common tasks

### Clone a repository
```bash
git clone <url> [directory]
```

### Create a branch and switch to it
```bash
git checkout -b <branch-name>
```

### Stage, commit, and push
```bash
git add <files>
git commit -m "description of change"
git push origin <branch>
```

### View history
```bash
git log --oneline --graph -20
```

### Stash work in progress
```bash
git stash push -m "description"
git stash pop
```

## When to use
- User wants to track code changes
- User needs to collaborate on code
- User wants to manage project versions
- User asks about code history or diffs

## Gotchas
- Always check `git status` before committing to avoid including unwanted files
- Use `git diff --staged` to review what you're about to commit
- Prefer `git pull --rebase` to keep linear history
