#!/bin/bash

# File containing the list of NTP servers
SERVER_LIST="ntp_servers.txt"

# Check if the server list file exists
if [ ! -f "$SERVER_LIST" ]; then
    echo "Server list file not found: $SERVER_LIST"
    exit 1
fi

# Function to perform NTP metrics test and return the best server
get_ntp_metrics() {
    local server=$1
    local ntp_output=$(ntpdate -q $server 2>&1)

    if echo "$ntp_output" | grep -q "delay"; then
        echo "$ntp_output" | awk -F 'delay ' '{print $2}' | awk '{print $1}' | awk '{sum+=$1; count++} END {if (count>0) print sum/count; else print "timeout"}'
    else
        echo "timeout"
    fi
}

# Create a temporary file for results
TMP_FILE=$(mktemp)

# Read each server from the file and get its NTP delay
while IFS= read -r server
do
    echo "Testing $server..."
    avg_delay=$(get_ntp_metrics $server)
    echo "Resulting delay for $server: $avg_delay"
    if [[ "$avg_delay" != "timeout" ]]; then
        echo "$avg_delay $server" >> "$TMP_FILE"
    fi
done < "$SERVER_LIST"

# Sort servers by the calculated score and print the top 5
echo "Top 5 NTP Servers Based on Delay:"
TOP_SERVERS=$(sort -k1 -n "$TMP_FILE" | head -n 5)
echo "$TOP_SERVERS"

# Check if TOP_SERVERS is empty
if [ -z "$TOP_SERVERS" ]; then
    echo "No valid NTP servers found."
    exit 1
fi

# Generate Chrony config with the top servers
CONFIG_FILE="chrony.conf"
echo "# Generated Chrony Config" > "$CONFIG_FILE"

# Ensure TOP_SERVERS variable is not empty
if [ -z "$TOP_SERVERS" ]; then
    echo "No valid NTP servers found."
    exit 1
fi

# Loop over each line in TOP_SERVERS to extract server addresses
while read -r delay server; do
    if [ -n "$server" ]; then
        # Assuming $server contains the domain name directly from the SERVER_LIST
        echo "pool $server iburst minpoll 1 maxpoll 1 maxsources 4 maxdelay 0.2" >> "$CONFIG_FILE"
    else
        echo "Error: Invalid server address extracted."
    fi
done <<< "$TOP_SERVERS"


cat >> "$CONFIG_FILE" << EOF

pool time.google.com iburst minpoll 1 maxpoll 1 maxsources 4 maxdelay 0.2

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
