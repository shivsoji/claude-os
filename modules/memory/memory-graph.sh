#!/usr/bin/env bash
# claude-os-memory — Memory graph with context window management
#
# Usage:
#   claude-os-memory remember <type> <name> <content> [--tags t1,t2]
#   claude-os-memory recall <query>                    — FTS5 search
#   claude-os-memory recall-id <id>                    — Get by ID
#   claude-os-memory forget <id>                       — Remove entity
#   claude-os-memory relate <src_id> <dst_id> <type> [weight]
#   claude-os-memory neighbors <id> [hops]             — Graph traversal
#   claude-os-memory context-load <session_id> [budget] — Load relevant context
#   claude-os-memory context-for <query> [budget]      — Context for a specific query
#   claude-os-memory summarize <id>                    — Get/create summary
#   claude-os-memory stats                             — Graph statistics
#   claude-os-memory types                             — List entity types
#   claude-os-memory recent [n]                        — Recent entities
#   claude-os-memory decay                             — Run decay pass
#   claude-os-memory export                            — Export graph as JSON

set -uo pipefail

STATE_DIR="${CLAUDE_OS_STATE:-/var/lib/claude-os}"
DB="$STATE_DIR/memory/graph.sqlite"
export PATH="/run/current-system/sw/bin:$PATH"

if [ ! -f "$DB" ]; then
  echo "Error: Memory graph not initialized. Wait for claude-os-memory-init service."
  exit 1
fi

# Helper: run SQL and return JSON results
sql() {
  sqlite3 -json "$DB" "$1" 2>/dev/null
}

sql_plain() {
  sqlite3 "$DB" "$1" 2>/dev/null
}

# Helper: safely escape a string for SQL (prevent injection)
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Helper: touch entity (update access time and count)
touch_entity() {
  sql_plain "UPDATE entities SET last_accessed = datetime('now'), access_count = access_count + 1, decay_score = MIN(1.0, decay_score + 0.1) WHERE id = $1;"
}

case "${1:-help}" in
  remember)
    shift
    type="${1:?Usage: claude-os-memory remember <type> <name> <content> [--tags t1,t2]}"
    name="${2:?Missing name}"
    content="${3:?Missing content}"
    shift 3
    tags=""
    session_id="${CLAUDE_OS_SESSION_ID:-unknown}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --tags) tags="$2"; shift 2 ;;
        --session) session_id="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    # All values properly escaped
    id=$(sql_plain "INSERT INTO entities (type, name, content, tags, session_id) VALUES ('$(sql_escape "$type")', '$(sql_escape "$name")', '$(sql_escape "$content")', '$(sql_escape "$tags")', '$(sql_escape "$session_id")') RETURNING id;")
    echo "Remembered: entity #$id ($type: $name)"
    echo "$id"
    ;;

  recall)
    shift
    query="${*:?Usage: claude-os-memory recall <query>}"
    escaped_query=$(sql_escape "$query")
    # FTS5 search with relevance scoring
    results=$(sql "
      SELECT e.id, e.type, e.name, substr(e.content, 1, 200) as content_preview,
             e.tags, e.access_count, round(e.decay_score, 2) as decay,
             round(rank, 4) as fts_rank
      FROM entities_fts fts
      JOIN entities e ON e.id = fts.rowid
      WHERE entities_fts MATCH '$escaped_query'
      ORDER BY (e.decay_score * -rank * (1 + ln(1 + e.access_count))) DESC
      LIMIT 20;
    ")

    # Touch accessed entities
    echo "$results" | jq -r '.[].id' 2>/dev/null | while read -r eid; do
      [ -n "$eid" ] && touch_entity "$eid"
    done

    if [ -z "$results" ] || [ "$results" = "[]" ]; then
      echo "No memories found for: $query"
    else
      echo "$results" | jq '.' 2>/dev/null || echo "$results"
    fi
    ;;

  recall-id)
    id="${2:?Usage: claude-os-memory recall-id <id>}"
    touch_entity "$id"
    sql "SELECT * FROM entities WHERE id = $id;"
    ;;

  forget)
    id="${2:?Usage: claude-os-memory forget <id>}"
    name=$(sql_plain "SELECT name FROM entities WHERE id = $id;")
    sql_plain "DELETE FROM entities WHERE id = $id;"
    echo "Forgotten: entity #$id ($name)"
    ;;

  relate)
    src="${2:?Usage: claude-os-memory relate <src_id> <dst_id> <rel_type> [weight]}"
    dst="${3:?Missing dst_id}"
    rel_type="${4:?Missing rel_type}"
    weight="${5:-1.0}"
    sql_plain "INSERT OR REPLACE INTO relations (src_id, dst_id, rel_type, weight) VALUES ($src, $dst, '$(sql_escape "$rel_type")', $weight);"
    echo "Related: #$src --[$rel_type ($weight)]--> #$dst"
    ;;

  neighbors)
    id="${2:?Usage: claude-os-memory neighbors <id> [hops]}"
    hops="${3:-1}"

    if [ "$hops" -eq 1 ]; then
      sql "
        SELECT e.id, e.type, e.name, r.rel_type, r.weight,
               substr(e.content, 1, 150) as content_preview
        FROM relations r
        JOIN entities e ON (e.id = r.dst_id OR e.id = r.src_id)
        WHERE (r.src_id = $id OR r.dst_id = $id) AND e.id != $id
        ORDER BY r.weight DESC;
      "
    else
      sql "
        WITH RECURSIVE traverse(entity_id, depth, path) AS (
          SELECT $id, 0, CAST($id AS TEXT)
          UNION ALL
          SELECT
            CASE WHEN r.src_id = t.entity_id THEN r.dst_id ELSE r.src_id END,
            t.depth + 1,
            t.path || ',' || CASE WHEN r.src_id = t.entity_id THEN r.dst_id ELSE r.src_id END
          FROM traverse t
          JOIN relations r ON (r.src_id = t.entity_id OR r.dst_id = t.entity_id)
          WHERE t.depth < $hops
            AND INSTR(t.path, CAST(CASE WHEN r.src_id = t.entity_id THEN r.dst_id ELSE r.src_id END AS TEXT)) = 0
        )
        SELECT DISTINCT e.id, e.type, e.name, t.depth as hops,
               substr(e.content, 1, 150) as preview,
               round(e.decay_score, 2) as decay
        FROM traverse t
        JOIN entities e ON e.id = t.entity_id
        WHERE e.id != $id
        ORDER BY t.depth, e.decay_score DESC;
      "
    fi
    ;;

  context-load)
    session_id="${2:?Usage: claude-os-memory context-load <session_id> [token_budget]}"
    budget="${3:-4000}"

    echo "Loading context for session $session_id (budget: $budget tokens)..."

    # Greedily pack entities into budget
    # Use process substitution to keep variables in scope
    total_tokens=0
    loaded=0

    while IFS='|' read -r id type name content tags relevance est_tokens; do
      [ -z "$id" ] && continue
      new_total=$((total_tokens + est_tokens))
      if [ "$new_total" -le "$budget" ]; then
        total_tokens=$new_total
        loaded=$((loaded + 1))

        # Use summary if available and entity is large
        if [ "$est_tokens" -gt 200 ]; then
          summary=$(sql_plain "SELECT summary FROM summaries WHERE entity_id = $id AND level = 1 LIMIT 1;")
          if [ -n "$summary" ]; then
            content="$summary"
          fi
        fi

        # Track in context window
        sql_plain "INSERT OR REPLACE INTO context_windows (session_id, entity_id, relevance, token_cost)
                   VALUES ('$(sql_escape "$session_id")', $id, $relevance, $est_tokens);"

        touch_entity "$id"

        # Output as structured context
        echo "## [$type] $name"
        echo "$content"
        echo ""
      fi
    done < <(sql_plain "
      SELECT id, type, name, content, tags,
             CAST((decay_score *
               (1.0 + ln(1 + access_count)) *
               (1.0 / (1.0 + (julianday('now') - julianday(last_accessed)))) *
               (1.0 + (SELECT COUNT(*) FROM relations WHERE src_id = entities.id OR dst_id = entities.id) * 0.1)
             ) AS REAL) as relevance,
             length(content) / 4 as est_tokens
      FROM entities
      WHERE decay_score > 0.05
      ORDER BY relevance DESC;
    ")

    echo "---"
    echo "Context loaded: $loaded entities, ~$total_tokens tokens"
    ;;

  context-for)
    shift
    query="${1:?Usage: claude-os-memory context-for <query> [token_budget]}"
    budget="${2:-4000}"
    escaped_query=$(sql_escape "$query")

    echo "# Relevant Memory Context"
    echo ""

    # FTS search + graph expansion
    while IFS='|' read -r id type name content; do
      [ -z "$id" ] && continue
      touch_entity "$id"
      echo "## [$type] $name"
      echo "$content"
      echo ""

      # Also show direct neighbors of each match
      while IFS='|' read -r nid ntype nname ncontent nrel; do
        [ -z "$nid" ] && continue
        echo "  -> [$nrel] [$ntype] $nname: $ncontent"
      done < <(sql_plain "
        SELECT e.id, e.type, e.name, substr(e.content, 1, 200), r.rel_type
        FROM relations r
        JOIN entities e ON (e.id = r.dst_id OR e.id = r.src_id)
        WHERE (r.src_id = $id OR r.dst_id = $id) AND e.id != $id
        ORDER BY r.weight DESC LIMIT 3;
      ")
      echo ""
    done < <(sql_plain "
      SELECT e.id, e.type, e.name, e.content
      FROM entities_fts fts
      JOIN entities e ON e.id = fts.rowid
      WHERE entities_fts MATCH '$escaped_query'
      ORDER BY (e.decay_score * -rank * (1 + ln(1 + e.access_count))) DESC
      LIMIT 10;
    ")
    ;;

  summarize)
    id="${2:?Usage: claude-os-memory summarize <id>}"
    existing=$(sql_plain "SELECT summary FROM summaries WHERE entity_id = $id AND level = 1;")
    if [ -n "$existing" ]; then
      echo "$existing"
    else
      content=$(sql_plain "SELECT content FROM entities WHERE id = $id;")
      if [ ${#content} -gt 200 ]; then
        summary="${content:0:200}..."
        sql_plain "INSERT INTO summaries (entity_id, level, summary) VALUES ($id, 1, '$(sql_escape "$summary")');"
        echo "$summary"
      else
        echo "$content"
      fi
    fi
    ;;

  stats)
    echo "=== Memory Graph Statistics ==="
    echo "Entities: $(sql_plain 'SELECT COUNT(*) FROM entities;')"
    echo "Relations: $(sql_plain 'SELECT COUNT(*) FROM relations;')"
    echo "Summaries: $(sql_plain 'SELECT COUNT(*) FROM summaries;')"
    echo "Sessions: $(sql_plain 'SELECT COUNT(*) FROM sessions;')"
    echo ""
    echo "By type:"
    while IFS='|' read -r type count; do
      [ -n "$type" ] && echo "  $type: $count"
    done < <(sql_plain "SELECT type, COUNT(*) as count FROM entities GROUP BY type ORDER BY count DESC;")
    echo ""
    echo "By relation:"
    while IFS='|' read -r rel count; do
      [ -n "$rel" ] && echo "  $rel: $count"
    done < <(sql_plain "SELECT rel_type, COUNT(*) as count FROM relations GROUP BY rel_type ORDER BY count DESC;")
    echo ""
    echo "Avg decay score: $(sql_plain 'SELECT round(avg(decay_score), 3) FROM entities;')"
    echo "Total accesses: $(sql_plain 'SELECT COALESCE(SUM(access_count),0) FROM entities;')"
    echo "DB size: $(du -h "$DB" 2>/dev/null | cut -f1)"
    ;;

  types)
    while IFS='|' read -r t count; do
      [ -n "$t" ] && echo "  $t ($count)"
    done < <(sql_plain "SELECT type, COUNT(*) FROM entities GROUP BY type ORDER BY type;")
    ;;

  recent)
    n="${2:-10}"
    sql "SELECT id, type, name, substr(content, 1, 100) as preview,
                created_at, access_count, round(decay_score, 2) as decay
         FROM entities ORDER BY created_at DESC LIMIT $n;"
    ;;

  decay)
    echo "Running decay pass..."
    sql_plain "
      UPDATE entities SET
        decay_score = CASE
          WHEN type IN ('system', 'core', 'user_pref') THEN decay_score
          WHEN last_accessed > datetime('now', '-1 hour') THEN MIN(1.0, decay_score + 0.05)
          WHEN last_accessed > datetime('now', '-1 day') THEN decay_score * 0.98
          WHEN last_accessed > datetime('now', '-7 days') THEN decay_score * 0.95
          ELSE decay_score * 0.90
        END;
    "
    forgotten=$(sql_plain "SELECT COUNT(*) FROM entities WHERE decay_score < 0.01 AND type NOT IN ('system','core','user_pref');")
    echo "Decay applied. ${forgotten:-0} entities below forget threshold."
    ;;

  export)
    echo "{"
    echo '  "entities":'
    sql "SELECT id, type, name, content, tags, created_at, access_count, decay_score FROM entities;"
    echo ','
    echo '  "relations":'
    sql "SELECT src_id, dst_id, rel_type, weight FROM relations;"
    echo "}"
    ;;

  help|*)
    echo "claude-os-memory — Memory graph with context management"
    echo ""
    echo "Store & retrieve:"
    echo "  remember <type> <name> <content> [--tags t1,t2]"
    echo "  recall <query>              FTS5 full-text search"
    echo "  recall-id <id>              Get entity by ID"
    echo "  forget <id>                 Remove an entity"
    echo ""
    echo "Graph:"
    echo "  relate <src> <dst> <type> [weight]   Create relation"
    echo "  neighbors <id> [hops]                Graph traversal (1-3 hops)"
    echo ""
    echo "Context management:"
    echo "  context-load <session> [budget]   Load relevant context (token budget)"
    echo "  context-for <query> [budget]      Context for a specific query"
    echo "  summarize <id>                    Get/create entity summary"
    echo "  decay                             Run memory decay"
    echo ""
    echo "Info:"
    echo "  stats       Graph statistics"
    echo "  types       List entity types"
    echo "  recent [n]  Recent entities"
    echo "  export      Export as JSON"
    echo ""
    echo "Entity types: system, user_pref, tool_knowledge, task_pattern, skill, fact, episode, goal"
    echo "Relation types: related_to, requires, part_of, supersedes, triggers, caused_by, learned_from"
    ;;
esac
