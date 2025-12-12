# SSL Certificate Setup Guide

This guide explains how to set up and maintain Let's Encrypt SSL certificates for your Archipelago deployment.

## Quick Start

### 1. Generate Let's Encrypt Certificate

Run the setup script:

```bash
cd /home/tod/archipelago-deployment-live/deploy/ec2-docker
./setup-letsencrypt.sh
```

This will:
- Stop the web container temporarily
- Use certbot to obtain a certificate from Let's Encrypt
- Display the certificate location

### 2. Start Production Stack

After obtaining the certificate, start the production stack:

```bash
docker-compose -f docker-compose-production.yml up -d
```

### 3. Verify Certificate

Check that the certificate is working:

```bash
curl -I https://tod.vridhamma.org
```

Or check certificate details:

```bash
echo | openssl s_client -connect tod.vridhamma.org:443 -servername tod.vridhamma.org 2>&1 | grep "Verify return code"
```

You should see `Verify return code: 0 (ok)` instead of the previous error code 18.

## Automatic Certificate Renewal

Let's Encrypt certificates expire after 90 days. Set up automatic renewal:

### Add Cron Job

Run:

```bash
crontab -e
```

Add this line to check for renewal daily at 2:30 AM:

```
30 2 * * * /home/tod/archipelago-deployment-live/deploy/ec2-docker/renew-certificate.sh >> /var/log/letsencrypt-renewal.log 2>&1
```

The renewal script will:
- Check if the certificate needs renewal (certbot does this automatically)
- Renew if needed (within 30 days of expiration)
- Restart the nginx container if renewed

## Manual Certificate Renewal

To manually renew the certificate:

```bash
cd /home/tod/archipelago-deployment-live/deploy/ec2-docker
./renew-certificate.sh
```

## Troubleshooting

### Certificate Not Found

If you get certificate errors, verify the certificate exists:

```bash
sudo ls -la /etc/letsencrypt/live/tod.vridhamma.org/
```

### Port 80/443 Already in Use

If certbot fails because ports are in use:

```bash
docker-compose stop web
./setup-letsencrypt.sh
```

### Check Certificate Expiration

```bash
sudo certbot certificates
```

## Files

- `docker-compose-production.yml` - Production configuration with Let's Encrypt
- `docker-compose-selfsigned.yml` - Development/testing with self-signed certs
- `setup-letsencrypt.sh` - Initial certificate setup script
- `renew-certificate.sh` - Certificate renewal script

## Certificate Locations

- **Certificates**: `/etc/letsencrypt/live/tod.vridhamma.org/`
  - `fullchain.pem` - Full certificate chain
  - `privkey.pem` - Private key
  - `cert.pem` - Certificate only
  - `chain.pem` - Chain only

- **Nginx Config**: `/home/tod/archipelago-deployment-live/config_storage/nginxconfig/conf.d/nginx.conf`
  - Configured to use Let's Encrypt certificates

## Switching Between Self-Signed and Let's Encrypt

### Use Self-Signed (Development)
```bash
docker-compose -f docker-compose-selfsigned.yml up -d
```

### Use Let's Encrypt (Production)
```bash
docker-compose -f docker-compose-production.yml up -d
```
