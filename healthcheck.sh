#!/bin/bash

# Add help message at the beginning
usage() {
    echo "Usage: $0 --apikey <api_key>"
    echo "  --apikey    API key for accessing the CDN endpoints"
    exit 1
}

# Parse command line arguments
api_key=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --apikey)
            api_key="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

# Validate API key is provided
if [ -z "$api_key" ]; then
    echo "Error: API key is required"
    usage
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is required but not installed. Please install jq first."
    exit 1
fi

# Define URL-ID pairs using a more compatible syntax
declare -a urls
declare -a ids
urls=(
    "https://emby.arkyncdn.net/system/info/public"
    "https://emby2.arkyncdn.net/system/info/public"
)
ids=(
    "696b66ad21364cde900cb63b5c3b5881"
    "8b4578d47c6348b18f0a0552e108e4a6"
)

# Fetch CDN locations from API
api_response=$(curl -s -H "api_key: $api_key" https://api.datahorders.org/endpoints)
if [ $? -ne 0 ]; then
    echo "Failed to fetch CDN locations from API"
    exit 1
fi

# Parse JSON response and extract endpoints array
declare -a endpoints
while IFS= read -r line; do
    endpoints+=("$line")
done < <(echo "$api_response" | jq -r '.endpoints[] | "\(.hostname):\(.ip)"')

if [ ${#endpoints[@]} -eq 0 ]; then
    echo "No endpoints found in API response"
    exit 1
fi

# Create a temporary file to store results
temp_file=$(mktemp)

# Test each URL with each endpoint asynchronously
for i in "${!urls[@]}"; do
    url="${urls[$i]}"
    expected_id="${ids[$i]}"
    domain=$(echo "$url" | awk -F[/:] '{print $4}')
    
    for endpoint in "${endpoints[@]}"; do
        IFS=':' read -r hostname ip <<< "$endpoint"
        
        # Run each test in background and write results to temp file
        (
            response=$(curl -s --resolve "$domain:443:$ip" "$url")
            if [ $? -eq 0 ] && [[ "$response" == *"$expected_id"* ]]; then
                status="SUCCESS"
            else
                status="FAILURE"
            fi
            echo "$domain:$hostname:$status" >> "$temp_file"
        ) &
    done
done

# Wait for all background processes to complete
wait

# Read results from temp file
mapfile -t results < "$temp_file"
rm "$temp_file"

# Sort results for consistent output
IFS=$'\n' results=($(sort <<<"${results[*]}"))

# Print header
printf "%-30s" "DOMAIN"
for endpoint in "${endpoints[@]}"; do
    hostname="${endpoint%%:*}"
    # Extract just the location code (e.g., 'mia-01' from 'cdn-mia-01.datahorders.org')
    location_code=$(echo "$hostname" | sed 's/cdn-\([^.]*\).*/\1/')
    printf "%-12s" "$location_code"
done
echo

# Print a separator line
printf "%-30s" "------------------------------"
for endpoint in "${endpoints[@]}"; do
    printf "%-12s" "------------"
done
echo

# Print results in a table format
current_domain=""
for result in "${results[@]}"; do
    IFS=':' read -r domain hostname status <<< "$result"
    
    if [ "$domain" != "$current_domain" ]; then
        [ -n "$current_domain" ] && echo
        printf "%-30s" "$domain"
        current_domain="$domain"
    fi
    printf "%-12s" "$status"
done
echo
