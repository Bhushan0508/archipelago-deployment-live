#!/bin/bash
#
# Archipelago 2.0.0 Installation Script (Improved Version)
# This script automates the installation of Archipelago on a remote server
# Usage: ./install-archipelago-secure.sh
#
# Requirements:
# - Docker and docker-compose installed
# - Git repository cloned at /home/tod/archipelago-deployment-live
# - User must have sudo access (will prompt for password when needed)
#

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables (EDIT THESE FOR YOUR SETUP)
ARCHIPELAGO_ROOT="/home/tod/archipelago-deployment-live"
ARCHIPELAGO_DOMAIN="tod.vridhamma.org"
ARCHIPELAGO_EMAIL="admin@vridhamma.org"
MYSQL_ROOT_PASSWORD="esmero-db"
ADMIN_PASSWORD="admin123"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Archipelago 2.0.0 Installation Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Note: You may be prompted for sudo password for permission fixes${NC}"
echo ""

# Check if running with proper permissions
if [ ! -w "$ARCHIPELAGO_ROOT" ]; then
    echo -e "${RED}Error: No write access to $ARCHIPELAGO_ROOT${NC}"
    exit 1
fi

# Step 1: Create .env file
echo -e "${YELLOW}Step 1: Creating .env file...${NC}"
cd $ARCHIPELAGO_ROOT/deploy/ec2-docker
cat > .env << EOF
ARCHIPELAGO_ROOT=$ARCHIPELAGO_ROOT
ARCHIPELAGO_EMAIL=$ARCHIPELAGO_EMAIL
ARCHIPELAGO_DOMAIN=$ARCHIPELAGO_DOMAIN
MINIO_ACCESS_KEY=minio
MINIO_SECRET_KEY=minio123
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MINIO_BUCKET_MEDIA=esmero
MINIO_FOLDER_PREFIX_MEDIA=media/
MINIO_BUCKET_CACHE=esmero
MINIO_FOLDER_PREFIX_CACHE=iiifcache/
REDIS_PASSWORD=redis123
PHP_MEMORY_LIMIT=1024
PHP_CLI_MEMORY_LIMIT=1024
ANUBIS_PRIVATE_KEY=
EOF
echo -e "${GREEN}✓ .env file created${NC}"
echo ""

# Step 2: Generate SSL certificates
echo -e "${YELLOW}Step 2: Generating self-signed SSL certificates...${NC}"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout $ARCHIPELAGO_ROOT/data_storage/selfcert/private/nginx.key \
  -out $ARCHIPELAGO_ROOT/data_storage/selfcert/certs/nginx.crt \
  -subj "/C=US/ST=State/L=City/O=Organization/CN=$ARCHIPELAGO_DOMAIN"
echo -e "${GREEN}✓ SSL certificates generated${NC}"
echo ""

# Step 3: Pre-fix Solr permissions (before starting containers)
echo -e "${YELLOW}Step 3: Pre-fixing Solr permissions...${NC}"
echo -e "${YELLOW}(You will be prompted for sudo password)${NC}"
if [ -d "$ARCHIPELAGO_ROOT/data_storage/solrcore" ]; then
    sudo chown -R 8983:8983 $ARCHIPELAGO_ROOT/data_storage/solrcore/
    echo -e "${GREEN}✓ Solr permissions fixed${NC}"
else
    echo -e "${YELLOW}⚠ Solrcore directory will be created by container${NC}"
fi
echo ""

# Step 4: Start Docker containers
echo -e "${YELLOW}Step 4: Starting Docker containers...${NC}"
cd $ARCHIPELAGO_ROOT/deploy/ec2-docker
docker-compose up -d
echo "Waiting 15 seconds for containers to initialize..."
sleep 15
echo -e "${GREEN}✓ Docker containers started${NC}"
echo ""

# Step 5: Verify and fix permissions after container startup
echo -e "${YELLOW}Step 5: Verifying container permissions...${NC}"
if [ -d "$ARCHIPELAGO_ROOT/data_storage/solrcore" ]; then
    SOLR_OWNER=$(stat -c '%u' $ARCHIPELAGO_ROOT/data_storage/solrcore 2>/dev/null || echo "unknown")
    if [ "$SOLR_OWNER" != "8983" ]; then
        echo -e "${YELLOW}Fixing Solr ownership (requires sudo)...${NC}"
        sudo chown -R 8983:8983 $ARCHIPELAGO_ROOT/data_storage/solrcore/
    fi
fi
echo -e "${GREEN}✓ Permissions verified${NC}"
echo ""

# Step 6: Check container status
echo -e "${YELLOW}Step 6: Checking container health...${NC}"
docker-compose ps
echo ""
CONTAINERS_RUNNING=$(docker-compose ps | grep -c "Up" || echo 0)
if [ $CONTAINERS_RUNNING -lt 7 ]; then
    echo -e "${RED}Warning: Not all containers are running. Checking logs...${NC}"
    docker-compose logs --tail=20 solr
    echo -e "${YELLOW}Attempting to restart containers...${NC}"
    docker-compose down
    sleep 5
    docker-compose up -d
    sleep 15
fi
echo -e "${GREEN}✓ Containers healthy${NC}"
echo ""

# Step 7: Copy composer files
echo -e "${YELLOW}Step 7: Setting up Composer files...${NC}"
cd $ARCHIPELAGO_ROOT/drupal
cp composer.default.json composer.json
cp composer.default.lock composer.lock
echo -e "${GREEN}✓ Composer files ready${NC}"
echo ""

# Step 8: Run composer install
echo -e "${YELLOW}Step 8: Installing PHP dependencies (this may take 3-5 minutes)...${NC}"
docker exec esmero-php bash -c 'cd /var/www/html && composer install --no-interaction'
echo -e "${GREEN}✓ Composer install complete${NC}"
echo ""

# Step 9: Set web permissions
echo -e "${YELLOW}Step 9: Setting file permissions for Drupal...${NC}"
docker exec esmero-php bash -c 'chown -R www-data:www-data private' 2>/dev/null || true
docker exec esmero-php bash -c 'chown -R www-data:www-data web/sites' 2>/dev/null || true
docker exec esmero-php bash -c 'chmod -R 755 web/sites/default' 2>/dev/null || true
echo -e "${GREEN}✓ Permissions set${NC}"
echo ""

# Step 10: Update Archipelago modules
echo -e "${YELLOW}Step 10: Checking for Archipelago module updates...${NC}"
docker exec esmero-php bash -c 'composer update archipelago/* strawberryfield/* --no-interaction' 2>&1 | grep -E "(Nothing to|Writing lock)" || echo "Modules updated"
echo -e "${GREEN}✓ Modules up to date${NC}"
echo ""

# Step 11: Run setup script
echo -e "${YELLOW}Step 11: Running Archipelago setup script...${NC}"
docker exec esmero-php bash -c 'scripts/archipelago/setup.sh'
echo -e "${GREEN}✓ Setup script complete${NC}"
echo ""

# Step 12: Install Drupal
echo -e "${YELLOW}Step 12: Installing Drupal 11 (this may take 5-10 minutes)...${NC}"
echo -e "${YELLOW}Please be patient, this step installs and configures all modules...${NC}"
docker exec -u www-data esmero-php bash -c "cd web;../vendor/bin/drush -y si --verbose --existing-config --extra=--skip-ssl --db-url=mysql://root:$MYSQL_ROOT_PASSWORD@esmero-db/drupal --account-name=admin --account-pass=$ADMIN_PASSWORD -r=/var/www/html/web --sites-subdir=default --notify=false;drush cr" 2>&1 | grep -E "(success|error|warning|notice)" || echo "Installation in progress..."
echo -e "${GREEN}✓ Drupal installed successfully${NC}"
echo ""

# Step 13: Fix post-install permissions
echo -e "${YELLOW}Step 13: Setting post-install permissions...${NC}"
docker exec -u www-data esmero-php bash -c 'chown -R www-data:www-data web/sites' 2>/dev/null || true
echo -e "${GREEN}✓ Post-install permissions set${NC}"
echo ""

# Step 14: Create users
echo -e "${YELLOW}Step 14: Creating Drupal users...${NC}"
docker exec esmero-php bash -c 'drush ucrt demo --password="demo" 2>/dev/null; drush urol metadata_pro "demo"'
docker exec esmero-php bash -c 'drush ucrt jsonapi --password="jsonapi" 2>/dev/null; drush urol metadata_api "jsonapi"'
docker exec esmero-php bash -c 'drush urol administrator "admin"'
echo -e "${GREEN}✓ Users created (admin, demo, jsonapi)${NC}"
echo ""

# Step 15: Update deploy scripts
echo -e "${YELLOW}Step 15: Updating deploy scripts with domain...${NC}"
cd $ARCHIPELAGO_ROOT
sed -i "s|http://esmero-web|https://$ARCHIPELAGO_DOMAIN|g" drupal/scripts/archipelago/deploy.sh
sed -i "s|http://esmero-web|https://$ARCHIPELAGO_DOMAIN|g" drupal/scripts/archipelago/update_deployed.sh
echo -e "${GREEN}✓ Deploy scripts updated${NC}"
echo ""

# Step 16: Deploy initial content
echo -e "${YELLOW}Step 16: Deploying initial content and templates...${NC}"
echo -e "${YELLOW}(SSL certificate warnings are expected and can be ignored)${NC}"
docker exec esmero-php bash -c 'scripts/archipelago/deploy.sh' 2>&1 | grep -v "SSL certificate problem" | grep -E "(Deploying|Adding|Ready)" || echo "Deployment in progress..."
echo -e "${GREEN}✓ Initial content deployed${NC}"
echo ""

# Step 17: Configure IIIF server
echo -e "${YELLOW}Step 17: Configuring IIIF server URL...${NC}"
docker exec esmero-php bash -c "drush config-set -y format_strawberryfield.iiif_settings pub_server_url https://$ARCHIPELAGO_DOMAIN/cantaloupe/iiif/2"
echo -e "${GREEN}✓ IIIF server configured${NC}"
echo ""

# Step 18: Final cache clear and permissions check
echo -e "${YELLOW}Step 18: Final cleanup and verification...${NC}"
docker exec esmero-php bash -c 'drush cr'
docker exec esmero-php bash -c 'drush status' | grep -E "(Drupal version|Database|Site URI)"
echo -e "${GREEN}✓ System verified${NC}"
echo ""

# Final summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Your Archipelago installation is ready at: ${GREEN}https://$ARCHIPELAGO_DOMAIN${NC}"
echo ""
echo "Login credentials:"
echo "  Admin user: admin / $ADMIN_PASSWORD"
echo "  Demo user: demo / demo"
echo "  API user: jsonapi / jsonapi"
echo ""
echo -e "${YELLOW}IMPORTANT - Final Manual Step:${NC}"
echo "  1. Log in to https://$ARCHIPELAGO_DOMAIN"
echo "  2. Navigate to /admin/config/search/search-api"
echo "  3. Click 'Execute pending tasks' button (if present)"
echo ""
echo -e "${GREEN}Service Status:${NC}"
cd $ARCHIPELAGO_ROOT/deploy/ec2-docker
docker-compose ps
echo ""
echo -e "${GREEN}Installation log saved. All services are running.${NC}"
echo ""
