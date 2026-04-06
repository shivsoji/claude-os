{ config, pkgs, lib, ... }:

let
  # The memory graph CLI — Claude's interface to persistent memory
  memoryGraph = pkgs.writeShellScriptBin "claude-os-memory" (builtins.readFile ./memory-graph.sh);

  # Schema initialization script
  schemaSQL = ./schema.sql;

in
{
  environment.systemPackages = [
    memoryGraph
    pkgs.python3  # Required for embedding vector operations (struct pack/unpack)
  ];

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

  # Periodic memory maintenance (intelligent decay + compaction)
  systemd.services.claude-os-memory-maintenance = {
    description = "Claude-OS Memory Maintenance (Intelligent Decay)";
    serviceConfig = {
      Type = "oneshot";
      User = "claude";
      Group = "users";
    };
    path = [ pkgs.sqlite pkgs.curl pkgs.jq ];
    script = ''
      DB="/var/lib/claude-os/memory/graph.sqlite"
      [ -f "$DB" ] || exit 0

      # === 1. Compute importance scores from graph topology ===
      sqlite3 "$DB" "
        -- Recompute importance for all entities
        INSERT OR REPLACE INTO importance (entity_id, connection_count, in_degree, out_degree, hub_score, authority_score, importance, computed_at)
        SELECT
          e.id,
          COALESCE(c.total, 0),
          COALESCE(c.in_deg, 0),
          COALESCE(c.out_deg, 0),
          -- Hub score: entities with many outgoing relations
          CASE WHEN COALESCE(c.out_deg, 0) > 3 THEN 0.8
               WHEN COALESCE(c.out_deg, 0) > 1 THEN 0.5
               ELSE 0.2 END,
          -- Authority score: entities with many incoming relations
          CASE WHEN COALESCE(c.in_deg, 0) > 3 THEN 0.8
               WHEN COALESCE(c.in_deg, 0) > 1 THEN 0.5
               ELSE 0.2 END,
          -- Composite importance: type weight + connectivity + access frequency
          MIN(1.0,
            -- Type weight (system/user_pref are inherently important)
            CASE e.type
              WHEN 'system' THEN 0.9
              WHEN 'user_pref' THEN 0.8
              WHEN 'core' THEN 0.9
              WHEN 'skill' THEN 0.6
              WHEN 'tool_knowledge' THEN 0.5
              WHEN 'task_pattern' THEN 0.5
              WHEN 'fact' THEN 0.4
              WHEN 'episode' THEN 0.3
              WHEN 'goal' THEN 0.4
              ELSE 0.3
            END
            -- Connectivity bonus
            + COALESCE(c.total, 0) * 0.05
            -- Access frequency bonus (log scale)
            + MIN(0.2, ln(1 + e.access_count) * 0.05)
          ),
          datetime('now')
        FROM entities e
        LEFT JOIN (
          SELECT id,
            (SELECT COUNT(*) FROM relations WHERE src_id = id OR dst_id = id) as total,
            (SELECT COUNT(*) FROM relations WHERE dst_id = id) as in_deg,
            (SELECT COUNT(*) FROM relations WHERE src_id = id) as out_deg
          FROM entities
        ) c ON c.id = e.id;
      "

      # === 2. Intelligent decay: importance-weighted ===
      sqlite3 "$DB" "
        UPDATE entities SET
          decay_score = CASE
            -- Protected types never decay below 0.5
            WHEN type IN ('system', 'core') THEN MAX(0.5, decay_score)
            -- User preferences decay very slowly
            WHEN type IN ('user_pref') THEN MAX(0.3, decay_score * 0.99)
            -- Recently accessed: boost
            WHEN last_accessed > datetime('now', '-1 hour') THEN MIN(1.0, decay_score + 0.05)
            -- Importance-weighted decay: important nodes decay slower
            WHEN last_accessed > datetime('now', '-1 day') THEN
              decay_score * (0.95 + COALESCE((SELECT importance FROM importance WHERE entity_id = entities.id), 0.3) * 0.04)
            WHEN last_accessed > datetime('now', '-7 days') THEN
              decay_score * (0.90 + COALESCE((SELECT importance FROM importance WHERE entity_id = entities.id), 0.3) * 0.08)
            -- Old + unimportant: decay faster
            ELSE
              decay_score * (0.80 + COALESCE((SELECT importance FROM importance WHERE entity_id = entities.id), 0.3) * 0.15)
          END;
      "

      # === 3. Auto-summarize large entities ===
      sqlite3 "$DB" "
        INSERT OR IGNORE INTO summaries (entity_id, level, summary)
        SELECT id, 1, substr(content, 1, 200) || '...'
        FROM entities
        WHERE access_count > 5
          AND id NOT IN (SELECT entity_id FROM summaries WHERE level = 1)
          AND length(content) > 200;
      "

      # === 4. Compact: remove truly forgotten memories ===
      forgotten=$(sqlite3 "$DB" "
        SELECT COUNT(*) FROM entities
        WHERE decay_score < 0.01
          AND type NOT IN ('system', 'core', 'user_pref')
          AND last_accessed < datetime('now', '-30 days')
          AND id NOT IN (SELECT entity_id FROM importance WHERE importance > 0.5);
      ")
      sqlite3 "$DB" "
        DELETE FROM entities
        WHERE decay_score < 0.01
          AND type NOT IN ('system', 'core', 'user_pref')
          AND last_accessed < datetime('now', '-30 days')
          AND id NOT IN (SELECT entity_id FROM importance WHERE importance > 0.5);
      "

      echo "Maintenance complete: importance recomputed, decay applied, $forgotten entities forgotten"
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
