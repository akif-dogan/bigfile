#!/bin/bash

# Function to display help
display_help() {
    echo "Usage: $0 [<extra flags>]"
    echo "   <extra flags>: start_from_block <block> or start_from_latest_state is required when "
    echo "                  launching the pilot node with the start_from_block flag."
}

BIGFILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! $BIGFILE_DIR/testnet/assert_testnet.sh; then
	echo "Error: This script must be run on a testnet server."
	exit 1
fi

if [[ ! -f "/bigfile-build/testnet/bin/start" ]]; then
    echo "Bigfile start script not found. Please run rebuild_testnet.sh first."
	exit 1
fi

node=$(hostname -f)
config_file="$BIGFILE_DIR/testnet/config/$(hostname -f).json"
blacklist="transaction_blacklist_url \"${BLACKLIST_URL}\""
SCREEN_CMD="screen -dmsL bigfile /bigfile-build/testnet/bin/start $blacklist config_file $config_file $*"

echo "$SCREEN_CMD"
echo "$SCREEN_CMD" > /bigfile-build/testnet/run.sh
chmod +x /bigfile-build/testnet/run.sh

cd /bigfile-build/testnet
./run.sh
