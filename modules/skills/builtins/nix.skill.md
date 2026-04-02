---
package: nix
version: "2.18"
capabilities: [package-management, system-configuration, reproducible-builds, dev-environments]
requires: []
---

# nix

## What it does
Purely functional package manager and system configuration tool. The foundation of Claude-OS — all packages and system state are managed through Nix.

## Common tasks

### Install a package ephemerally (one-shot)
```bash
nix shell nixpkgs#<package> --command <cmd> <args>
```

### Search for packages
```bash
nix search nixpkgs <query>
```

### Run a program without installing
```bash
nix run nixpkgs#<package> -- <args>
```

### Enter a dev shell with multiple packages
```bash
nix shell nixpkgs#python3 nixpkgs#nodejs nixpkgs#gcc
```

### Rebuild the system after config changes
```bash
sudo nixos-rebuild switch --flake /etc/claude-os#claude-os
```

### Rollback to previous system generation
```bash
sudo nixos-rebuild switch --rollback
```

### List system generations
```bash
sudo nix-env --list-generations -p /nix/var/nix/profiles/system
```

### Garbage collect old packages
```bash
sudo nix-collect-garbage -d
```

## When to use
- ANY time a tool or package is needed — nix is always the answer
- User needs a development environment
- System configuration needs to change
- Need to rollback a broken change

## Gotchas
- `nix shell` is ephemeral — the package disappears when the shell exits
- For persistent installs, add to `user-packages.nix` and rebuild
- Use `--impure` flag if a flake needs to access system state
- CUDA packages require `allowUnfree = true` (already configured)
- Binary caches speed up builds — first build of uncached packages can be slow
