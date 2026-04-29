#!/usr/bin/env bash
set -euo pipefail

MASTER_FILE=""
TARGET_FILE=""
RENAME_FROM=""
RENAME_TO=""
SKIP_CONTAINS=()

# ------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --master)
      MASTER_FILE="${2:-}"
      shift 2
      ;;
    --target)
      TARGET_FILE="${2:-}"
      shift 2
      ;;
    --rename-from)
      RENAME_FROM="${2:-}"
      shift 2
      ;;
    --rename-to)
      RENAME_TO="${2:-}"
      shift 2
      ;;
    --skip-contains)
      SKIP_CONTAINS+=("${2:-}")
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  compare-schema-v2.sh --master master-schema.json --target target-schema.json [options]

Options:
  --rename-from TEXT       Replace this text in database names before comparison
  --rename-to TEXT         Replacement text for --rename-from
  --skip-contains TEXT     Skip any database whose name contains TEXT
                           Can be used multiple times
  -h, --help               Show help

Examples:
  ./compare-schema-v2.sh \
    --master master.json \
    --target target.json

  ./compare-schema-v2.sh \
    --master master.json \
    --target target.json \
    --rename-from "_ownName" \
    --rename-to "_alternativeName"

  ./compare-schema-v2.sh \
    --master master.json \
    --target target.json \
    --skip-contains "Dev" \
    --skip-contains "_Test"

Notes:
  - Only structure metadata is compared, never row data.
  - Rename is applied to BOTH master and target before comparison.
  - Skip rules are applied after rename normalization.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Use --help for usage."
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------
# Styling
# ------------------------------------------------------------
if [[ -t 1 ]]; then
  RED="$(printf '\033[31m')"
  GREEN="$(printf '\033[32m')"
  YELLOW="$(printf '\033[33m')"
  BLUE="$(printf '\033[34m')"
  BOLD="$(printf '\033[1m')"
  RESET="$(printf '\033[0m')"
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  BOLD=""
  RESET=""
fi

section() {
  echo
  echo "${BLUE}${BOLD}============================================================${RESET}"
  echo "${BLUE}${BOLD}$1${RESET}"
  echo "${BLUE}${BOLD}============================================================${RESET}"
}

ok() {
  echo "${GREEN}$1${RESET}"
}

warn() {
  echo "${YELLOW}$1${RESET}"
}

err() {
  echo "${RED}$1${RESET}"
}

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------
section "SCHEMA COMPARISON DISCLAIMER"
echo "This comparison uses ONLY schema structure metadata."
echo "No actual database row data or table content is read or compared."
echo "Only databases, tables, columns, data types, and indexes are checked."
echo

if [[ -z "$MASTER_FILE" || -z "$TARGET_FILE" ]]; then
  err "Usage: $0 --master master-schema.json --target target-schema.json [options]"
  exit 1
fi

if [[ ! -f "$MASTER_FILE" ]]; then
  err "Master file not found: $MASTER_FILE"
  exit 1
fi

if [[ ! -f "$TARGET_FILE" ]]; then
  err "Target file not found: $TARGET_FILE"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but not installed."
  exit 1
fi

if [[ -n "$RENAME_FROM" && -z "$RENAME_TO" ]]; then
  err "If --rename-from is used, --rename-to must also be provided."
  exit 1
fi

if [[ -z "$RENAME_FROM" && -n "$RENAME_TO" ]]; then
  err "If --rename-to is used, --rename-from must also be provided."
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ------------------------------------------------------------
# Build skip filter for jq
# ------------------------------------------------------------
SKIP_JSON="$(printf '%s\n' "${SKIP_CONTAINS[@]:-}" | jq -R . | jq -s .)"

# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------
section "VERIFICATION"

echo "Master file : $MASTER_FILE"
echo "Target file : $TARGET_FILE"
echo

echo "${BOLD}Master server details:${RESET}"
jq -r '
  [
    "  Requested instance : " + (.server.requested_server_instance // "n/a"),
    "  Detected server    : " + (.server.detected_server_name // "n/a"),
    "  Machine name       : " + (.server.machine_name // "n/a"),
    "  Instance name      : " + ((.server.instance_name // "") | if . == "" then "default" else . end),
    "  Edition            : " + (.server.edition // "n/a"),
    "  Product version    : " + (.server.product_version // "n/a"),
    "  Product level      : " + (.server.product_level // "n/a"),
    "  Extracted          : " + (.extracted // "n/a")
  ] | .[]
' "$MASTER_FILE"

echo
echo "${BOLD}Target server details:${RESET}"
jq -r '
  [
    "  Requested instance : " + (.server.requested_server_instance // "n/a"),
    "  Detected server    : " + (.server.detected_server_name // "n/a"),
    "  Machine name       : " + (.server.machine_name // "n/a"),
    "  Instance name      : " + ((.server.instance_name // "") | if . == "" then "default" else . end),
    "  Edition            : " + (.server.edition // "n/a"),
    "  Product version    : " + (.server.product_version // "n/a"),
    "  Product level      : " + (.server.product_level // "n/a"),
    "  Extracted          : " + (.extracted // "n/a")
  ] | .[]
' "$TARGET_FILE"

echo
echo "${BOLD}Normalization rules:${RESET}"
if [[ -n "$RENAME_FROM" ]]; then
  echo "  Database rename : '$RENAME_FROM' -> '$RENAME_TO'"
else
  echo "  Database rename : none"
fi

if [[ ${#SKIP_CONTAINS[@]} -gt 0 ]]; then
  echo "  Skip contains   :"
  for s in "${SKIP_CONTAINS[@]}"; do
    echo "    - $s"
  done
else
  echo "  Skip contains   : none"
fi

echo
echo "Comparison direction confirmation:"
echo "  Baseline / master : $MASTER_FILE"
echo "  Compared against  : $TARGET_FILE"

# ------------------------------------------------------------
# jq helpers
# ------------------------------------------------------------
build_db_list() {
  local input_file="$1"
  jq -r \
    --arg rename_from "$RENAME_FROM" \
    --arg rename_to "$RENAME_TO" \
    --argjson skip_contains "$SKIP_JSON" '
    def normalize_db:
      if $rename_from != "" then gsub($rename_from; $rename_to) else . end;

    def keep_db:
      . as $db
      | ($skip_contains | map($db | contains(.)) | any) | not;

    .databases[]
    | .name = (.name | normalize_db)
    | select(.name | keep_db)
    | .name
  ' "$input_file" | sort
}

build_table_list() {
  local input_file="$1"
  jq -r \
    --arg rename_from "$RENAME_FROM" \
    --arg rename_to "$RENAME_TO" \
    --argjson skip_contains "$SKIP_JSON" '
    def normalize_db:
      if $rename_from != "" then gsub($rename_from; $rename_to) else . end;

    def keep_db:
      . as $db
      | ($skip_contains | map($db | contains(.)) | any) | not;

    .databases[]
    | .name = (.name | normalize_db)
    | select(.name | keep_db)
    | . as $db
    | $db.tables[]
    | "\($db.name)|\(.schema)|\(.table)"
  ' "$input_file" | sort
}

build_column_list() {
  local input_file="$1"
  jq -r \
    --arg rename_from "$RENAME_FROM" \
    --arg rename_to "$RENAME_TO" \
    --argjson skip_contains "$SKIP_JSON" '
    def normalize_db:
      if $rename_from != "" then gsub($rename_from; $rename_to) else . end;

    def keep_db:
      . as $db
      | ($skip_contains | map($db | contains(.)) | any) | not;

    .databases[]
    | .name = (.name | normalize_db)
    | select(.name | keep_db)
    | . as $db
    | $db.tables[] as $t
    | $t.columns[]
    | [
        $db.name,
        $t.schema,
        $t.table,
        .column_id,
        .name,
        .data_type,
        .max_length,
        .precision,
        .scale,
        .is_nullable,
        .is_identity,
        .is_computed,
        (.default_definition // "")
      ] | @tsv
  ' "$input_file" | sort
}

build_index_list() {
  local input_file="$1"
  jq -r \
    --arg rename_from "$RENAME_FROM" \
    --arg rename_to "$RENAME_TO" \
    --argjson skip_contains "$SKIP_JSON" '
    def normalize_db:
      if $rename_from != "" then gsub($rename_from; $rename_to) else . end;

    def keep_db:
      . as $db
      | ($skip_contains | map($db | contains(.)) | any) | not;

    .databases[]
    | .name = (.name | normalize_db)
    | select(.name | keep_db)
    | . as $db
    | $db.tables[] as $t
    | $t.indexes[] as $ix
    | $ix.columns[] as $c
    | [
        $db.name,
        $t.schema,
        $t.table,
        $ix.index_name,
        $ix.index_type,
        $ix.is_primary_key,
        $ix.is_unique,
        $ix.is_unique_constraint,
        $c.name,
        $c.key_ordinal,
        $c.is_included_column
      ] | @tsv
  ' "$input_file" | sort
}

# ------------------------------------------------------------
# Prepare normalized data
# ------------------------------------------------------------
section "PREPARING NORMALIZED STRUCTURE DATA"

build_db_list "$MASTER_FILE"   > "$WORKDIR/master_databases.txt"
build_db_list "$TARGET_FILE"   > "$WORKDIR/target_databases.txt"

build_table_list "$MASTER_FILE" > "$WORKDIR/master_tables.txt"
build_table_list "$TARGET_FILE" > "$WORKDIR/target_tables.txt"

build_column_list "$MASTER_FILE" > "$WORKDIR/master_columns.txt"
build_column_list "$TARGET_FILE" > "$WORKDIR/target_columns.txt"

build_index_list "$MASTER_FILE" > "$WORKDIR/master_indexes.txt"
build_index_list "$TARGET_FILE" > "$WORKDIR/target_indexes.txt"

ok "Normalized comparison files prepared."

# ------------------------------------------------------------
# Produce diffs
# ------------------------------------------------------------
comm -23 "$WORKDIR/master_databases.txt" "$WORKDIR/target_databases.txt" > "$WORKDIR/db_only_in_master.txt" || true
comm -13 "$WORKDIR/master_databases.txt" "$WORKDIR/target_databases.txt" > "$WORKDIR/db_only_in_target.txt" || true

comm -23 "$WORKDIR/master_tables.txt" "$WORKDIR/target_tables.txt" > "$WORKDIR/tables_only_in_master.txt" || true
comm -13 "$WORKDIR/master_tables.txt" "$WORKDIR/target_tables.txt" > "$WORKDIR/tables_only_in_target.txt" || true

comm -23 "$WORKDIR/master_columns.txt" "$WORKDIR/target_columns.txt" > "$WORKDIR/columns_only_in_master.txt" || true
comm -13 "$WORKDIR/master_columns.txt" "$WORKDIR/target_columns.txt" > "$WORKDIR/columns_only_in_target.txt" || true

comm -23 "$WORKDIR/master_indexes.txt" "$WORKDIR/target_indexes.txt" > "$WORKDIR/indexes_only_in_master.txt" || true
comm -13 "$WORKDIR/master_indexes.txt" "$WORKDIR/target_indexes.txt" > "$WORKDIR/indexes_only_in_target.txt" || true

count_lines() {
  local file="$1"
  if [[ -s "$file" ]]; then
    wc -l < "$file" | tr -d ' '
  else
    echo "0"
  fi
}

DB_MASTER_COUNT="$(count_lines "$WORKDIR/db_only_in_master.txt")"
DB_TARGET_COUNT="$(count_lines "$WORKDIR/db_only_in_target.txt")"
TABLE_MASTER_COUNT="$(count_lines "$WORKDIR/tables_only_in_master.txt")"
TABLE_TARGET_COUNT="$(count_lines "$WORKDIR/tables_only_in_target.txt")"
COLUMN_MASTER_COUNT="$(count_lines "$WORKDIR/columns_only_in_master.txt")"
COLUMN_TARGET_COUNT="$(count_lines "$WORKDIR/columns_only_in_target.txt")"
INDEX_MASTER_COUNT="$(count_lines "$WORKDIR/indexes_only_in_master.txt")"
INDEX_TARGET_COUNT="$(count_lines "$WORKDIR/indexes_only_in_target.txt")"

TOTAL_DIFFS=$((DB_MASTER_COUNT + DB_TARGET_COUNT + TABLE_MASTER_COUNT + TABLE_TARGET_COUNT + COLUMN_MASTER_COUNT + COLUMN_TARGET_COUNT + INDEX_MASTER_COUNT + INDEX_TARGET_COUNT))

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
section "SUMMARY"

echo "Databases only in master : $DB_MASTER_COUNT"
echo "Databases only in target : $DB_TARGET_COUNT"
echo "Tables only in master    : $TABLE_MASTER_COUNT"
echo "Tables only in target    : $TABLE_TARGET_COUNT"
echo "Columns only in master   : $COLUMN_MASTER_COUNT"
echo "Columns only in target   : $COLUMN_TARGET_COUNT"
echo "Indexes only in master   : $INDEX_MASTER_COUNT"
echo "Indexes only in target   : $INDEX_TARGET_COUNT"
echo

if [[ "$TOTAL_DIFFS" -eq 0 ]]; then
  ok "No structural differences found."
else
  warn "Structural differences found: $TOTAL_DIFFS"
fi

print_block() {
  local title="$1"
  local file="$2"
  local max_lines="${3:-50}"

  section "$title"

  if [[ ! -s "$file" ]]; then
    ok "None"
    return
  fi

  local line_count
  line_count="$(wc -l < "$file" | tr -d ' ')"

  echo "Count: $line_count"
  echo

  if [[ "$line_count" -le "$max_lines" ]]; then
    cat "$file"
  else
    head -n "$max_lines" "$file"
    echo
    warn "... output truncated, showing first $max_lines lines of $line_count ..."
  fi
}

print_block "DATABASES ONLY IN MASTER" "$WORKDIR/db_only_in_master.txt" 100
print_block "DATABASES ONLY IN TARGET" "$WORKDIR/db_only_in_target.txt" 100

print_block "TABLES ONLY IN MASTER" "$WORKDIR/tables_only_in_master.txt" 100
print_block "TABLES ONLY IN TARGET" "$WORKDIR/tables_only_in_target.txt" 100

print_block "COLUMNS ONLY IN MASTER OR CHANGED FROM TARGET" "$WORKDIR/columns_only_in_master.txt" 80
print_block "COLUMNS ONLY IN TARGET OR CHANGED FROM MASTER" "$WORKDIR/columns_only_in_target.txt" 80

print_block "INDEXES ONLY IN MASTER OR CHANGED FROM TARGET" "$WORKDIR/indexes_only_in_master.txt" 80
print_block "INDEXES ONLY IN TARGET OR CHANGED FROM MASTER" "$WORKDIR/indexes_only_in_target.txt" 80

section "COMPARISON COMPLETE"

if [[ "$TOTAL_DIFFS" -eq 0 ]]; then
  ok "Master and target match on compared schema structure."
else
  warn "Differences were found between master and target schema structure."
fi

echo "Reminder: only structure metadata was compared, not actual data."
