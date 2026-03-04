#!/bin/bash
set -euo pipefail

# Provision schema + indexes + seed data for the Resident Directory app.
# This script is intended to be idempotent and safe to run on every container start.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -f "db_connection.txt" ]; then
  echo "ERROR: db_connection.txt not found. Cannot determine PostgreSQL connection string."
  exit 1
fi

DB_CONN_CMD="$(cat db_connection.txt)"
# db_connection.txt contains something like:
#   psql postgresql://user:pass@host:port/db
# We'll reuse that as the base command and append -c statements.
PSQL="${DB_CONN_CMD}"

echo "Running provisioning using: ${DB_CONN_CMD}"

# ---- Extensions (for search indexes) ----
# pg_trgm supports fast ILIKE / similarity search via trigram GIN indexes.
${PSQL} -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"

# ---- Tables ----
# admin_users: store admin identity and password hash (hashing handled by backend).
${PSQL} -c "
CREATE TABLE IF NOT EXISTS admin_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  full_name TEXT,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"

# residents: core resident directory table.
# unit_number is unique (one resident per unit in this simplified model).
${PSQL} -c "
CREATE TABLE IF NOT EXISTS residents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  unit_number TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT residents_unit_unique UNIQUE (unit_number)
);
"

# ---- Indexes ----
# Fast lookup by unit and filtering by status.
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_residents_unit_number ON residents (unit_number);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_residents_status ON residents (status);"

# Search indexes (trigram) for name/email/phone searches.
# Note: gin_trgm_ops supports fast ILIKE on lowercased text.
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_residents_name_trgm ON residents USING GIN ((lower(first_name || ' ' || last_name)) gin_trgm_ops);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_residents_email_trgm ON residents USING GIN (lower(email) gin_trgm_ops);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_residents_phone_trgm ON residents USING GIN (phone gin_trgm_ops);"

# ---- Seed data (dev only) ----
# Seed is idempotent via ON CONFLICT DO NOTHING.
# IMPORTANT: password_hash is a placeholder for local dev; backend should replace with real hashing.
${PSQL} -c "
INSERT INTO admin_users (email, password_hash, full_name, is_active)
VALUES ('admin@example.com', 'dev_only__password_hash_replace_me', 'Default Admin', TRUE)
ON CONFLICT (email) DO NOTHING;
"

${PSQL} -c "
INSERT INTO residents (first_name, last_name, unit_number, email, phone, status, notes)
VALUES ('Alex','Johnson','101','alex.johnson@example.com','555-0101','active','Prefers email contact')
ON CONFLICT (unit_number) DO NOTHING;
"

${PSQL} -c "
INSERT INTO residents (first_name, last_name, unit_number, email, phone, status, notes)
VALUES ('Maria','Santos','102','maria.santos@example.com','555-0102','active','Emergency contact on file')
ON CONFLICT (unit_number) DO NOTHING;
"

${PSQL} -c "
INSERT INTO residents (first_name, last_name, unit_number, email, phone, status, notes)
VALUES ('Priya','Patel','203','priya.patel@example.com','555-0203','inactive','Moved out')
ON CONFLICT (unit_number) DO NOTHING;
"

${PSQL} -c "
INSERT INTO residents (first_name, last_name, unit_number, email, phone, status, notes)
VALUES ('Sam','Lee','305',NULL,'555-0305','active',NULL)
ON CONFLICT (unit_number) DO NOTHING;
"

echo "Provisioning complete."
