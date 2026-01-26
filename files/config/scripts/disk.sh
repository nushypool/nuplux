#!/usr/bin/env bash
df -h / | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}'
