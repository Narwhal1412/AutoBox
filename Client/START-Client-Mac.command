#!/bin/sh
cd "$(dirname "$0")" || exit 1
sh ./client.sh
printf '\nYou can close this window now.\n'
