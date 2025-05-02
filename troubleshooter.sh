#!/bin/bash
# Author: Morgan Habecker

# This script performs the following checks:
# 1. Gathers system information (OS, memory, disk space, processors)
# 2. Tests HTTPS connectivity to prod.cymbiotic.io (port 443)
# 3. Tests SSH connectivity to bridge.cymbiotic.io on port 443
# 4. Checks for DNS resolution errors via apt update and hostname consistency
# 5. Calls the get_consultants API (if Cymbiotic is installed)

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

system_info() {
    echo -e "\n${YELLOW}Gathering System Information...${NC}"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo -e "${GREEN}OS:${NC} ${PRETTY_NAME}"
    else
        echo -e "${RED}OS Information not available${NC}"
    fi

    echo -e "\n${YELLOW}Memory Information:${NC}"
    free -h | grep -E "^Mem:" | awk '{print "Total: " $2 "\nUsed: " $3 "\nFree: " $4}'

    echo -e "\n${YELLOW}Disk Space Information (root partition):${NC}"
    df -h / | awk 'NR==2 {print "Total: " $2 "\nAvailable: " $4}'

    echo -e "\n${YELLOW}Processor Information:${NC}"
    echo "Number of processors: $(nproc)"

    echo ""
}

test_https() {
    echo -e "\n${YELLOW}Testing connectivity to prod.cymbiotic.io on port 443 (HTTPS)...${NC}"
    if nc -z -w 5 prod.cymbiotic.io 443; then
        echo -e "${GREEN}Success:${NC} Able to connect to prod.cymbiotic.io on port 443."
    else
        echo -e "${RED}Error:${NC} Unable to connect to prod.cymbiotic.io on port 443."
    fi
    echo ""
}

test_ssh() {
    echo -e "\n${YELLOW}Testing SSH connectivity to bridge.cymbiotic.io on port 443...${NC}"
    if ssh -o BatchMode=yes \
           -o ConnectTimeout=5 \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -v \
           -p 443 bridge.cymbiotic.io exit 2>&1 \
       | grep -q "Authentications that can continue"; then
        echo -e "${GREEN}Success:${NC} Able to connect to the bridge over SSH on port 443."
    else
        echo -e "${RED}Error:${NC} Unable to connect to bridge.cymbiotic.io on port 443 over SSH."
    fi
    echo ""
}

test_dns() {
    echo -e "\n${YELLOW}Checking for DNS resolution errors via 'apt update'...${NC}"

    update_output=$(apt update 2>&1)
    if echo "$update_output" | grep -qi "unable to resolve host"; then
        echo -e "${RED}DNS Error:${NC} 'unable to resolve host' found in apt update output."
    else
        echo -e "${GREEN}No DNS resolution errors detected in apt update output.${NC}"
    fi

    echo -e "\n${YELLOW}Checking hostname consistency...${NC}"
    hostname=$(tr -d '[:space:]' < /etc/hostname)
    if grep -q "127.0.1.1.*$hostname" /etc/hosts; then
        echo -e "${GREEN}Hostname check passed:${NC} '$hostname' is correctly mapped in /etc/hosts."
    else
        echo -e "${RED}Hostname check FAILED:${NC} /etc/hosts does not have the proper entry for '$hostname'."
        echo -e "${YELLOW}Solution:${NC} Edit /etc/hosts and ensure there is a line like:"
        echo "127.0.1.1 $hostname"
        echo "Then reboot the system."
    fi
    echo ""
}

test_consultants_api() {
    local conf_file="/usr/local/bin/cymbiotic/conf/env.conf"
    local pubkey_file="/home/rpa/.ssh/id_ed25519.pub"
    local api_host api_token device_id url http_code curl_exit tmpfile

    # If Cymbiotic isn't installed, skip this test
    if [[ ! -r "$conf_file" || ! -r "$pubkey_file" ]]; then
        echo -e "${RED}UH OH! Cymbiotic is not installed. Please run the install command provided by your point of contact.${NC}"
        echo ""
        return 0
    fi

    # load API_HOST & API_AUTH_TOKEN
    api_host=$(sed -n 's/^API_HOST="\([^"]*\)"/\1/p' "$conf_file")
    api_token=$(sed -n 's/^API_AUTH_TOKEN="\([^"]*\)"/\1/p' "$conf_file")
    if [[ -z "$api_host" || -z "$api_token" ]]; then
        echo -e "${RED}Error:${NC} API_HOST or API_AUTH_TOKEN missing in $conf_file"
        echo ""
        return 1
    fi

    # extract device_id from the public key
    device_id=$(awk '{print $NF}' "$pubkey_file")
    url="$api_host/api/get_authorized_keys/$device_id"

    echo -e "\n${YELLOW}Testing API at:${NC} $url"

    # call the API
    tmpfile=$(mktemp)
    http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        -H "Api-Token: $api_token" \
        --max-time 5 \
        "$url")
    curl_exit=$?

    if [[ $curl_exit -ne 0 ]]; then
        echo -e "${RED}Error:${NC} Unable to connect to $url"
    elif [[ "$http_code" != "200" ]]; then
        echo -e "${RED}Error:${NC} HTTP $http_code"
        cat "$tmpfile"
    else
        echo -e "${GREEN}Success:${NC} Authorized keys:"
        resp=$(tr -d '\n' < "$tmpfile")
        keys_raw=$(echo "$resp" \
            | sed -e 's/.*"authorized_keys"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/')
        IFS=',' read -ra keys_array <<< "$keys_raw"
        for key in "${keys_array[@]}"; do
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            key="${key#\"}"
            key="${key%\"}"
            echo "$key"
        done
    fi

    rm -f "$tmpfile"
    echo ""
}

echo -e "\n================= System Information =================\n"
system_info

echo -e "================= Troubleshooting Tests =================\n"
test_https
echo "-----------------------------------------------------"
test_consultants_api
echo "-----------------------------------------------------"
test_ssh
echo "-----------------------------------------------------"
test_dns
echo -e "================= Tests Completed =================\n"
