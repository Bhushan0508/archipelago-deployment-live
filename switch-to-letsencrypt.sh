#!/bin/bash
# Switch from self-signed certificate to Let's Encrypt SSL
# This script performs the complete migration to production SSL setup

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

if [ -f .env ]; then
    source .env
else
    echo -e "${RED}Error: .env file not found!${NC}"
    exit 1
fi

echo "================================================================"
echo "   Archipelago SSL Certificate Migration to Let's Encrypt"
echo "================================================================"
echo ""
echo "Domain: $ARCHIPELAGO_DOMAIN"
echo "Email: $ARCHIPELAGO_EMAIL"
echo ""

# Check if certbot is installed
if ! command -v certbot &> /dev/null; then
    echo -e "${RED}Error: certbot is not installed!${NC}"
    echo "Install it with: sudo apt-get install certbot"
    exit 1
fi

echo -e "${BLUE}Step 1: Checking current certificate status...${NC}"
echo "Current certificate details:"
echo | openssl s_client -connect $ARCHIPELAGO_DOMAIN:443 -servername $ARCHIPELAGO_DOMAIN 2>&1 | grep -E "subject=|issuer=|Verify return code" || true
echo ""

# Check if Let's Encrypt certificate exists
echo -e "${BLUE}Step 2: Checking for existing Let's Encrypt certificate...${NC}"
if sudo certbot certificates 2>&1 | grep -q "$ARCHIPELAGO_DOMAIN"; then
    echo -e "${GREEN}✓ Let's Encrypt certificate found${NC}"
    sudo certbot certificates | grep -A 6 "$ARCHIPELAGO_DOMAIN"
    CERT_EXISTS=true
else
    echo -e "${YELLOW}! No Let's Encrypt certificate found${NC}"
    CERT_EXISTS=false
fi
echo ""

# Obtain certificate if it doesn't exist
if [ "$CERT_EXISTS" = false ]; then
    echo -e "${BLUE}Step 3: Obtaining Let's Encrypt certificate...${NC}"
    echo "This will temporarily stop the web container to free ports 80/443"
    read -p "Continue? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi

    # Stop web container
    echo "Stopping web container..."
    docker-compose stop web || docker-compose -f docker-compose-production.yml stop web || true

    # Obtain certificate
    echo "Obtaining certificate from Let's Encrypt..."
    sudo certbot certonly --standalone \
        -d $ARCHIPELAGO_DOMAIN \
        -m $ARCHIPELAGO_EMAIL \
        --agree-tos \
        --non-interactive \
        --preferred-challenges http

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Certificate obtained successfully!${NC}"
    else
        echo -e "${RED}✗ Certificate generation failed!${NC}"
        exit 1
    fi
else
    echo -e "${BLUE}Step 3: Skipping certificate generation (already exists)${NC}"
fi
echo ""

# Verify certificate files exist
echo -e "${BLUE}Step 4: Verifying certificate files...${NC}"
if sudo test -f "/etc/letsencrypt/live/$ARCHIPELAGO_DOMAIN/fullchain.pem"; then
    echo -e "${GREEN}✓ fullchain.pem exists${NC}"
else
    echo -e "${RED}✗ fullchain.pem not found!${NC}"
    exit 1
fi

if sudo test -f "/etc/letsencrypt/live/$ARCHIPELAGO_DOMAIN/privkey.pem"; then
    echo -e "${GREEN}✓ privkey.pem exists${NC}"
else
    echo -e "${RED}✗ privkey.pem not found!${NC}"
    exit 1
fi
echo ""

# Check if nginx template exists
echo -e "${BLUE}Step 5: Preparing nginx configuration...${NC}"
if [ ! -f "$ARCHIPELAGO_ROOT/config_storage/nginxconfig/conf.d/nginx.conf.template" ]; then
    echo "Creating nginx template file..."
    cp "$ARCHIPELAGO_ROOT/config_storage/nginxconfig/conf.d/nginx.conf" \
       "$ARCHIPELAGO_ROOT/config_storage/nginxconfig/conf.d/nginx.conf.template"
    echo -e "${GREEN}✓ Template created${NC}"
else
    echo -e "${GREEN}✓ Template already exists${NC}"
fi
echo ""

# Switch to production configuration
echo -e "${BLUE}Step 6: Switching to production configuration...${NC}"
echo "Stopping current stack..."
docker-compose down 2>/dev/null || docker-compose -f docker-compose-selfsigned.yml down 2>/dev/null || true

echo "Starting production stack with Let's Encrypt..."
docker-compose -f docker-compose-production.yml up -d

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Production stack started${NC}"
else
    echo -e "${RED}✗ Failed to start production stack${NC}"
    exit 1
fi
echo ""

# Wait for services to start
echo -e "${BLUE}Step 7: Waiting for services to start...${NC}"
sleep 10

# Check container status
echo "Container status:"
docker ps --filter "name=esmero" --format "table {{.Names}}\t{{.Status}}" | grep esmero
echo ""

# Verify certificate is working
echo -e "${BLUE}Step 8: Verifying certificate is working...${NC}"
echo "Checking SSL certificate verification..."
VERIFY_RESULT=$(echo | openssl s_client -connect $ARCHIPELAGO_DOMAIN:443 -servername $ARCHIPELAGO_DOMAIN 2>&1 | grep "Verify return code")
echo "$VERIFY_RESULT"

if echo "$VERIFY_RESULT" | grep -q "Verify return code: 0 (ok)"; then
    echo -e "${GREEN}✓ Certificate is valid and trusted!${NC}"
else
    echo -e "${YELLOW}! Certificate verification returned non-zero code${NC}"
    echo "This might resolve after DNS propagation or initial connection"
fi
echo ""

# Check certificate issuer
echo "Certificate issuer:"
echo | openssl s_client -connect $ARCHIPELAGO_DOMAIN:443 -servername $ARCHIPELAGO_DOMAIN 2>&1 | grep -E "subject=|issuer=" | head -2
echo ""

# Test HTTPS connection
echo -e "${BLUE}Step 9: Testing HTTPS connection...${NC}"
HTTP_RESULT=$(curl -s -o /dev/null -w "%{http_code}" https://$ARCHIPELAGO_DOMAIN 2>/dev/null || echo "failed")

if [ "$HTTP_RESULT" = "200" ]; then
    echo -e "${GREEN}✓ HTTPS connection successful (HTTP $HTTP_RESULT)${NC}"
else
    echo -e "${YELLOW}! HTTPS returned: $HTTP_RESULT${NC}"
fi
echo ""

# Check auto-renewal setup
echo -e "${BLUE}Step 10: Checking certificate auto-renewal...${NC}"
if crontab -l 2>/dev/null | grep -q "renew-certificate.sh"; then
    echo -e "${GREEN}✓ Auto-renewal cron job configured${NC}"
    echo "Cron entry:"
    crontab -l | grep renew-certificate.sh
else
    echo -e "${YELLOW}! No auto-renewal cron job found${NC}"
    echo "To set up auto-renewal, run:"
    echo "  crontab -e"
    echo "And add:"
    echo "  30 2 * * * $SCRIPT_DIR/renew-certificate.sh >> /var/log/letsencrypt-renewal.log 2>&1"
fi
echo ""

# Summary
echo "================================================================"
echo -e "${GREEN}                    MIGRATION COMPLETE!${NC}"
echo "================================================================"
echo ""
echo "Summary:"
echo "  • Let's Encrypt certificate: Active"
echo "  • Certificate issuer: Let's Encrypt"
echo "  • Domain: $ARCHIPELAGO_DOMAIN"
echo "  • Configuration: docker-compose-production.yml"
echo ""
echo "Next steps:"
echo "  1. Test in browser: https://$ARCHIPELAGO_DOMAIN"
echo "  2. Verify no security warnings appear"
echo "  3. Check certificate details in browser (should show Let's Encrypt)"
echo ""
echo "Certificate will auto-renew 30 days before expiration."
echo "Check renewal status with: sudo certbot certificates"
echo ""
echo "To view logs: docker logs esmero-web"
echo "================================================================"
