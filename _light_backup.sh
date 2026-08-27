#!/bin/bash
source /workspace/.s3_env
B="s3://$S3_BUCKET/$S3_PREFIX"
mkdir -p /workspace/logs
echo "[$(date -u +%FT%TZ)] START light backup"
mysqldump avaniko > /workspace/gateway/avaniko_db.sql 2>/dev/null && echo "  db dumped"

# browsable dirs (small — no venv/model walk)
aws s3 sync /workspace/gateway/app     "$B/gateway/app"     --no-progress
aws s3 sync /workspace/gateway/static  "$B/gateway/static"  --no-progress
aws s3 sync /workspace/mysql           "$B/mysql"           --no-progress
aws s3 sync /workspace/backups         "$B/backups"         --no-progress

# loose files (code, scripts, docs, configs, keys)
FILES="gateway/main.py gateway/start.sh gateway/avaniko_db.sql \
gateway/.api_key gateway/.mysql_env gateway/keys.json.migrated \
embed_server.py ocr_server.py start_all.sh backup.sh push_to_s3.sh \
push_workspace_s3.sh setup.sh db_setup.sql .env .gitignore \
OFFICE_PROJECT_KEY.txt API_GUIDE.md DOCUMENTATION.md RUNPOD_DEPLOYMENT.md \
TOKEN_LIMIT_SOLUTION.md AVANIKO_FULL_REPORT.md AVANIKO_PROJECT_REPORT_TAMIL.md \
Avaniko_AI_Platform_Report.md Avaniko_Session_Report.md current.md README.md"
for f in $FILES; do
  [ -f "/workspace/$f" ] && aws s3 cp "/workspace/$f" "$B/$f" --no-progress
done

echo "[$(date -u +%FT%TZ)] DONE light backup"
