#!/bin/bash
# Setup Let's Encrypt SSL Certificate for Archipelago
# This is the initial setup script for obtaining a Let's Encrypt certificate
# After running this, use switch-to-letsencrypt.sh to migrate to production

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
    echo "Please create a .env file with ARCHIPELAGO_DOMAIN and ARCHIPELAGO_EMAIL"
    exit 1
fi

echo "================================================================"
echo "   Let's Encrypt Certificate Initial Setup"
echo "================================================================"
echo ""
echo "Domain: $ARCHIPELAGO_DOMAIN"
echo "Email: $ARCHIPELAGO_EMAIL"
echo ""

# Validate required variables
if [ -z "$ARCHIPELAGO_DOMAIN" ]; then
    echo -e "${RED}Error: ARCHIPELAGO_DOMAIN is not set in .env${NC}"
    exit 1
fi

if [ -z "$ARCHIPELAGO_EMAIL" ]; then
    echo -e "${RED}Error: ARCHIPELAGO_EMAIL is not set in .env${NC}"
    exit 1
fi

# Check if certbot is installed
echo -e "${BLUE}Step 1: Checking prerequisites...${NC}"
if ! command -v certbot &> /dev/null; then
    echo -e "${RED}✗ certbot is not installed!${NC}"
    echo ""
    echo "Install certbot with:"
    echo "  sudo apt-get update"
    echo "  sudo apt-get install certbot"
    exit 1
else
    CERTBOT_VERSION=$(certbot --version 2>&1)
    echo -e "${GREEN}✓ certbot is installed: $CERTBOT_VERSION${NC}"
fi
echo ""

# Check if certificate already exists
echo -e "${BLUE}Step 2: Checking for existing certificate...${NC}"
if sudo certbot certificates 2>&1 | grep -q "$ARCHIPELAGO_DOMAIN"; then
    echo -e "${YELLOW}! Certificate already exists for $ARCHIPELAGO_DOMAIN${NC}"
    sudo certbot certificates | grep -A 6 "$ARCHIPELAGO_DOMAIN"
    echo ""
    read -p "Continue anyway? This will renew/recreate the certificate (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    FORCE_RENEWAL="--force-renewal"
else
    echo -e "${GREEN}✓ No existing certificate found${NC}"
    FORCE_RENEWAL=""
fi
echo ""

# Check if ports 80/443 are available
echo -e "${BLUE}Step 3: Checking port availability...${NC}"
if sudo lsof -i :80 -i :443 | grep LISTEN > /dev/null 2>&1; then
    echo -e "${YELLOW}! Ports 80/443 are in use${NC}"
    echo "The following processes are using ports 80/443:"
    sudo lsof -i :80 -i :443 | grep LISTEN || true
    echo ""
    echo "Stopping web container to free ports..."
    docker-compose stop web 2>/dev/null || docker-compose -f docker-compose-production.yml stop web 2>/dev/null || true
    sleep 3

    # Check again
    if sudo lsof -i :80 -i :443 | grep LISTEN > /dev/null 2>&1; then
        echo -e "${RED}✗ Ports still in use!${NC}"
        echo "Please manually stop the services using ports 80/443"
        exit 1
    else
        echo -e "${GREEN}✓ Ports are now available${NC}"
    fi
else
    echo -e "${GREEN}✓ Ports 80/443 are available${NC}"
fi
echo ""

# Verify DNS resolution
echo -e "${BLUE}Step 4: Verifying DNS resolution...${NC}"
if host $ARCHIPELAGO_DOMAIN > /dev/null 2>&1; then
    RESOLVED_IP=$(host $ARCHIPELAGO_DOMAIN | grep "has address" | head -1 | awk '{print $NF}')
    echo -e "${GREEN}✓ Domain resolves to: $RESOLVED_IP${NC}"

    # Get public IP
    PUBLIC_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "unknown")
    if [ "$PUBLIC_IP" != "unknown" ]; then
        echo "  Server public IP: $PUBLIC_IP"
        if [ "$RESOLVED_IP" = "$PUBLIC_IP" ]; then
            echo -e "${GREEN}✓ DNS points to this server${NC}"
        else
            echo -e "${YELLOW}! DNS does not point to this server${NC}"
            echo "  Certificate validation may fail"
            read -p "Continue anyway? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Aborted."
                exit 1
            fi
        fi
    fi
else
    echo -e "${RED}✗ Cannot resolve domain: $ARCHIPELAGO_DOMAIN${NC}"
    echo "Please ensure your domain's DNS is configured correctly"
    read -p "Continue anyway? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi
echo ""

# Obtain certificate
echo -e "${BLUE}Step 5: Obtaining Let's Encrypt certificate...${NC}"
echo "This will contact Let's Encrypt servers to obtain a certificate"
echo ""

sudo certbot certonly --standalone \
    -d $ARCHIPELAGO_DOMAIN \
    -m $ARCHIPELAGO_EMAIL \
    --agree-tos \
    --non-interactive \
    --preferred-challenges http \
    $FORCE_RENEWAL

CERTBOT_STATUS=$?

echo ""
if [ $CERTBOT_STATUS -eq 0 ]; then
    echo -e "${GREEN}✓ Certificate obtained successfully!${NC}"
else
    echo -e "${RED}✗ Certificate generation failed!${NC}"
    echo "Please check the error messages above."
    exit 1
fi
echo ""

# Verify certificate files
echo -e "${BLUE}Step 6: Verifying certificate files...${NC}"
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

if sudo test -f "/etc/letsencrypt/live/$ARCHIPELAGO_DOMAIN/cert.pem"; then
    echo -e "${GREEN}✓ cert.pem exists${NC}"
fi

if sudo test -f "/etc/letsencrypt/live/$ARCHIPELAGO_DOMAIN/chain.pem"; then
    echo -e "${GREEN}✓ chain.pem exists${NC}"
fi
echo ""

# Display certificate info
echo -e "${BLUE}Certificate Information:${NC}"
sudo openssl x509 -in "/etc/letsencrypt/live/$ARCHIPELAGO_DOMAIN/cert.pem" -noout -subject -issuer -dates 2>/dev/null || true
echo ""

# Summary
echo "================================================================"
echo -e "${GREEN}            CERTIFICATE SETUP COMPLETE!${NC}"
echo "================================================================"
echo ""
echo "Certificate files are located at:"
echo "  /etc/letsencrypt/live/$ARCHIPELAGO_DOMAIN/"
echo ""
echo "Files:"
echo "  • fullchain.pem - Full certificate chain"
echo "  • privkey.pem   - Private key"
echo "  • cert.pem      - Certificate only"
echo "  • chain.pem     - Chain only"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo "1. Switch to production configuration:"
echo "   ${BLUE}./switch-to-letsencrypt.sh${NC}"
echo ""
echo "   OR manually start production stack:"
echo "   ${BLUE}docker-compose -f docker-compose-production.yml up -d${NC}"
echo ""
echo "2. Set up automatic renewal (add to crontab):"
echo "   ${BLUE}crontab -e${NC}"
echo "   Add line:"
echo "   ${BLUE}30 2 * * * $SCRIPT_DIR/renew-certificate.sh >> /var/log/letsencrypt-renewal.log 2>&1${NC}"
echo ""
echo "3. Verify certificate in browser:"
echo "   https://$ARCHIPELAGO_DOMAIN"
echo ""
echo "Certificate will expire in 90 days and needs renewal."
echo "================================================================"
