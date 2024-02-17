#!/bin/sh

# VERBOSE="${VERBOSE:-1}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-teeworlds/teeworlds}"
DOWNSTREAM_REMOTE="${DOWNSTREAM_REMOTE:-teeworlds-community/teeworlds}"
DOWNSTREAM_BRANCH="${DOWNSTREAM_BRANCH:-community}"

KNOWN_URLS_FILE=urls.txt
GH_URLS_FILE=tmp/gh_urls.txt

err() {
	printf '[-][%s] %s\n' "$(date '+%F %H:%M')" "$1"
}
log() {
	printf '[*][%s] %s\n' "$(date '+%F %H:%M')" "$1"
}
dbg() {
	[ "$VERBOSE" = "" ] && return

	printf '[DEBUG][%s] %s\n' "$(date '+%F %H:%M')" "$1"
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
[ ! -f "$KNOWN_URLS_FILE" ] && :>"$KNOWN_URLS_FILE"

# https://stackoverflow.com/questions/38015239/url-encoding-a-string-in-shell-script-in-a-portable-way/38021063#38021063
urlencodepipe() {
    LANG=C;
    while IFS= read -r c;
    do
        case $c in [a-zA-Z0-9.~_-]) printf "%s" "$c"; continue ;; esac
        printf "%s" "$c" | od -An -tx1 | tr ' ' % | tr -d '\n'
    done <<EOF
$(fold -w1)
EOF
    echo
}
urlencode() {
	printf '%s\n' "$*" | urlencodepipe
}

get_upstream_prs() {
	# example output:
	# https://github.com/teeworlds/teeworlds/pull/2931 datafile-exceptions:Robyt3
	# https://github.com/teeworlds/teeworlds/pull/2950 harpoon-draft-pr:Stiopa866
	gh pr list \
		--limit 90000 \
		--repo "$UPSTREAM_REMOTE" \
		--state open \
		--json headRepositoryOwner,headRefName,url,title |
		jq -r '.[] | "\(.url) \(.headRepositoryOwner.login):\(.headRefName) \(.title)"' |
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

create_pr() {
	url="$1"
	ref="$2"
	title="$3"
	pr_id="${url##*/}"
	# https://github.com/orgs/community/discussions/23123#discussioncomment-3239240
	url="https://www.github.com${url#*https://github.com}"
	dbg "url=$url ref=$ref pr_id=$pr_id title=$title"

	manual_url="https://github.com/$DOWNSTREAM_REMOTE/compare/$DOWNSTREAM_BRANCH...$ref"
	manual_url="$manual_url?expand=1&title=$(urlencode "$title #$pr_id")&body=$(urlencode "upstream: $url")"
	# printf '%s\n' "$manual_url"
	# ${BROWSER:-echo} "$manual_url"

	gh pr create \
		--repo "$DOWNSTREAM_REMOTE" \
		--base "$DOWNSTREAM_BRANCH" \
		--head "$ref" \
		--title "$title #$pr_id" \
		--body "upstream: $url" \
		--no-maintainer-edit
}

on_new_pr() {
	url="$1"
	shift
	ref="$1"
	shift
	title="$*"
	if grep -qF "$url" "$KNOWN_URLS_FILE"
	then
		dbg "skipping known url=$url"
		return
	fi
	printf '%s\n' "$url" >> "$KNOWN_URLS_FILE"
	log "new url=$url ref=$ref title=$title"
	create_pr "$url" "$ref" "$title"
}

get_new_known_form_gh() {
	gh_prs="$(gh pr list \
		--limit 90000 \
		--state all \
		--repo "$DOWNSTREAM_REMOTE" \
		--json title,body)"
	title_ids="$(printf '%s\n' "$gh_prs" |
		jq '.[] | .title' -r |
		grep -Eo " #[1-9][0-9][0-9][0-9]+$" |
		cut -d'#' -f2)"
	body_ids="$(printf '%s\n' "$gh_prs" |
		jq '.[] | .body' |
		grep -Eo "\"upstream: https://www.github.com/$UPSTREAM_REMOTE/pull/[0-9]+(\\\\r|\"$)" |
		grep -Eo 'pull/[0-9]+' |
		cut -d'/' -f2)"
	printf '%s\n%s\n' "$title_ids" "$body_ids" | while IFS= read -r gh_id
	do
		[ "$gh_id" = "" ] && continue

		if ! grep -qF "$gh_id" "$KNOWN_URLS_FILE"
		then
			url="https://github.com/$UPSTREAM_REMOTE/pull/$gh_id"
			printf '%s\n' "$url" >> "$KNOWN_URLS_FILE"
			log "new pull id found on $DOWNSTREAM_REMOTE id=$gh_id"
		fi
	done
}

check_for_new() {
	get_upstream_prs > "$GH_URLS_FILE"
	sort_file "$GH_URLS_FILE"
	sort_file "$KNOWN_URLS_FILE"

	while IFS= read -r new
	do
		# we word split new into url and ref
		# shellcheck disable=SC2086
		on_new_pr $new
	done < "$GH_URLS_FILE"
}

log "checking for new pulls on own remote ..."
get_new_known_form_gh
log "checking for new pulls on upstream remote ..."
check_for_new
log "done."

