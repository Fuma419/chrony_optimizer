#!/bin/bash

# File containing the list of NTP servers
SERVER_LIST="ntp_servers.txt"

# Check if the server list file exists
if [ ! -f "$SERVER_LIST" ]; then
    echo "Server list file not found: $SERVER_LIST"
    exit 1
fi

# Function to get ping time with 1-second timeout
get_ping_time() {
    local server=$1
    # Ping the server with a timeout of 1 second
    local result=$(ping -c 1 -W 1 $server 2>&1) # Redirect stderr to stdout
    if echo "$result" | grep -q 'time='; then
        echo "$result" | grep 'time=' | awk -F'=' '{ print $4 }' | cut -d ' ' -f 1
    else
        echo "timeout"
    fi
}

# Create a temporary file for sorting
TMP_FILE=$(mktemp)

# Read each server from the file and get its ping time
while IFS= read -r server
do
    echo "Pinging $server..."
    ping_time=$(get_ping_time $server)
    if [ "$ping_time" != "timeout" ]; then
        echo "$ping_time $server" >> "$TMP_FILE"
    else
        echo "No response or timeout from $server"
    fi
done < "$SERVER_LIST"

# Sort the results by ping time and print
echo "Ping Results:"
cat "$TMP_FILE" | sort -n | while read -r line; do
    echo "$line ms"
done

# Take top 4 servers and generate chrony config
TOP_SERVERS=$(sort -n "$TMP_FILE" | head -n 4 | awk '{print $2}')

CONFIG_FILE="$HOME/chrony.conf"
cat > "$CONFIG_FILE" << EOF
# Generated Chrony Config
EOF

for server in $TOP_SERVERS
do
    echo "pool $server iburst minpoll 1 maxpoll 1 maxsources 3 maxdelay 0.3" >> "$CONFIG_FILE"
done

cat >> "$CONFIG_FILE" << EOF
# Other Chrony settings
# This directive specify the location of the file containing ID/key pairs for
# NTP authentication.
keyfile /etc/chrony/chrony.keys

# This directive specify the file into which chronyd will store the rate
# information.
driftfile /var/lib/chrony/chrony.drift

# Uncomment the following line to turn logging on.
#log tracking measurements statistics

# Log files location.
logdir /var/log/chrony

# Stop bad estimates upsetting machine clock.
maxupdateskew 5.0

# This directive enables kernel synchronisation (every 11 minutes) of the
# real-time clock. Note that it can’t be used along with the 'rtcfile' directive.
rtcsync

# Step the system clock instead of slewing it if the adjustment is larger than
# one second, but only in the first three clock updates.
makestep 0.1 -1

leapsectz right/UTC

local stratum 10
EOF

# Move the file to /etc/chrony/ and restart chronyd service
sudo mv "$CONFIG_FILE" /etc/chrony/chrony.conf
sudo systemctl restart chronyd.service

# Clean up: Remove the temporary file
rm "$TMP_FILE"
