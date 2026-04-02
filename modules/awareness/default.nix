{ config, pkgs, lib, ... }:

let
  # The nerve center — unified signal aggregator + health guardian + agent coordinator
  awarenessEngine = pkgs.writeShellScriptBin "claude-os-awareness" (builtins.readFile ./awareness-engine.sh);

  # CLI for querying live system state
  awarenessQuery = pkgs.writeShellScriptBin "claude-os-sense" (builtins.readFile ./sense.sh);

  # Health guardian — autonomous self-healing
  healthGuardian = pkgs.writeShellScriptBin "claude-os-health" (builtins.readFile ./health-guardian.sh);

  # Agent coordinator
  agentCoordinator = pkgs.writeShellScriptBin "claude-os-agents" (builtins.readFile ./agent-coordinator.sh);

in
{
  environment.systemPackages = [
    awarenessEngine
    awarenessQuery
    healthGuardian
    agentCoordinator
  ];

  # ============================================
  # Awareness engine — the nervous system daemon
  # Runs alongside master, feeds it signals
  # ============================================
  systemd.services.claude-os-awareness = {
    description = "Claude-OS Awareness Engine";
    wantedBy = [ "multi-user.target" ];
    after = [ "claude-os-bootstrap.service" "claude-os-master.service" ];
    wants = [ "claude-os-master.service" ];

    serviceConfig = {
      Type = "simple";
      User = "claude";
      Group = "users";
      Restart = "always";
      RestartSec = 5;
      ExecStart = "${awarenessEngine}/bin/claude-os-awareness";
      StandardOutput = "journal";
      StandardError = "journal";
      ProtectSystem = "no";
    };
  };

  # ============================================
  # Health guardian — periodic self-healing
  # ============================================
  systemd.services.claude-os-health = {
    description = "Claude-OS Health Guardian";
    serviceConfig = {
      Type = "oneshot";
      User = "root"; # Needs root for service restarts and process management
    };
    path = with pkgs; [ systemd procps coreutils jq util-linux ];
    script = ''
      exec ${healthGuardian}/bin/claude-os-health check-and-heal
    '';
  };

  systemd.timers.claude-os-health = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "60s";
      OnUnitActiveSec = "30s"; # Every 30 seconds
      AccuracySec = "5s";
    };
  };
}
