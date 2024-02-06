#!/bin/sh

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-teeworlds/teeworlds}"
DOWNSTREAM_REMOTE="${DOWNSTREAM_REMOTE:-teeworlds-community/teeworlds}"

KNOWN_URLS_FILE=urls.txt
GH_URLS_FILE=tmp/gh_urls.txt
NEW_URLS_FILE=tmp/new_urls.txt

err() {
	printf '[-][%s] %s\n' "$(date '+%F %H:%M')" "$1"
}
log() {
	printf '[*][%s] %s\n' "$(date '+%F %H:%M')" "$1"
}

# everything not in here should be passed to check_dep
# https://pubs.opengroup.org/onlinepubs/9699919799/utilities/contents.html
# https://pubs.opengroup.org/onlinepubs/009695399/idx/utilities.html
check_dep() {
	[ -x "$(command -v "$1")" ] && return
	err "Error: missing dependency $1"
	exit 1
}

check_dep gh
check_dep jq

mkdir -p tmp

:>"$GH_URLS_FILE"
:>"$NEW_URLS_FILE"
[ ! -f "$KNOWN_URLS_FILE" ] && :>"$KNOWN_URLS_FILE"

get_upstream_prs() {
	# example output:
	# https://github.com/teeworlds/teeworlds/pull/2931 datafile-exceptions:Robyt3
	# https://github.com/teeworlds/teeworlds/pull/2950 harpoon-draft-pr:Stiopa866
	gh pr list \
		--repo "$UPSTREAM_REMOTE" \
		--state open \
		--json headRepositoryOwner,headRefName,url |
		jq -r '.[] | "\(.url) \(.headRefName):\(.headRepositoryOwner.login)"' |
		sort
}

sort_file() {
	file_path="$1"
	if [ -f "$file_path".tmp ]
	then
		err "Error: failed to sort $file_path"
		err "       not overwriting $file_path.tmp"
		err "       you may want to remove that file manually"
		exit 1
	fi
	sort "$file_path" > "$file_path".tmp
	mv "$file_path".tmp "$file_path"
}

new_pr() {
	pr_info="$1"
	log "new url=$pr_info"
	printf '%s\n' "$url" >> "$KNOWN_URLS_FILE"
}

check_for_new() {
	get_upstream_prs > "$GH_URLS_FILE"
	sort_file "$GH_URLS_FILE"
	sort_file "$KNOWN_URLS_FILE"
	comm -23 "$GH_URLS_FILE" "$KNOWN_URLS_FILE" > "$NEW_URLS_FILE"

	while read -r new
	do
		new_pr "$new"
	done < "$NEW_URLS_FILE"
}

check_for_new

