#!/bin/bash

echo "Unblocking: $1"
ufw show added \ | awk -v myip="$1" '$0 ~ myip{ gsub("ufw","ufw delete",$0); system($0) }'
exit 0