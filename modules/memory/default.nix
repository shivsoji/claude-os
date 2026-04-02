{ config, pkgs, lib, ... }:

let
  # The memory graph CLI — Claude's interface to persistent memory
  memoryGraph = pkgs.writeShellScriptBin "claude-os-memory" (builtins.readFile ./memory-graph.sh);

  # Schema initialization script
  schemaSQL = ./schema.sql;

in
{
  environment.systemPackages = [ memoryGraph ];

  # Initialize the graph database on boot
  systemd.services.claude-os-memory-init = {
    description = "Initialize Claude-OS Memory Graph";
    wantedBy = [ "multi-user.target" ];
    after = [ "claude-os-bootstrap.service" ];
    before = [ "claude-os-master.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "claude";
      Group = "users";
    };
    path = [ pkgs.sqlite ];
    script = ''
      DB="/var/lib/claude-os/memory/graph.sqlite"
      mkdir -p /var/lib/claude-os/memory

      # Initialize schema if DB doesn't exist or is empty
      if [ ! -f "$DB" ] || [ ! -s "$DB" ]; then
        sqlite3 "$DB" < ${schemaSQL}
        echo "Memory graph initialized"
      else
        # Run migrations (idempotent — CREATE IF NOT EXISTS)
        sqlite3 "$DB" < ${schemaSQL}
        echo "Memory graph schema updated"
      fi

      # Seed system identity entity if first boot
      count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM entities WHERE type='system';")
      if [ "$count" -eq 0 ]; then
        sqlite3 "$DB" "INSERT INTO entities (type, name, content, tags) VALUES
          ('system', 'identity', 'I am Claude-OS, a self-evolving AI operating system built on NixOS.', 'core,identity'),
          ('system', 'architecture', 'NixOS base, systemd init, master/shell agent model, genome-based evolution.', 'core,architecture'),
          ('system', 'capabilities', 'Shell, networking, SSH, file management, version control, text editing, JSON processing.', 'core,capabilities');"

        # Relate them
        sqlite3 "$DB" "INSERT INTO relations (src_id, dst_id, rel_type, weight) VALUES
          (1, 2, 'has', 1.0),
          (1, 3, 'has', 1.0),
          (2, 3, 'enables', 0.8);"

        echo "Memory graph seeded with system identity"
      fi
    '';
  };

  # Periodic memory maintenance (decay, compaction)
  systemd.services.claude-os-memory-maintenance = {
    description = "Claude-OS Memory Maintenance";
    serviceConfig = {
      Type = "oneshot";
      User = "claude";
      Group = "users";
    };
    path = [ pkgs.sqlite ];
    script = ''
      DB="/var/lib/claude-os/memory/graph.sqlite"
      [ -f "$DB" ] || exit 0

      # Apply decay: reduce scores of unaccessed memories
      sqlite3 "$DB" "
        UPDATE entities SET
          decay_score = decay_score * 0.95
        WHERE last_accessed < datetime('now', '-1 day')
          AND type NOT IN ('system', 'core');
      "

      # Auto-summarize: entities accessed many times get a summary
      # (placeholder — full summarization would use Claude)
      sqlite3 "$DB" "
        INSERT OR IGNORE INTO summaries (entity_id, level, summary)
        SELECT id, 1, substr(content, 1, 200) || '...'
        FROM entities
        WHERE access_count > 10
          AND id NOT IN (SELECT entity_id FROM summaries WHERE level = 1)
          AND length(content) > 200;
      "

      # Compact: remove very low-decay entities (forgotten memories)
      sqlite3 "$DB" "
        DELETE FROM entities
        WHERE decay_score < 0.01
          AND type NOT IN ('system', 'core', 'user_pref')
          AND last_accessed < datetime('now', '-30 days');
      "

      echo "Memory maintenance complete"
    '';
  };

  # Run maintenance daily
  systemd.timers.claude-os-memory-maintenance = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
