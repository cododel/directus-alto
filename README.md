![Directus Alto Framework Preview](docs/preview.jpeg)

# Directus Alto Framework Template

A comprehensive Directus CMS template designed to treat Directus not just as a content management system, but as a full-featured development framework. This template includes the powerful **Alto CLI** tool for streamlined development workflows, robust backup systems, and environment synchronization capabilities.

## 🚀 Features

### Alto CLI - Your Directus Development Companion
- **Database Management**: Flush, dump, and restore operations with intelligent backup naming
- **Direct Tool Access**: Seamless psql and Redis CLI integration
- **Directus Integration**: Built-in Directus CLI and directus-sync support with version detection
- **Docker Compose Passthrough**: Use alto as a drop-in replacement for docker-compose commands

### Production-Ready Infrastructure
- **Automated Backups**: Sophisticated backup system with retention policies and incremental uploads
- **Environment Sync**: Push/pull backups between development, staging, and production
- **Error Recovery**: Comprehensive error handling with diagnostic preservation
- **Monitoring**: Detailed logging and health checks

### Developer Experience
- **Quick Setup**: One-command environment initialization
- **Hot Reloading**: Development-optimized Docker configuration
- **Email Testing**: Integrated Mailpit for email development
- **Extension Support**: Ready-to-use extension mounting system
- **Fullstack Ready**: Easily extend to monorepo with frontend integration

## 🛠 Quick Start

### Prerequisites
- **Docker & Docker Compose**: Container orchestration  
- **Bash**: For alto CLI functionality
- **Bun** (optional): Required only for `directus-sync` functionality

### 1. Clone and Setup
```bash
# Use this template or clone
git clone <your-repo> my-directus-project
cd my-directus-project

# Copy environment configuration
cp example.env .env

# Edit your environment variables
nano .env  # Configure DB credentials, admin settings, etc.
```

### 2. Launch with Alto
```bash
# Make alto executable
chmod +x alto

# Start the entire stack
./alto up -d

# Check status
./alto ps
```

### 3. Initialize Directus
```bash
# Create initial admin user and setup
./alto directus bootstrap

# Initialize directus-sync for schema management
./alto init-directus-sync
```

Your Directus instance will be available at `http://localhost:8055`

## 📋 Alto CLI Reference

Alto is your primary interface for managing the Directus development environment.

### Database Operations
```bash
# Flush database (reset schema)
./alto db-flush

# Create database backup
./alto db-dump                    # Creates: {timestamp}_backup.sql (default name)
./alto db-dump my-feature-backup  # Creates: {timestamp}_my-feature-backup.sql

# Restore from backup
./alto db-restore                 # Restores latest backup by file modification time
./alto db-restore my-feature      # Finds backup containing "my-feature" in name
./alto db-restore /path/to/backup.sql  # Restores specific backup file
```

**Database Backup Details:**
- **File Format**: All backups are saved as `.sql` files with automatic timestamp prefix
- **Naming**: `{YYYYMMDD_HHMMSS}_{name}.sql` (e.g., `20240115_143000_my-backup.sql`)
- **Location**: `./directus/data/.alto/backups/` directory
- **Default Name**: If no name provided, uses "backup" as the default name

**Database Restore Logic:**
- **Without arguments**: Automatically finds and restores the most recent backup by file modification time (not filename date)
- **With name**: Searches for backups containing the specified name (partial match), selects latest by modification time if multiple found
- **With full path**: Restores the exact backup file specified
- **Safety**: Always flushes database first, requires confirmation before proceeding

**Note**: "Latest" backup is determined by file modification time, not by the timestamp in the filename. This means if backup files are copied or moved, their modification time may differ from the creation date in the filename.

### Direct Tool Access
```bash
# PostgreSQL CLI
./alto psql
./alto psql -c "\l"

# Redis CLI (if enabled)
./alto redis
./alto redis PING
```

### Directus Management
```bash
# Directus CLI (with version detection)
./alto directus users create --email admin@example.com --password password --role administrator
./alto d users list  # 'd' is an alias for 'directus'

# Schema and data synchronization
# Note: `alto` automatically detects your Directus version and uses the compatible
# version of `directus-sync` (v2 for Directus 10, v3 for Directus 11+).
./alto directus-sync pull all
./alto ds push collections  # 'ds' is an alias for 'directus-sync'
```

### Docker Compose Passthrough
```bash
# All unrecognized commands pass through to docker-compose
./alto up -d
./alto down
./alto logs -f directus
./alto exec directus bash
```

## 💾 Backup System

### Automated Backups
```bash
# Create backup with default settings
./backup.sh

# Custom backup location
./backup.sh /path/to/backups

# With custom retention
BACKUP_RETENTION_DAYS=30 ./backup.sh
```

### Backup Features
- **Compressed Database Dumps**: Automatic gzip compression with configurable levels
- **Incremental Uploads**: Space-efficient file backups using hardlinks
- **Retention Policies**: Time-based and count-based cleanup
- **Error Recovery**: Failed backup analysis and recovery

### Restore Operations
```bash
# Restore from specific backup
./backup-restore.sh ./directus/data/backups/backup_latest

# Restore from any backup directory
./backup-restore.sh ./directus/data/backups/backup_2024-01-15_10-30-00_1705312200
```

## 🔄 Environment Synchronization

Sync databases and files between environments using the sync system.

```bash
# Pull from production to local
./sync.sh pull prod

# Pull from development to local
./sync.sh pull dev

# Create local backup only
./sync.sh pull local

# Push local backup to development (production pushes are restricted)
./sync.sh push dev

# Restore latest local backup
./sync.sh push local
```

## 🏗 Project Structure

```
directus-alto/
├── alto                           # Main CLI tool
├── backup.sh                     # Backup system
├── backup-restore.sh             # Restore system
├── sync.sh                       # Environment sync
├── docker-compose.yml            # Development stack
├── docker-compose.base.yml       # Base services
├── docker-compose.prod.yml       # Production overrides
├── example.env                   # Environment template
├── .gitignore                    # Git ignore patterns
└── directus/
    ├── Dockerfile                # Custom Directus image
    ├── directus-sync.config.base.js  # Sync configuration
    ├── extensions/               # Custom extensions
    ├── migrations/               # Database migrations
    ├── seed/                     # Seed data
    └── data/
        ├── backups/              # Backup storage
        ├── logs/                 # Application logs
        ├── uploads/              # User uploads
        └── .alto/                # Alto CLI working directory
```

## ⚙️ Configuration

### Environment Variables

Key configuration options in your `.env` file:

```bash
# Directus Core Security (CRITICAL - MUST BE CHANGED)
# Generate this using `npx directus bootstrap` or any random string generator.
# It should be long, random, and secret.
# See: https://directus.io/docs/configuration/security-and-limits
SECRET=your_generated_secret_here

# This should be the public-facing URL where Directus is accessible.
# For local development, use localhost. For production, set this to your actual Directus URL.
PUBLIC_URL=http://localhost:8055

# Default admin account credentials (CHANGE FOR PRODUCTION)
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=admin
# A static token for the first admin user, created during bootstrapping.
# Also used by custom scripts like `alto` for `directus-sync`.
ADMIN_TOKEN=your_local_dev_token

# Database Configuration
DB_CLIENT=pg
DB_HOST=database
DB_PORT=5432
DB_DATABASE=directus
DB_USER=postgres
DB_PASSWORD=your_database_password_here

# Cache Configuration (optional, commented by default)
# CACHE_ENABLED=true
# CACHE_STORE=redis
# REDIS=redis://cache:6379

# Email Configuration (uses Mailpit for development)
EMAIL_TRANSPORT=smtp
EMAIL_FROM=noreply@example.com
EMAIL_SMTP_HOST=mailpit
EMAIL_SMTP_PORT=1025

# Backup Configuration
BACKUPS_DIR=./directus/data/backups
BACKUP_RETENTION_DAYS=7
BACKUP_RETENTION_COUNT=0

# Sync Script Configuration
PROD_SERVER=your-prod-server-alias
DEV_SERVER=your-dev-server-alias
REMOTE_PROJECT_PATH=/srv/backend-directus

# Alto CLI Configuration
ALTO_BASE_DIR=./directus/data/.alto
```

⚠️ **Security Warning**: The default values above are for development only. **Always change SECRET, passwords, and tokens before deploying to production!**

### Docker Services

#### Development (docker-compose.yml)
- **directus**: Main CMS application with custom extensions
- **database**: PostgreSQL with PostGIS extensions
- **mailpit**: Email testing (development only)
- **cache**: Redis for caching (optional, commented by default)

#### Production (docker-compose.prod.yml)
- **directus**: Directus CMS backend
- **database**: PostgreSQL database

**Note**: The production compose file currently includes only base services. Frontend services can be added manually based on your chosen deployment strategy (see Fullstack Monorepo Setup section).

## 🔧 Development Workflow

### 1. Schema Development
```bash
# Work on your schema in Directus Admin UI
# Pull changes to version control
./alto ds pull all

# Apply schema changes to other environments
./alto ds push collections
```

### 2. Extension Development
```bash
# Mount your extensions in docker-compose.yml
# volumes:
#   - ./directus/extensions/my-extension:/directus/extensions/my-extension

# Restart to load extensions
./alto restart directus
```

### 3. Database Snapshots
```bash
# Before major changes
./alto db-dump before-migration     # Creates: {timestamp}_before-migration.sql

# After testing  
./alto db-dump after-migration      # Creates: {timestamp}_after-migration.sql

# Rollback if needed
./alto db-restore before-migration  # Finds latest backup containing "before-migration"
```

### 4. Environment Promotion
```bash
# Test locally, then promote to dev
./sync.sh pull local
./sync.sh push dev

# Pull production data for testing
./sync.sh pull prod
./sync.sh push local
```

## 🎯 Fullstack Monorepo Setup

This template can be easily extended to a fullstack monorepo by adding your frontend application alongside Directus.

### Adding Frontend Application

Choose between two deployment strategies based on your frontend framework:

### Option A: SPA + Nginx (React, Vue, Angular, Svelte)

For static Single Page Applications that generate build artifacts:

1. **Create your frontend directory**:
```bash
mkdir frontend
cd frontend
# Initialize your SPA (React, Vue, Angular, Svelte, etc.)
# npm create react-app . 
# npm create vue@latest .
# npm create svelte@latest .
```

2. **Add Dockerfile for SPA**:
```dockerfile
# frontend/Dockerfile
# Build stage
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build

# Production stage with Nginx  
FROM nginx:alpine AS runner
COPY --from=builder /app/dist /usr/share/nginx/html  # Adjust path: /app/build for React, /app/dist for Vue/Vite
COPY ./nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

3. **Add nginx config** (create `frontend/nginx.conf`):
```nginx
server {
    listen 80;
    server_name localhost;
    root /usr/share/nginx/html;
    index index.html;

    # Handle client-side routing for SPA
    location / {
        try_files $uri $uri/ /index.html;
    }

    # Gzip compression for better performance
    gzip on;
    gzip_vary on;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
}
```

4. **Docker Compose setup**:
```yaml
# In docker-compose.prod.yml
services:
  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    ports:
      - "3000:80"
    environment:
      - VITE_API_URL=${DIRECTUS_API_URL}     # for Vite (Vue/Svelte)
      - REACT_APP_API_URL=${DIRECTUS_API_URL}  # for React
```

### Option B: Next.js with Server

For Next.js applications with server-side rendering:

1. **Create your Next.js directory**:
```bash
mkdir frontend
cd frontend
npx create-next-app@latest . --typescript --tailwind --eslint
```

2. **Add Dockerfile for Next.js**:
```dockerfile
# frontend/Dockerfile
# Build stage
FROM node:18-alpine AS builder
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

RUN npm install -g pnpm
COPY package*.json ./
RUN pnpm install --no-frozen-lockfile --no-dev
RUN pnpm add sharp
COPY . .
COPY deploy.env .env
RUN pnpm run build

# Production stage
FROM oven/bun:1-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production

# Copy necessary files from build stage
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static

EXPOSE 3000
CMD ["node", "server.js"]
```

3. **Enable standalone output** (next.config.js):
```javascript
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
}

module.exports = nextConfig
```

4. **Docker Compose setup**:
```yaml
# In docker-compose.prod.yml
services:
  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    ports:
      - "3000:3000"
    environment:
      - NEXT_PUBLIC_API_URL=${DIRECTUS_API_URL}
```

**Note**: The current `docker-compose.prod.yml` only includes base services. To use frontend services, you'll need to add them manually based on your chosen option above.

### Frontend Container Purpose
The frontend container serves a single purpose: **packaging your built frontend application into a lightweight, deployable Docker image**.

**What it includes:**
- Built static files (HTML, CSS, JS)
- Nginx for serving static content only (Option A)
- Next.js server (Option B)
- SPA routing support
- Gzip compression

**What it does NOT include:**
- API proxying or routing
- Domain configuration
- SSL termination
- Backend services

### Infrastructure Responsibilities
Domain configuration, SSL, API routing, and load balancing should be handled by your infrastructure layer (external nginx, Traefik, Cloudflare, etc.), not by the application containers.

### Monorepo Structure

**Option A: SPA + Nginx**
```
directus-alto/
├── alto                           # CLI tool
├── backup.sh                     # Backup system
├── sync.sh                       # Environment sync
├── frontend/                     # Your SPA frontend
│   ├── Dockerfile                 # Multi-stage build with Nginx
│   ├── nginx.conf                 # Nginx config for static serving
│   ├── package.json
│   ├── src/
│   └── dist/                      # Build output (gitignored)
├── directus/                     # Backend CMS
└── docker-compose.*.yml          # Container orchestration
```

**Option B: Next.js Server**
```
directus-alto/
├── alto                           # CLI tool
├── backup.sh                     # Backup system
├── sync.sh                       # Environment sync
├── frontend/                     # Your Next.js app
│   ├── Dockerfile                 # Next.js standalone build
│   ├── next.config.js             # Next.js config with standalone output
│   ├── package.json
│   ├── pages/ or app/             # Next.js routes
│   └── .next/                     # Build output (gitignored)
├── directus/                     # Backend CMS
└── docker-compose.*.yml          # Container orchestration
```

### Benefits of Monorepo Approach
- **Unified Repository**: Single repository for entire application stack
- **Shared Configuration**: Common environment variables and deployment scripts
- **Consistent Deployment**: Deploy entire stack together in production
- **Schema Synchronization**: Keep frontend types in sync with Directus schema
- **Simplified CI/CD**: Single pipeline for both frontend and backend

### Development Workflow

**Backend Development:**
```bash
# Start Directus and supporting services
./alto up -d

# Services available at:
# Directus: http://localhost:8055
# Mailpit: http://localhost:8025
```

**Frontend Development (both options):**
```bash
# Local development with hot reloading
cd frontend

# For SPA (React/Vue/Angular/Svelte)
npm run dev      # Usually http://localhost:5173 (Vite) or :3000 (React)

# For Next.js
npm run dev      # Usually http://localhost:3000
```

**Container Testing:**
```bash
# Build and test your frontend container locally
docker-compose -f docker-compose.prod.yml build frontend
docker-compose -f docker-compose.prod.yml up frontend

# For SPA: Container serves static files on http://localhost:3000
# For Next.js: Container runs server on http://localhost:3000
```

**Production Build:**
```bash
# Build all images for deployment
docker-compose -f docker-compose.prod.yml build

# Deploy according to your infrastructure setup
```

### Development Best Practices

**Backend:**
- Use `alto` CLI for all Directus operations and database management
- Database dumps and restores are managed through `alto db-dump` / `alto db-restore`
- Schema changes tracked via `alto directus-sync`

**Frontend:**
- **Local Development**: Always use `npm run dev` for hot reloading and fast iteration
- **API Configuration**: Point to `http://localhost:8055` in your development environment
- **Container Testing**: Build and test containers before deployment to catch build issues early
- **Environment Variables**: Use different variable names based on your framework:
  - Vite: `VITE_API_URL`
  - React: `REACT_APP_API_URL` 
  - Next.js: `NEXT_PUBLIC_API_URL`

**Deployment:**
- Frontend containers are lightweight and self-contained
- Infrastructure handles routing, SSL, and domain configuration
- Use `docker-compose.prod.yml` to build production images

## 📚 Advanced Usage

### Custom Commands
Alto supports custom configurations:

```bash
# Use custom config file
./alto --config custom.env up -d

# Override base directory
ALTO_BASE_DIR=/custom/path ./alto db-dump
```

### Backup Automation
Set up automated backups with cron:

```bash
# Daily backups at 2 AM
0 2 * * * cd /path/to/project && ./backup.sh >> /var/log/directus-backup.log 2>&1
```

### Production Deployment
1. Use `docker-compose.prod.yml` for production
2. Configure proper environment variables
3. Set up backup automation
4. Configure reverse proxy (nginx/traefik)
5. Set up monitoring and alerts

## 🔒 Security Considerations

- **Environment Files**: Never commit `.env` files
- **Production Access**: Sync script restricts production pushes
- **Backup Security**: Secure backup directories with proper permissions
- **Token Management**: Use strong, unique tokens for each environment
- **Default Credentials**: Always change SECRET, passwords, and tokens before production deployment

## 🤝 Contributing

This template is designed to be forked and customized for your specific needs. Consider contributing improvements back to help the community.

## 📄 License

[Your License Here]

## 🆘 Support

- **Documentation**: Check the comprehensive inline help with `./alto --help`
- **Troubleshooting**: Error logs are preserved in `directus/data/backups/error_logs/`
- **Community**: [Your community links]

---

**Built with ❤️ for developers who want to use Directus as more than just a CMS**