#!/usr/bin/env bash
pkill -f "llama[-]server" && echo "stopped" || echo "was not running"
