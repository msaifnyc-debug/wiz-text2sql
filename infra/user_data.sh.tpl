#!/usr/bin/env bash
# Bootstraps an INTENTIONALLY outdated MongoDB ${mongodb_version} with auth enabled,
# bound so the EKS cluster can reach it, plus a daily backup to the (public) bucket.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y gnupg curl unzip cron

# AWS CLI v2 (for the backup upload; uses the instance profile).
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install || true

# --- Install outdated MongoDB (the required weakness) -------------------------
curl -fsSL https://pgp.mongodb.com/server-${mongodb_version}.asc \
  | gpg -o /usr/share/keyrings/mongodb-server-${mongodb_version}.gpg --dearmor
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-${mongodb_version}.gpg ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/${mongodb_version} multiverse" \
  > /etc/apt/sources.list.d/mongodb-org-${mongodb_version}.list
apt-get update -y
apt-get install -y mongodb-org

# Bind to all interfaces (the SG, not the bind IP, restricts access to EKS) and
# require authentication (requirement: DB auth).
sed -i 's/^\( *bindIp:\).*/\1 0.0.0.0/' /etc/mongod.conf
if ! grep -q '^security:' /etc/mongod.conf; then
  printf '\nsecurity:\n  authorization: enabled\n' >> /etc/mongod.conf
fi

systemctl enable mongod
systemctl restart mongod

# Wait for mongod to accept connections.
for i in $(seq 1 30); do
  if mongosh --quiet --eval 'db.runCommand({ ping: 1 })' >/dev/null 2>&1; then break; fi
  sleep 2
done

# First user via the localhost exception, then the app user (authenticated).
mongosh --quiet <<EOF
use admin
db.createUser({ user: "admin", pwd: "${admin_password}", roles: [ { role: "root", db: "admin" } ] })
EOF

mongosh --quiet -u admin -p "${admin_password}" --authenticationDatabase admin <<EOF
use ${app_db}
db.createUser({ user: "appuser", pwd: "${app_password}", roles: [ { role: "readWrite", db: "${app_db}" } ] })
// Seed a row so "prove data is in the database" works immediately in the demo.
db.seed.insertOne({ note: "text2sql bootstrap", at: new Date() })
EOF

# --- Daily backup to the public bucket (required) -----------------------------
cat > /usr/local/bin/mongo-backup.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
TS=$(date -u +%Y%m%dT%H%M%SZ)
ARCHIVE="/tmp/mongo-$${TS}.archive.gz"
mongodump --username admin --password '${admin_password}' --authenticationDatabase admin \
  --archive="$${ARCHIVE}" --gzip
aws s3 cp "$${ARCHIVE}" "s3://${backup_bucket}/backups/mongo-$${TS}.archive.gz" --region ${region}
rm -f "$${ARCHIVE}"
SCRIPT
chmod +x /usr/local/bin/mongo-backup.sh

# Daily at 03:00 UTC + one immediate run so the public bucket has an object to show.
echo "0 3 * * * root /usr/local/bin/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1" \
  > /etc/cron.d/mongo-backup
systemctl restart cron
/usr/local/bin/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1 || true
