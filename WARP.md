# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Repository Overview

This is a Docker Compose infrastructure repository that manages development services including PostgreSQL, Redis, MongoDB (with replica set), Kafka ecosystem, LocalStack, Typesense, ClamAV, and Traefik reverse proxy. Services are organized using Docker Compose profiles for flexible service management.

## Architecture

### Service Profiles System
Services are grouped into profiles that can be started independently or together:
- **all**: Starts all services
- **essential**: Core services (Postgres, Redis, MongoDB replica)
- **promom**: Prometheus monitoring stack services (Postgres, Redis)
- **dopin**: Application-specific services (MongoDB replica, ClamAV)
- **kafka**: Kafka ecosystem (Zookeeper, Kafka, Schema Registry)
- **localstack**: AWS service emulation
- **typesense**: Search engine with dashboard

### Network Configuration
- Most services use `shared-network` (external network that must exist)
- Some essential services use `host` networking mode (Postgres, Redis)
- Network must be created before starting services: `docker network create shared-network`

### MongoDB Replica Set
MongoDB is configured as a replica set (`rs0`) with authentication enabled. The initialization process is managed by `init-replica.sh`:
1. Generates keyfile for replica set authentication
2. Starts MongoDB without auth for initial setup
3. Initiates replica set
4. Creates root user
5. Restarts with authentication enabled

### Traefik Reverse Proxy
Located in `traefik/` subdirectory with its own compose file. Configured with:
- HTTP (80) and HTTPS (443) entry points
- Let's Encrypt SSL certificates via ACME
- Custom local plugins: API key authentication and memcached caching
- Dynamic configuration via `dynamic.yml`
- Dashboard accessible on port 8080

### Service Volumes
Persistent data stored in local directories:
- `postgres_data/`: PostgreSQL data
- `redis/`: Redis ACL configuration
- `mongo_data_replica/`: MongoDB replica set data
- `mongo_keyfile_data/`: MongoDB keyfile for replica authentication
- `typesense-data/`: Typesense search index
- `traefik/acme.json`: SSL certificates (must have 600 permissions)

## Common Commands

### Service Management
```bash
# Start all services
docker compose --profile all up -d

# Start essential services only
docker compose --profile essential up -d

# Start specific profile
docker compose --profile kafka up -d

# Start multiple profiles
docker compose --profile essential --profile kafka up -d

# Stop all services
docker compose --profile all down

# View running services
docker compose ps
```

### Network Setup
```bash
# Create required external network (must be done once)
docker network create shared-network

# Create traefik network (for traefik subdirectory)
docker network create traefik
```

### MongoDB Management
```bash
# Access MongoDB shell with authentication
docker exec -it mongo_replica mongosh -u emdjoo -p $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin

# Check replica set status
docker exec -it mongo_replica mongosh -u emdjoo -p $MONGO_INITDB_ROOT_PASSWORD --authenticationDatabase admin --eval "rs.status()"

# Force replica set reinitialization (if needed)
docker compose --profile essential down
rm -rf mongo_data_replica/* mongo_keyfile_data/*
docker compose --profile essential up -d mongo_replica
```

### Traefik Management
```bash
# Start Traefik (from traefik/ directory)
cd traefik
docker compose up -d

# View Traefik logs
docker logs traefik

# Access dashboard
open http://localhost:8080
```

### Image Cleanup
```bash
# Clean unused images (interactive with storage calculation)
./clean-unused-images.sh

# Clean with specific compose file
./clean-unused-images.sh docker-compose.yml

# Preserve specific images while cleaning
./clean-unused-images.sh --ignore "nginx:latest,redis:6"
```

### Viewing Logs
```bash
# Follow logs for specific service
docker compose logs -f postgres

# View logs for multiple services
docker compose logs redis mongo_replica

# View logs for all services in a profile
docker compose --profile essential logs
```

## Environment Configuration

Create `.env` file from `.env.example` with required credentials:
```bash
cp .env.example .env
# Edit .env with your values
```

Required environment variables:
- `POSTGRES_PASSWORD`: PostgreSQL root password
- `REDIS_PASSWORD`: Redis authentication password  
- `MONGO_INITDB_ROOT_PASSWORD`: MongoDB root password
- `TYPESENSE_API_KEY`: Typesense API key

### Redis ACL Configuration
Redis uses ACL file at `redis/acl.conf`:
- Default user is disabled
- Custom user `emdjoo` with full permissions
- Password managed via environment variable

### PostgreSQL Configuration
Custom `postgresql.conf` included (not currently mounted). Key settings:
- `listen_addresses = '*'`: Accept connections from all addresses
- `max_connections = 100`
- `shared_buffers = 128MB`

## Key Implementation Details

### MongoDB Replica Set Initialization
The `init-replica.sh` script handles complex initialization:
- Filters out `--keyFile` and `--auth` flags for initial startup
- Uses localhost exception to create admin user
- Waits for PRIMARY state before creating users
- Automatically restarts with authentication after setup

### Service Dependencies
- Kafka requires Zookeeper to be running
- Schema Registry depends on both Zookeeper and Kafka
- Traefik depends on Memcached for caching plugin
- Services have health checks where critical (MongoDB)

### Traefik Plugin System
Custom local plugins mounted from `traefik/plugins-local/`:
- `traefik-api-key-auth`: API key authentication middleware
- `memcachedplugin`: Response caching with Memcached backend

## Troubleshooting

### Services Won't Start
- Ensure `shared-network` exists: `docker network create shared-network`
- Check `.env` file is properly configured
- Verify port conflicts: `lsof -i :5432` (or relevant port)

### MongoDB Authentication Issues
- Ensure `MONGO_INITDB_ROOT_PASSWORD` is set in `.env`
- Check keyfile permissions: should be 400, owned by mongodb user
- View initialization logs: `docker logs mongo_replica`

### Traefik SSL Issues
- Ensure `acme.json` exists: `touch traefik/acme.json`
- Set correct permissions: `chmod 600 traefik/acme.json`
- Check Let's Encrypt rate limits if certificates fail

### Redis Connection Issues
- Verify ACL configuration in `redis/acl.conf`
- Password in `.env` must match ACL file
- Default user is intentionally disabled

## Port Reference

| Service | Port(s) | Description |
|---------|---------|-------------|
| PostgreSQL | 5432 | Database (host mode) |
| Redis | 6379 | Cache (host mode) |
| MongoDB | 27017 | Database with replica set |
| Kafka | 9092, 29092 | Message broker (internal, external) |
| Schema Registry | 8081 | Kafka schema registry |
| LocalStack | 4566, 4510-4559 | AWS service emulation |
| Typesense | 8108 | Search engine |
| Typesense Dashboard | 8109 | Search UI |
| ClamAV | 3310 | Antivirus scanner |
| Traefik | 80, 443, 8080 | Reverse proxy, dashboard |
| Memcached | 11211 | Cache for Traefik |
