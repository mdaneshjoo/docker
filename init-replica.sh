#!/bin/bash
set -e

KEYFILE_PATH="/data/mongo-keyfile"

# Generate MongoDB keyfile if it doesn't exist
if [ ! -f "$KEYFILE_PATH" ]; then
    echo "Generating MongoDB keyfile..."
    openssl rand -base64 756 > "$KEYFILE_PATH"
    chmod 400 "$KEYFILE_PATH"
    chown mongodb:mongodb "$KEYFILE_PATH"
    echo "MongoDB keyfile generated successfully at $KEYFILE_PATH"
else
    echo "MongoDB keyfile already exists at $KEYFILE_PATH"
    # Ensure proper permissions even if file exists
    chmod 400 "$KEYFILE_PATH"
    chown mongodb:mongodb "$KEYFILE_PATH"
fi

ROOT_USER="emdjoo"
ROOT_PASSWORD="${MONGO_INITDB_ROOT_PASSWORD:-}"
if [ -z "$ROOT_USER" ] || [ -z "$ROOT_PASSWORD" ]; then
    echo "MONGO_INITDB_ROOT_USERNAME and MONGO_INITDB_ROOT_PASSWORD must be set"
    exit 1
fi

# Build args without keyFile/auth for initial unsecured startup
FILTERED_ARGS=""
skip_next=0
for arg in "$@"; do
  if [ "$skip_next" -eq 1 ]; then
    skip_next=0
    continue
  fi
  case "$arg" in
    --keyFile)
      skip_next=1
      ;;
    --keyFile=*)
      ;;
    --auth)
      ;;
    *)
      FILTERED_ARGS="$FILTERED_ARGS $arg"
      ;;
  esac
done

# Start mongod (without keyFile/auth) to perform first-time initialization
eval "$FILTERED_ARGS" &
MONGOD_PID=$!

# Wait for mongod to be ready
echo "Waiting for mongod to accept connections..."
for i in $(seq 1 60); do
  if mongosh --quiet --eval "db.adminCommand('ping').ok" | grep -q 1; then
    echo "mongod is up"
    break
  fi
  sleep 1
done

# Initiate replica set if needed
echo "Ensuring replica set is initiated..."
mongosh --quiet --eval "try { rs.status() } catch (e) { rs.initiate({_id:'rs0', members:[{_id:0, host:'localhost:27017'}]}) }"

# Wait for PRIMARY state
echo "Waiting for PRIMARY state..."
for i in $(seq 1 60); do
  STATE=$(mongosh --quiet --eval "try { rs.status().myState } catch (e) { print(0) }")
  if [ "$STATE" = "1" ]; then
    echo "Replica set PRIMARY ready"
    break
  fi
  sleep 1
done

# Create root user without calling usersInfo (works under localhost exception)
echo "Ensuring root user exists..."
mongosh admin --quiet --eval "try { db.createUser({user:'$ROOT_USER', pwd:'$ROOT_PASSWORD', roles:[{role:'root', db:'admin'}]}) } catch (e) { if (e.code === 11000 || e.codeName === 'DuplicateKey' || /already exists/i.test(e.message)) { print('Root user already exists'); } else { throw e } }"

# Shutdown mongod to restart with --auth
echo "Restarting mongod with --auth..."
mongosh admin --quiet --eval "db.shutdownServer()" || true
wait $MONGOD_PID || true

# Start final mongod with authentication enabled
exec "$@" --auth

