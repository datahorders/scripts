#!/bin/bash

# Certificate Upload Script
#
# This script helps upload certificates to the API, with automatic domain detection.
#
# Usage:
#   ./upload-certificate.sh --name "My Cert" --acme-dir ~/.acme.sh/example.com_ecc [--force-update]
#
# Required parameters:
#   --name       Certificate name
#   --acme-dir   Path to acme.sh certificate directory
#
# Optional parameters:
#   --token      API token (default: uses API_TOKEN env var)
#   --url        API URL (default: https://dashboard.datahorders.org/api/v1/certificates)
#   --force-update  Force update if certificate already exists

set -e

# Default values
API_URL=${API_URL:-"https://dashboard.datahorders.org/api/v1/certificates"}
API_TOKEN=${API_TOKEN:-""}
FORCE_UPDATE="false"

# Check for required tools
if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but not installed. Please install jq."
  exit 1
fi

# Function to extract domains from certificate
extract_domains() {
  local cert_file="$1"
  # Extract Subject Alternative Names
  local domains=$(openssl x509 -noout -text -in "$cert_file" | grep -A1 "Subject Alternative Name" | grep "DNS:" | sed 's/DNS://g')
  
  # If no SANs, try to extract Common Name
  if [ -z "$domains" ]; then
    domains=$(openssl x509 -noout -subject -in "$cert_file" | grep -o "CN = [^,]*" | sed 's/CN = //')
  else
    # Process the domain list to create proper output
    # This will convert "DNS:example.com, DNS:*.example.com" to separate lines
    # First replace commas with newlines
    domains=$(echo "$domains" | tr ',' '\n' | sed 's/^ *//' | grep -v "^$")
  fi
  
  echo "$domains"
}

# Function to print usage
print_usage() {
  echo "Usage:"
  echo "  $0 --name \"My Cert\" --acme-dir ~/.acme.sh/example.com_ecc [options]"
  echo ""
  echo "Required options:"
  echo "  --name NAME           Certificate name"
  echo "  --acme-dir DIR        Path to acme.sh certificate directory"
  echo ""
  echo "Optional options:"
  echo "  --url URL             API URL (default: $API_URL or API_URL env var)"
  echo "  --token TOKEN         API token (default: API_TOKEN env var)"
  echo "  --force-update        Force update if certificate already exists (default: false)"
  echo "  --help                Show this help message"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --name)
      NAME="$2"
      shift 2
      ;;
    --acme-dir)
      ACME_DIR="$2"
      shift 2
      ;;
    --url)
      API_URL="$2"
      shift 2
      ;;
    --token)
      API_TOKEN="$2"
      shift 2
      ;;
    --force-update)
      FORCE_UPDATE="true"
      shift
      ;;
    --help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
done

# Validate required options
if [ -z "$NAME" ]; then
  echo "Error: --name is required"
  print_usage
  exit 1
fi

if [ -z "$ACME_DIR" ]; then
  echo "Error: --acme-dir is required"
  print_usage
  exit 1
fi

# Handle acme.sh directory
if [ ! -d "$ACME_DIR" ]; then
  echo "Error: acme.sh directory not found: $ACME_DIR"
  exit 1
fi

# Detect domain from directory name
DOMAIN_FROM_DIR=$(basename "$ACME_DIR" | sed 's/_ecc$//')

# Find certificate and key files
CERT_PATH=""
KEY_PATH=""

# Check for fullchain.cer first (preferred)
if [ -f "$ACME_DIR/fullchain.cer" ]; then
  CERT_PATH="$ACME_DIR/fullchain.cer"
elif [ -f "$ACME_DIR/cert.pem" ]; then
  CERT_PATH="$ACME_DIR/cert.pem"
fi

# Look for key file
if [ -f "$ACME_DIR/$DOMAIN_FROM_DIR.key" ]; then
  KEY_PATH="$ACME_DIR/$DOMAIN_FROM_DIR.key"
elif [ -f "$ACME_DIR/private.key" ]; then
  KEY_PATH="$ACME_DIR/private.key"
fi

if [ -z "$CERT_PATH" ] || [ -z "$KEY_PATH" ]; then
  echo "Error: Could not find certificate or key files in acme.sh directory: $ACME_DIR"
  echo "Expected files: fullchain.cer and $DOMAIN_FROM_DIR.key"
  exit 1
fi

echo "Found certificate: $CERT_PATH"
echo "Found key: $KEY_PATH"

# Auto-detect domains from certificate
echo "Auto-detecting domains from certificate..."
DOMAINS=$(extract_domains "$CERT_PATH")

if [ -z "$DOMAINS" ]; then
  echo "Error: Could not detect domains from certificate."
  exit 1
fi

# Convert the domains from newlines to an array for JSON
DOMAINS_ARRAY=$(echo "$DOMAINS" | jq -R . | jq -s .)

echo "Detected domains:" 
echo "$DOMAINS" | sed 's/^/  - /'  # Show domains nicely formatted

# Use absolute paths
CERT_PATH=$(realpath "$CERT_PATH")
KEY_PATH=$(realpath "$KEY_PATH")

# Read certificate and key contents
echo "Reading certificate and key contents..."
CERT_CONTENT=$(cat "$CERT_PATH")
KEY_CONTENT=$(cat "$KEY_PATH")

# Check if certificate content is properly PEM encoded
if ! echo "$CERT_CONTENT" | grep -q "BEGIN CERTIFICATE"; then
  echo "Error: Certificate content doesn't appear to be in PEM format"
  echo "Certificate should start with -----BEGIN CERTIFICATE-----"
  exit 1
fi

if ! echo "$KEY_CONTENT" | grep -q "BEGIN PRIVATE KEY\|BEGIN RSA PRIVATE KEY\|BEGIN EC PRIVATE KEY"; then
  echo "Error: Key content doesn't appear to be in PEM format"
  echo "Key should start with -----BEGIN PRIVATE KEY----- or similar"
  exit 1
fi

# Create JSON with file contents for manual certificate
JSON=$(cat <<EOF
{
  "name": "$NAME",
  "domains": $DOMAINS_ARRAY,
  "provider": "manual",
  "certContent": $(jq -Rs . <<<"$CERT_CONTENT"),
  "keyContent": $(jq -Rs . <<<"$KEY_CONTENT"),
  "autoRenew": false
}
EOF
)

# Set up headers
HEADERS=(-H "Content-Type: application/json")
if [ -n "$API_TOKEN" ]; then
  # Use Authorization header for API token authentication
  HEADERS+=(-H "Authorization: Bearer $API_TOKEN")
else
  echo "Warning: No API token provided. Authentication may fail."
fi

# First, check if certificate already exists for any of the domains
echo "Checking if certificate already exists for domains..."
FIRST_DOMAIN=$(echo "$DOMAINS" | head -n 1)
DOMAIN_CHECK_URL="${API_URL}?domain=${FIRST_DOMAIN}"
EXISTING_CERT_RESPONSE=$(curl -s -X GET "${DOMAIN_CHECK_URL}" "${HEADERS[@]}")

# Check if we got a successful response with a certificate
if echo "$EXISTING_CERT_RESPONSE" | jq -e '.success == true' > /dev/null; then
  echo "Certificate already exists for domain: $FIRST_DOMAIN"
  
  if [ "$FORCE_UPDATE" = "true" ]; then
    echo "Force update requested, proceeding with PUT request..."
    HTTP_METHOD="PUT"
    API_ENDPOINT="${API_URL}?domain=${FIRST_DOMAIN}"
  else
    echo "Use --force-update to update the existing certificate."
    echo "Existing certificate details:"
    echo "$EXISTING_CERT_RESPONSE" | jq '.data'
    exit 0
  fi
else
  echo "No existing certificate found for domain, creating new certificate..."
  HTTP_METHOD="POST"
  API_ENDPOINT="${API_URL}"
fi

# Make the API request
echo "Sending request to: $API_ENDPOINT"
echo "Request method: $HTTP_METHOD"
echo "Request data: $(echo "$JSON" | jq 'del(.certContent, .keyContent)') [certificate and key contents omitted]"

# Use curl to make the request - capture both response and status code in one call
TEMP_RESPONSE_FILE=$(mktemp)
HEADERS_FILE=$(mktemp)
HTTP_CODE=$(curl -s -w "%{http_code}" -X "$HTTP_METHOD" "${API_ENDPOINT}" \
  "${HEADERS[@]}" \
  -D "$HEADERS_FILE" \
  -d "$JSON" -o "$TEMP_RESPONSE_FILE")
RESPONSE=$(cat "$TEMP_RESPONSE_FILE")

echo "Response Status: $HTTP_CODE"
echo "Response Body:"
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"

# Clean up temporary files
rm "$HEADERS_FILE" "$TEMP_RESPONSE_FILE"

# Handle response based on status code and response content
if [[ $HTTP_CODE -ge 200 && $HTTP_CODE -lt 300 ]]; then
  if echo "$RESPONSE" | jq -e '.success == true' > /dev/null; then
    if [ "$HTTP_METHOD" = "PUT" ]; then
      echo -e "\nCertificate updated successfully!"
    else
      echo -e "\nCertificate uploaded successfully!"
    fi
    exit 0
  else
    echo -e "\nUnexpected response format. Please check the response."
    exit 1
  fi
else
  # Check for specific error codes
  ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error.code // "UNKNOWN_ERROR"')
  ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown error occurred"')
  
  echo -e "\nError: $ERROR_MSG (Code: $ERROR_CODE)"
  
  if [ "$ERROR_CODE" = "DUPLICATE_DOMAIN_CERTIFICATE" ]; then
    EXISTING_CERT_ID=$(echo "$RESPONSE" | jq -r '.error.data.existingCertificateId // "unknown"')
    echo -e "A certificate already exists for one or more domains."
    echo -e "Existing certificate ID: $EXISTING_CERT_ID"
    echo -e "You must delete this certificate before proceeding."
  fi
  
  exit 1
fi 
