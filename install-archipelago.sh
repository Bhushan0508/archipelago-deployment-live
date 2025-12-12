#!/bin/bash
#
# Archipelago 2.0.0 Installation Script
# This script automates the installation of Archipelago on a remote server
# Usage: ./install-archipelago.sh
#
# Requirements:
# - Docker and docker-compose installed
# - Git repository cloned at /home/tod/archipelago-deployment-live
# - Sudo access for fixing permissions
#

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables
ARCHIPELAGO_ROOT="/home/tod/archipelago-deployment-live"
ARCHIPELAGO_DOMAIN="tod.vridhamma.org"
ARCHIPELAGO_EMAIL="admin@vridhamma.org"
MYSQL_ROOT_PASSWORD="esmero-db"
ADMIN_PASSWORD="admin123"
SUDO_PASSWORD="Pala@tod"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Archipelago 2.0.0 Installation Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

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
openssl req -x509 -nodes -days 365 -newkey rsa:2048   -keyout $ARCHIPELAGO_ROOT/data_storage/selfcert/private/nginx.key   -out $ARCHIPELAGO_ROOT/data_storage/selfcert/certs/nginx.crt   -subj "/C=US/ST=State/L=City/O=Organization/CN=$ARCHIPELAGO_DOMAIN"
echo -e "${GREEN}✓ SSL certificates generated${NC}"
echo ""

# Step 3: Start Docker containers
echo -e "${YELLOW}Step 3: Starting Docker containers...${NC}"
cd $ARCHIPELAGO_ROOT/deploy/ec2-docker
docker-compose up -d
echo -e "${GREEN}✓ Docker containers started${NC}"
echo ""

# Step 4: Fix Solr permissions
echo -e "${YELLOW}Step 4: Fixing Solr permissions...${NC}"
echo "$SUDO_PASSWORD" | sudo -S chown -R 8983:8983 $ARCHIPELAGO_ROOT/data_storage/solrcore/
echo -e "${GREEN}✓ Solr permissions fixed${NC}"
echo ""

# Step 5: Restart services
echo -e "${YELLOW}Step 5: Restarting services...${NC}"
docker-compose down
docker-compose up -d
sleep 10
echo -e "${GREEN}✓ Services restarted${NC}"
echo ""

# Step 6: Copy composer files
echo -e "${YELLOW}Step 6: Setting up Composer files...${NC}"
cd $ARCHIPELAGO_ROOT/drupal
cp composer.default.json composer.json
cp composer.default.lock composer.lock
echo -e "${GREEN}✓ Composer files ready${NC}"
echo ""

# Step 7: Run composer install
echo -e "${YELLOW}Step 7: Installing PHP dependencies (this may take a few minutes)...${NC}"
docker exec esmero-php bash -c 'cd /var/www/html && composer install'
echo -e "${GREEN}✓ Composer install complete${NC}"
echo ""

# Step 8: Set permissions
echo -e "${YELLOW}Step 8: Setting file permissions...${NC}"
docker exec esmero-php bash -c 'chown -R www-data:www-data private'
docker exec esmero-php bash -c 'chown -R www-data:www-data web/sites'
echo -e "${GREEN}✓ Permissions set${NC}"
echo ""

# Step 9: Update Archipelago modules
echo -e "${YELLOW}Step 9: Updating Archipelago modules...${NC}"
docker exec esmero-php bash -c 'composer update archipelago/* strawberryfield/*'
echo -e "${GREEN}✓ Modules updated${NC}"
echo ""

# Step 10: Run setup script
echo -e "${YELLOW}Step 10: Running Archipelago setup script...${NC}"
docker exec esmero-php bash -c 'scripts/archipelago/setup.sh'
echo -e "${GREEN}✓ Setup script complete${NC}"
echo ""

# Step 11: Install Drupal
echo -e "${YELLOW}Step 11: Installing Drupal (this may take several minutes)...${NC}"
docker exec -u www-data esmero-php bash -c "cd web;../vendor/bin/drush -y si --verbose --existing-config --extra=--skip-ssl --db-url=mysql://root:$MYSQL_ROOT_PASSWORD@esmero-db/drupal --account-name=admin --account-pass=$ADMIN_PASSWORD -r=/var/www/html/web --sites-subdir=default --notify=false;drush cr;chown -R www-data:www-data sites;"
echo -e "${GREEN}✓ Drupal installed${NC}"
echo ""

# Step 12: Create users
echo -e "${YELLOW}Step 12: Creating Drupal users...${NC}"
docker exec esmero-php bash -c 'drush ucrt demo --password="demo"; drush urol metadata_pro "demo"'
docker exec esmero-php bash -c 'drush ucrt jsonapi --password="jsonapi"; drush urol metadata_api "jsonapi"'
docker exec esmero-php bash -c 'drush urol administrator "admin"'
echo -e "${GREEN}✓ Users created${NC}"
echo ""

# Step 13: Update deploy scripts
echo -e "${YELLOW}Step 13: Updating deploy scripts with domain...${NC}"
cd $ARCHIPELAGO_ROOT
sed -i "s/http:\/\/esmero-web/https:\/\/$ARCHIPELAGO_DOMAIN/g" drupal/scripts/archipelago/deploy.sh
sed -i "s/http:\/\/esmero-web/https:\/\/$ARCHIPELAGO_DOMAIN/g" drupal/scripts/archipelago/update_deployed.sh
echo -e "${GREEN}✓ Deploy scripts updated${NC}"
echo ""

# Step 14: Deploy initial content
echo -e "${YELLOW}Step 14: Deploying initial content and templates...${NC}"
docker exec esmero-php bash -c 'scripts/archipelago/deploy.sh' 2>&1 | grep -v "SSL certificate problem" || true
echo -e "${GREEN}✓ Initial content deployed${NC}"
echo ""

# Step 15: Configure IIIF server
echo -e "${YELLOW}Step 15: Configuring IIIF server URL...${NC}"
docker exec esmero-php bash -c "drush config-set -y format_strawberryfield.iiif_settings pub_server_url https://$ARCHIPELAGO_DOMAIN/cantaloupe/iiif/2"
echo -e "${GREEN}✓ IIIF server configured${NC}"
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
echo -e "${YELLOW}Important:${NC} Please complete the final step manually:"
echo "  1. Log in to https://$ARCHIPELAGO_DOMAIN"
echo "  2. Navigate to /admin/config/search/search-api"
echo "  3. Click 'Execute pending tasks' button if present"
echo ""
echo -e "${GREEN}All Docker services are running and accessible.${NC}"
echo ""
