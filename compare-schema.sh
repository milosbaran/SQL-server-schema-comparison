#!/usr/bin/env bash
set -euo pipefail

MASTER_FILE=""
TARGET_FILE=""
RENAME_FROM=""
RENAME_TO=""
SKIP_CONTAINS=()

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
      RENAME_FROM="${2-}"
      RENAME_FROM_SET=1
      shift 2
      ;;
    --rename-to)
      RENAME_TO="${2-}"
      RENAME_TO_SET=1
      shift 2
      ;;
    --skip-contains)
      SKIP_CONTAINS+=("${2:-}")
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  compare-schema.sh --master master-schema.json --target target-schema.json [options]

Options:
  --rename-from TEXT       Replace this text in database names before comparison
  --rename-to TEXT         Replacement text for --rename-from
  --skip-contains TEXT     Skip any database whose name contains TEXT
                           Can be used multiple times
  -h, --help               Show help

Examples:
  ./compare-schema.sh \
    --master spain-schema.json \
    --target uk-schema.json

  ./compare-schema.sh \
    --master spain-schema.json \
    --target uk-schema.json \
    --rename-from "Enveseur_" \
    --rename-to ""

  ./compare-schema.sh \
    --master spain-schema.json \
    --target uk-schema.json \
    --skip-contains "Dev"
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

RENAME_FROM_SET=0
RENAME_TO_SET=0

if [[ $RENAME_FROM_SET -eq 1 && $RENAME_TO_SET -eq 0 ]]; then
  err "If --rename-from is used, --rename-to must also be provided."
  exit 1
fi

if [[ $RENAME_FROM_SET -eq 0 && $RENAME_TO_SET -eq 1 ]]; then
  err "If --rename-to is used, --rename-from must also be provided."
  exit 1
fi

OUTPUT_DIR="./compare-output"
mkdir -p "$OUTPUT_DIR"
WORKDIR="$OUTPUT_DIR"

if [[ ${#SKIP_CONTAINS[@]} -eq 0 ]]; then
  SKIP_JSON='[]'
else
  SKIP_JSON="$(printf '%s\n' "${SKIP_CONTAINS[@]}" | jq -R . | jq -s .)"
fi

section "VERIFICATION"

echo "Master file : $MASTER_FILE"
echo "Target file : $TARGET_FILE"
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
      | ([ $skip_contains[] | select(. != "") | . as $pat | ($db | contains($pat)) ] | any) | not;

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
      | ([ $skip_contains[] | select(. != "") | . as $pat | ($db | contains($pat)) ] | any) | not;

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
      | ([ $skip_contains[] | select(. != "") | . as $pat | ($db | contains($pat)) ] | any) | not;

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
      | ([ $skip_contains[] | select(. != "") | . as $pat | ($db | contains($pat)) ] | any) | not;

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

section "PREPARING NORMALIZED STRUCTURE DATA"

build_db_list "$MASTER_FILE" > "$WORKDIR/master_databases.txt"
build_db_list "$TARGET_FILE" > "$WORKDIR/target_databases.txt"

build_table_list "$MASTER_FILE" > "$WORKDIR/master_tables.txt"
build_table_list "$TARGET_FILE" > "$WORKDIR/target_tables.txt"

build_column_list "$MASTER_FILE" > "$WORKDIR/master_columns.txt"
build_column_list "$TARGET_FILE" > "$WORKDIR/target_columns.txt"

build_index_list "$MASTER_FILE" > "$WORKDIR/master_indexes.txt"
build_index_list "$TARGET_FILE" > "$WORKDIR/target_indexes.txt"

ok "Normalized comparison files prepared."

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
