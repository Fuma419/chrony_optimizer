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
    local result=$(ping -c 1 -W 1 $server 2>&1)
    if echo "$result" | grep -q 'time='; then
        echo "$result" | grep 'time=' | awk -F'=' '{ print $4 }' | cut -d ' ' -f 1
    else
        echo "timeout"
    fi
}

# Function to perform NTP metrics test
get_ntp_metrics() {
    local server=$1
    local ntp_output=$(ntpdate -q $server 2>&1)
    if echo "$ntp_output" | grep -q "offset"; then
        # Use awk to calculate the average offset and delay
        echo "$ntp_output" | grep "offset" | awk '{offsetSum += $6; delaySum += $8; count++} END {if (count > 0) print offsetSum/count, delaySum/count; else print "timeout timeout"}'
    else
        echo "timeout timeout"
    fi
}

# Create a temporary file for results
TMP_FILE=$(mktemp)

# Read each server from the file and get its ping time and NTP metrics
while IFS= read -r server
do
    echo "Testing $server..."
    ping_time=$(get_ping_time $server)
    read offset delay <<< $(get_ntp_metrics $server)
    if [[ "$ping_time" != "timeout" && "$offset" != "timeout" && "$delay" != "timeout" ]]; then
        # Convert values to positive and check if they are numbers
        ping_time=$(echo "$ping_time" | tr -d '-')
        offset=$(echo "$offset" | tr -d '-')
        delay=$(echo "$delay" | tr -d '-')

        if [[ "$ping_time" =~ ^[0-9]+([.][0-9]+)?$ && "$offset" =~ ^[0-9]+([.][0-9]+)?$ && "$delay" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            score=$(echo "scale=2; 1/$ping_time + 1/$offset + 1/$delay" | bc -l)
            echo "$score $server" >> "$TMP_FILE"
        else
            echo "Invalid measurement for $server"
        fi
    else
        echo "Timeout or error for $server"
    fi
done < "$SERVER_LIST"

# Sort servers by the calculated score and print the top 10
echo "Top 10 NTP Servers Based on Score:"
TOP_SERVERS=$(sort -r -n "$TMP_FILE" | head -n 5)
echo "$TOP_SERVERS"

# Generate Chrony config with the top 4 servers
CONFIG_FILE="chrony.conf"
cat > "$CONFIG_FILE" << EOF
# Generated Chrony Config
EOF

for server in $(echo "$TOP_SERVERS" | awk '{print $2}')
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
