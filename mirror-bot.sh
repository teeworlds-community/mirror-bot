#!/bin/sh

# shellcheck disable=SC1091
[ -f .env ] && . ./.env

# VERBOSE="${VERBOSE:-1}"
ARG_DRY="${ARG_DRY:-1}"
GH_BOT_USERNAME="${GH_BOT_USERNAME:-teeworlds-mirror}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-teeworlds/teeworlds}"
DOWNSTREAM_REMOTE="${DOWNSTREAM_REMOTE:-teeworlds-community/teeworlds}"
COPY_BRANCHES="${COPY_BRANCHES:-0}"
_upstream_remote_slug="$(printf '%s' "$UPSTREAM_REMOTE" | sed 's/[^a-zA-Z0-9]/_/g')"
DEFAULT_COPY_BRANCHES_REMOTE="$GH_BOT_USERNAME/${_upstream_remote_slug}-mirror-prs"
COPY_BRANCHES_REMOTE="${COPY_BRANCHES_REMOTE:-$DEFAULT_COPY_BRANCHES_REMOTE}"
DOWNSTREAM_BRANCH="${DOWNSTREAM_BRANCH:-community}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"


KNOWN_URLS_FILE=urls.txt
# this is not a github-cli variable
GH_URLS_FILE=tmp/gh_urls.txt

# https://github.com/teeworlds-community/mirror-bot/issues/5
# https://github.com/cli/cli/blob/f4dff56057efabcfa38c25b3d5220065719d2b15/pkg/cmd/root/help_topic.go#L92-L96
# use local github cli config
# so this script never opens pullrequests under the wrong github user
# if the linux user wide configuration changes
export GH_CONFIG_DIR="$PWD/gh"

err() {
	printf '[-][%s] %s\n' "$(date '+%F %H:%M')" "$1"
}
wrn() {
	printf '[!][%s] %s\n' "$(date '+%F %H:%M')" "$1"
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

if [ "$ARG_DRY" = 1 ]
then
	log "Running in dry mode. Run with ARG_DRY=0 to apply changes."
fi

if ! gh --version | grep -qF 'https://github.com/cli/cli/releases'
then
	err "Error: found gh in your PATH but it does not seem to be the github cli"
	exit 1
fi

if ! gh auth switch --user "$GH_BOT_USERNAME"
then
	err "Error: failed to switch to github account '$GH_BOT_USERNAME'"
	exit 1
fi

# temporary storage that can be deleted at any time
mkdir -p tmp
# more long term storage that is more annoying to obtain again
# these files can also be messed with manually to configure things
# for now only the COPY_BRANCHES repository is stored here
mkdir -p data

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
	if ! gh pr list \
		--limit 90000 \
		--repo "$UPSTREAM_REMOTE" \
		--state open \
		--json headRepository,headRepositoryOwner,headRefName,url,baseRefName,isDraft,title |
		jq -r '.[] | "\(.url) \(.headRepository.name) \(.headRepositoryOwner.login):\(.headRefName) \(.baseRefName) \(.isDraft) \(.title)"' |
		sort
	then
		err "Error: failed to list upstream pull requests on github"
		exit 1
	fi
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

# create a pullrequest from the original source
# so the branch will be owned by the upstream pr author
# it can not be written to
create_pr_direct_ref() {
	url="$1"
	_repo_name="$2"
	ref="$3"
	is_draft="$4"
	title="$5"
	pr_id="${url##*/}"
	# https://github.com/orgs/community/discussions/23123#discussioncomment-3239240
	url="https://www.github.com${url#*https://github.com}"
	flag_draft=''
	if [ "$is_draft" = true ]
	then
		flag_draft='--draft'
	fi
	dbg "url=$url ref=$ref pr_id=$pr_id draft=$is_draft title=$title"

	manual_url="https://github.com/$DOWNSTREAM_REMOTE/compare/$DOWNSTREAM_BRANCH...$ref"
	manual_url="$manual_url?expand=1&title=$(urlencode "$title #$pr_id")&body=$(urlencode "upstream: $url")"
	# printf '%s\n' "$manual_url"
	# ${BROWSER:-echo} "$manual_url"

	if [ "$ARG_DRY" = 1 ]
	then
		log "[dry] $url $ref $flag_draft $title"
	else
		if ! gh pr create $flag_draft \
			--repo "$DOWNSTREAM_REMOTE" \
			--base "$DOWNSTREAM_BRANCH" \
			--head "$ref" \
			--title "$title #$pr_id" \
			--body "upstream: $url" \
			--no-maintainer-edit
		then
			err "Error: failed to create pullrequest using github cli"
			exit 1
		fi
	fi
}

# change directory into data/copy_branches_repo
# creating the folder if it does not exist already
goto_copy_branches_repo() {
	cd data || exit 1
	if [ ! -d copy_branches_repo ]
	then
		if ! git clone "git@github.com:$COPY_BRANCHES_REMOTE" copy_branches_repo
		then
			err "Error: failed to clone $COPY_BRANCHES_REMOTE"
			err "       make sure to create this repository on github"
			err "       as a fork of $UPSTREAM_REMOTE"
			# has to be UPSTREAM_REMOTE because we assume the main branch is the UPSTREAM_BRANCH
			# technically github has the flexibility to pick either upstream or downstream repo
			# as a fork source for the copy branches repo
			# because it can then pr everywhere
			# but it makes the code way more complex if we
			# want to support both in data/copy_branches_repo
			exit 1
		fi
	fi
	if [ ! -d copy_branches_repo ] || [ ! -d copy_branches_repo/.git ]
	then
		err "Error: missing repo at data/copy_branches_repo"
		exit 1
	fi

	cd copy_branches_repo || exit 1
}

git_checkout_branch_or_die() {
	branch="$1"
	if ! git checkout "$branch"
	then
		err "Error: failed to checkout branch $branch"
		err "       try running this command and check for errors"
		err ""
		err "  cd $PWD"
		err "  git checkout $branch"
		err ""
		exit 1
	fi
}

git_add_remote_and_fetch() {
	remote_name="$1"
	remote_url="$2"
	git remote add "$remote_name" "$remote_url"
	if ! git fetch "$remote_name"
	then
		err "Error: failed to fetch $remote_name"
		err "       expect it to point at $remote_url"
		err "       check the following command"
		err ""
		err "  cd $PWD"
		err "  git remote -v"
		err "  git fetch $remote_name"
		err ""
		exit 1
	fi
}

push_branch_or_die() {
	remote="$1"
	branch="$2"
	if ! git push -u "$remote" "$branch"
	then
		err "Error: failed to push branch $branch to remote $remote"
		err "       check the following command"
		err ""
		err "  cd $PWD"
		err "  git push -u $remote $branch"
		err ""
		exit 1
	fi
}

attempt_rebase_ignore_conflicts() {
	main_branch="$1"
	if ! git rebase "$main_branch"
	then
		# assume git conflict
		if ! git rebase --abort
		then
			# it was no conflict?
			err "Error: something went wrong. Failed to abort failed rebase"
			err ""
			err "  cd $PWD"
			err "  git status"
			err ""
			exit 1
		fi
	fi
}

# create a branch owned by the bot user
# that contains the pullrequest
# so this one has to be maintained by the bot
# but it can be written to
#
# this function is not pure
# it depends on being in the root of the mirror-bot repo on launch
# and it changes directory into data/copy_branches_repo
create_pr_copy_ref() {
	url="$1"
	pr_repo_name="$2"
	ref="$3"
	is_draft="$4"
	title="$5"
	pr_id="${url##*/}"
	# https://github.com/orgs/community/discussions/23123#discussioncomment-3239240
	url="https://www.github.com${url#*https://github.com}"
	flag_draft=''
	if [ "$is_draft" = true ]
	then
		flag_draft='--draft'
	fi
	dbg "url=$url ref=$ref pr_id=$pr_id draft=$is_draft title=$title"

	goto_copy_branches_repo
	git_checkout_branch_or_die "$UPSTREAM_BRANCH"
	git fetch || exit 1

	pr_repo_owner="$(printf '%s' "$ref" | cut -d':' -f1)"
	pr_branch="$(printf '%s' "$ref" | cut -d':' -f2-)"
	pr_git_url="git@github.com:$pr_repo_owner/$pr_repo_name"
	copy_branch_name="mirror_${pr_id}_${pr_repo_owner}_$pr_branch"

	log "fetching pr from $pr_git_url ..."

	git_add_remote_and_fetch "remote_$pr_repo_owner" "$pr_git_url"
	git_checkout_branch_or_die "$remote_name/$pr_branch"
	git checkout -b "$copy_branch_name" || exit 1
	attempt_rebase_ignore_conflicts "$DOWNSTREAM_BRANCH"
	push_branch_or_die origin "$copy_branch_name"

	copy_branch_ref="$(printf '%s' "$COPY_BRANCHES_REMOTE" | cut -d'/' -f1):$copy_branch_name"

	if [ "$ARG_DRY" = 1 ]
	then
		log "[dry] $url $ref $flag_draft $title"
	else
		if ! gh pr create $flag_draft \
			--repo "$DOWNSTREAM_REMOTE" \
			--base "$DOWNSTREAM_BRANCH" \
			--head "$copy_branch_ref" \
			--title "$title #$pr_id" \
			--body "upstream: $url"
		then
			err "Error: failed to create pullrequest using github cli"
			exit 1
		fi
	fi
}

create_pr() {
	if [ "$COPY_BRANCHES" = 1 ]
	then
		# allow any kind of directory chaning
		# in create_pr_copy_ref
		old_pwd="$PWD"
		create_pr_copy_ref "$@"
		cd "$old_pwd" || exit 1
	else
		create_pr_direct_ref "$@"
	fi
}

on_new_pr() {
	url="$1"
	shift
	pr_repo_name="$1"
	shift
	ref="$1"
	shift
	target_branch="$1"
	shift
	is_draft="$1"
	shift
	title="$*"
	if grep -qF "$url" "$KNOWN_URLS_FILE"
	then
		dbg "skipping known url=$url"
		return
	fi
	if [ "$target_branch" = editor ]
	then
		dbg "Debug: skipping pr made against the editor branch"
		dbg "       url=$url ref=$ref title=$title"
		printf '%s\n' "$url" >> "$KNOWN_URLS_FILE"
		return
	elif [ "$target_branch" != "$UPSTREAM_BRANCH" ]
	then
		wrn "Warning: ignoring pr because it is against the '$target_branch' not the expected '$UPSTREAM_BRANCH' branch"
		wrn "         url=$url ref=$ref title=$title"
		return
	fi
	printf '%s\n' "$url" >> "$KNOWN_URLS_FILE"
	log "new url=$url ref=$ref draft=$is_draft title=$title"
	create_pr "$url" "$pr_repo_name" "$ref" "$is_draft" "$title"
}

get_new_known_form_gh() {
	if ! gh_prs="$(gh pr list \
		--limit 90000 \
		--state all \
		--repo "$DOWNSTREAM_REMOTE" \
		--json title,body)"
	then
		err "Error: failed to list pullrequests on github"
		exit 1
	fi
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

