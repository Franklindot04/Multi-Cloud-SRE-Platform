#!/bin/sh
# Runs once, when the PostgreSQL data directory is first created (docker-entrypoint-initdb.d).
# Creates one login role and one database per service, as the cluster does in Kubernetes, and stops the
# roles from connecting to each other's database.
set -eu

create_service_database() {
  # $1 = role and database name, $2 = password
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -v role="$1" -v pw="$2" << 'SQL'
CREATE ROLE :"role" LOGIN PASSWORD :'pw';
CREATE DATABASE :"role" OWNER :"role";
REVOKE CONNECT ON DATABASE :"role" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"role" TO :"role";
SQL
}

create_service_database orders "$ORDERS_DB_PASSWORD"
create_service_database payments "$PAYMENTS_DB_PASSWORD"
