#!/usr/bin/env bash
# Apply the copied Atlas migration set to the LOCAL Supabase stack.
#
# Why not `supabase start`/`db reset`: Atlas's migration history is not
# reproducible from the repo. Two independent failure classes abort an atomic run:
#   1. bare `SELECT cron.unschedule('job')` for jobs created out-of-band in the
#      hosted project (handled by 00000000000001_local_bootstrap.sql)
#   2. duplicate object creation — e.g. two migrations both CREATE TABLE
#      atlas_import_profiles, which the hosted DB never hit in this order
# Applying per-file with ON_ERROR_STOP=0 lets each statement stand or fall on its
# own, so a duplicate-object error skips one statement instead of killing the run.
# Every error is logged and classified so nothing is silently swallowed.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DBC="supabase_db_supabase-local"
SRC="$HELIX_ROOT/.supabase-local/pending"
LOG="$LOGDIR/supabase-apply.log"
mkdir -p "$LOGDIR"; : > "$LOG"

docker ps --format '{{.Names}}' | grep -qx "$DBC" || { bad "$DBC not running"; exit 1; }

total=0; clean=0; witherr=0
for f in $(ls "$SRC"/*.sql | sort); do
  total=$((total+1))
  err="$(docker exec -i "$DBC" psql -U postgres -d postgres -v ON_ERROR_STOP=0 -q -f - < "$f" 2>&1 | grep -E "ERROR:|FATAL:" || true)"
  if [ -z "$err" ]; then
    clean=$((clean+1))
  else
    witherr=$((witherr+1))
    { echo "### $(basename "$f")"; echo "$err"; echo; } >> "$LOG"
  fi
  [ $((total % 50)) -eq 0 ] && printf '  ... %s/%s applied\n' "$total" "$(ls "$SRC"/*.sql | wc -l)"
done

echo
ok "applied $total files: $clean clean, $witherr with at least one statement error"
say "full error log: $LOG"
echo
head1 "Error classes"
grep -oE "ERROR:.*" "$LOG" 2>/dev/null \
  | sed -E 's/^ERROR:  //; s/"[^"]*"/"X"/g; s/[0-9]+/N/g' \
  | sort | uniq -c | sort -rn | head -20

# --- restore Supabase's API-role grants -------------------------------------
# Applying migrations as `postgres` creates tables WITHOUT the privileges
# PostgREST's roles need, so every Atlas server read fails with
# 42501 "permission denied for table ...". Must run after the tables exist.
head1 "Granting API-role privileges"
if docker exec -i "$DBC" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q -f - < "$HELIX_ROOT/.supabase-local/grants.sql" 2>/dev/null; then
  ok "anon / authenticated / service_role granted on public"
else
  bad "grant step failed — Atlas reads will 42501"
fi

# --- silence the cron jobs the migrations (re)created ------------------------
# The migrations schedule pg_cron jobs whose bodies net.http_post to PRODUCTION
# Lovable endpoints — several every 1-2 minutes. Harmless to the local schema but
# it means a local database firing real outbound traffic at prod, so unschedule
# them. The schema keeps the job definitions' effect on tables; only the timers go.
head1 "Disabling cron jobs (they POST to production endpoints)"
docker exec -i "$DBC" psql -U postgres -d postgres -tA -c \
  "do \$\$ declare r record; begin for r in select jobname from cron.job loop perform cron.unschedule(r.jobname); end loop; end \$\$;" >/dev/null 2>&1
LEFT="$(docker exec -i "$DBC" psql -U postgres -d postgres -tA -c 'select count(*) from cron.job' 2>/dev/null | tr -d ' ')"
[ "$LEFT" = "0" ] && ok "all cron jobs unscheduled" || warn "$LEFT cron job(s) still scheduled"
