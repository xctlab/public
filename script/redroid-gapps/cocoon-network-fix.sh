#!/system/bin/sh
# Docker already assigns eth0 its IPv4 address before Android starts.
setprop cocoon.network.configured 1
exit 0
