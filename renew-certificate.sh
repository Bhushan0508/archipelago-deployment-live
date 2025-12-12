#!/bin/bash
# Renew Let's Encrypt SSL Certificate for Archipelago
# This script checks and renews the Let's Encrypt certificate if needed
# Typically run via cron job daily

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
echo "   Let's Encrypt Certificate Renewal Check"
echo "================================================================"
echo "Domain: $ARCHIPELAGO_DOMAIN"
echo "Date: $(date)"
echo ""

# Check if certbot is installed
if ! command -v certbot &> /dev/null; then
    echo -e "${RED}Error: certbot is not installed!${NC}"
    exit 1
fi

# Check certificate expiration
echo -e "${BLUE}Checking certificate status...${NC}"
if sudo certbot certificates 2>&1 | grep -q "$ARCHIPELAGO_DOMAIN"; then
    echo -e "${GREEN}✓ Certificate found for $ARCHIPELAGO_DOMAIN${NC}"

    # Get certificate details
    CERT_INFO=$(sudo certbot certificates | grep -A 6 "$ARCHIPELAGO_DOMAIN")
    echo "$CERT_INFO"
    echo ""

    # Extract expiry date
    EXPIRY_DATE=$(echo "$CERT_INFO" | grep "Expiry Date:" | sed 's/.*Expiry Date: //')
    if [ -n "$EXPIRY_DATE" ]; then
        echo "Certificate expires: $EXPIRY_DATE"

        # Calculate days until expiry
        EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || echo "0")
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( ($EXPIRY_EPOCH - $NOW_EPOCH) / 86400 ))

        if [ $DAYS_LEFT -gt 30 ]; then
            echo -e "${GREEN}Certificate is valid for $DAYS_LEFT more days${NC}"
        elif [ $DAYS_LEFT -gt 0 ]; then
            echo -e "${YELLOW}Certificate expires in $DAYS_LEFT days - renewal will be attempted${NC}"
        else
            echo -e "${RED}Certificate has expired!${NC}"
        fi
    fi
else
    echo -e "${RED}✗ No certificate found for $ARCHIPELAGO_DOMAIN${NC}"
    exit 1
fi
echo ""

# Attempt renewal
echo -e "${BLUE}Attempting certificate renewal...${NC}"
echo "Note: Certbot will only renew if certificate expires within 30 days"
echo ""

# Run certbot renew with deploy hook to restart nginx
RENEWAL_OUTPUT=$(sudo certbot renew --deploy-hook "docker restart esmero-web" 2>&1)
RENEWAL_STATUS=$?

echo "$RENEWAL_OUTPUT"
echo ""

if [ $RENEWAL_STATUS -eq 0 ]; then
    if echo "$RENEWAL_OUTPUT" | grep -q "No renewals were attempted"; then
        echo -e "${GREEN}✓ Certificate is still valid - no renewal needed${NC}"
    elif echo "$RENEWAL_OUTPUT" | grep -q "Successfully renewed"; then
        echo -e "${GREEN}✓ Certificate renewed successfully!${NC}"
        echo "Nginx container has been restarted"

        # Verify the new certificate is working
        echo ""
        echo -e "${BLUE}Verifying renewed certificate...${NC}"
        sleep 5

        VERIFY_RESULT=$(echo | openssl s_client -connect $ARCHIPELAGO_DOMAIN:443 -servername $ARCHIPELAGO_DOMAIN 2>&1 | grep "Verify return code")
        echo "$VERIFY_RESULT"

        if echo "$VERIFY_RESULT" | grep -q "Verify return code: 0 (ok)"; then
            echo -e "${GREEN}✓ Certificate is valid and trusted!${NC}"
        else
            echo -e "${YELLOW}! Certificate verification returned non-zero code${NC}"
        fi
    else
        echo -e "${GREEN}✓ Renewal check completed successfully${NC}"
    fi
else
    echo -e "${RED}✗ Certificate renewal failed!${NC}"
    echo "Please check the error messages above"
    exit 1
fi

echo ""
echo "================================================================"
echo -e "${GREEN}                  RENEWAL CHECK COMPLETE${NC}"
echo "================================================================"
echo ""
echo "Next renewal check: $(date -d '+1 day')"
echo ""
