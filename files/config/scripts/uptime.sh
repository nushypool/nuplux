#!/usr/bin/env bash
uptime | awk '{print $(NF-2)}' | sed 's/,//'
