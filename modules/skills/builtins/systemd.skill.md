---
package: systemd
version: "255"
capabilities: [service-management, init-system, logging, scheduling]
requires: []
---

# systemd

## What it does
System and service manager for Linux. Manages all services, timers, and system state in Claude-OS.

## Common tasks

### Check service status
```bash
systemctl status <service>
```

### Start/stop/restart a service
```bash
sudo systemctl start <service>
sudo systemctl stop <service>
sudo systemctl restart <service>
```

### Enable service to start on boot
```bash
sudo systemctl enable <service>
```

### View logs for a service
```bash
journalctl -u <service> -f          # follow live
journalctl -u <service> --since "1h ago"
journalctl -u <service> -n 50       # last 50 lines
```

### List all running services
```bash
systemctl list-units --type=service --state=running
```

### List failed services
```bash
systemctl --failed
```

### Create a one-shot timer (scheduled task)
```bash
systemd-run --on-calendar="*-*-* 03:00:00" /path/to/script
```

## When to use
- Managing background services (web servers, databases, agents)
- Scheduling recurring tasks
- Debugging why something isn't running
- Checking system logs

## Gotchas
- On NixOS, services are defined in nix config — `systemctl enable` alone won't persist across rebuilds
- For persistent services, add them to the NixOS configuration
- Use `journalctl -xe` for detailed error context
- The master agent runs as `claude-os-master.service`
