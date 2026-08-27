#!/bin/bash
# Daily backup of everything that can't be regenerated:
# API keys, customer files + RAG indexes, gateway code, UI, scripts.
# Keeps 14 days of archives in /workspace/backups.
set -u
DEST=/workspace/backups
mkdir -p "$DEST"
STAMP=$(date -u +%Y-%m-%d)
# dump the key database (restorable with: mysql avaniko < avaniko_db.sql)
mysqldump avaniko > /workspace/gateway/avaniko_db.sql 2>/dev/null
tar -czf "$DEST/avaniko_$STAMP.tar.gz" \
  -C /workspace \
  gateway/avaniko_db.sql gateway/.mysql_env gateway/.api_key gateway/main.py gateway/start.sh \
  gateway/static gateway/files \
  embed_server.py start_all.sh backup.sh API_GUIDE.md 2>/dev/null
# prune archives older than 14 days
find "$DEST" -name "avaniko_*.tar.gz" -mtime +14 -delete
echo "$(date -u) backup done: $DEST/avaniko_$STAMP.tar.gz ($(du -h "$DEST/avaniko_$STAMP.tar.gz" | cut -f1))"
