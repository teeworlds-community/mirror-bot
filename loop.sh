#!/bin/sh

SLEEP_MINUTES=15

log() {
	printf '[*][%s] %s\n' "$(date '+%F %H:%M')" "$1"
}

while ARG_DRY=0 ./mirror-bot.sh
do
	git add urls.txt
	git commit -m 'auto sync' && git push
	log "sleeping for $SLEEP_MINUTES minutes"
	sleep "$SLEEP_MINUTES"m
done

exit 1

