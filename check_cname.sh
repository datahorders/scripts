#!/bin/bash

# Hardcoded expected CNAME
EXPECTED_CNAME="_acme-challenge.datahorders.org"

# Function to display usage
usage() {
    echo "Usage: $0 --domain DOMAIN"
    echo "Example: $0 --domain datahorders.org"
    exit 1
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            BASE_DOMAIN="$2"
            DOMAIN="_acme-challenge.${BASE_DOMAIN}"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

# Check if domain parameter is provided
if [ -z "$BASE_DOMAIN" ]; then
    echo "Error: --domain parameter is required"
    usage
fi

# Check if dig is installed
if ! command_exists dig; then
    echo "Error: dig command not found. Please install dig (dnsutils package)"
    exit 1
fi

# Get the CNAME record
RESULT=$(dig +short CNAME ${DOMAIN} | tr -d '"' | tr -d '.' )
EXPECTED=$(echo ${EXPECTED_CNAME} | tr -d '.' )

# Check if dig command was successful
if [ $? -ne 0 ]; then
    echo "Error: DNS query failed"
    exit 1
fi

# Check if result is empty
if [ -z "$RESULT" ]; then
    echo "Error: No CNAME record found for ${DOMAIN}"
    exit 1
fi

# Compare the result with expected value (ignoring trailing dots)
if [ "$RESULT" = "$EXPECTED" ]; then
    echo "Success: CNAME record is correctly set"
    exit 0
else
    echo "Error: CNAME record mismatch"
    echo "Expected: ${EXPECTED_CNAME}"
    echo "Got: ${RESULT}"
    exit 1
fi
