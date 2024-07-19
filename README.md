# mirror-bot

Shell script to copy pullrequests from teeworlds/teeworlds to teeworlds-community/teeworlds

## dependencies

- POSIX shell
- jq
- github cli
- git

## setup

Install the github cli and then login:

```bash
mkdir -p gh
GH_CONFIG_DIR=./gh gh auth login
```

Copy the example config:

```bash
cp env.example .env
```
then open `.env` with your favorite text editor and adapt the values.

## terms

**upstream** Is the project you copy from. It will act as source of truth for the mirror bot and will never be written to.

**downstream** Is a copy of the upstream. A repository you own. The mirror bot will open pull requests here.

Example upstream: teeworlds/teeworlds

Example downstream: teeworlds-community/teeworlds

## how does it work what does it do

Running `ARG_DRY=0 ./mirror-bot.sh` does one sync run. To keep it running run `./loop.sh`.
One sync run means getting all open pull requests from the remote you configured in your `.env` (`UPSTREAM_REMOTE`)
then it makes sure there is a corresponding pull request in the downstream remote you configured in your `.env` (`DOWNSTREAM_REMOTE`).

The github account the bot uses needs at least write permissions to the downstream repository. It is just creating pullrequests.
But github does not allow non write access members to create pull requests on behalf of others.

The bot will create "light" pull requests by just creating a pr with the exact same ref as source that the corresponding pr upstream has.
This means that if there are new commits pushed in the upstream pr they will instantly show up in the downstream fork. Because it is the exact same branch.
This also means that the down stream prs are read only or at least can only be written to by the original pr author.

There is also a copy mode `COPY_BRANCHES=1`. Which will create a fresh branch with the same commits as the original pr.
This branch lives in a third copy pr repository where the bot has write access to (`COPY_BRANCHES_REMOTE`).
In the copy mode the prs are not synced by github but have to be synced by the bot (see `--update`) and the bot no longer needs write access to the downstream
because he will be the full owner of the branch. This also means that copy branches can be written to by the bot. So they can be updated independently from the upstream.
The mirror bot uses this opportunity to perform a rebase to the master branch as first action. This ensures that if the downstream is ahead of the upstream or the pr is old
that the mirrored pr will run the latest pipeline with the latest downstream code base.

## dry mode

By default the script will run in dry mode which is debug print only and not creating pull requests.
So running `./mirror-bot.sh` is safe. To make it actually create stuff on github run `ARG_DRY=0 ./mirror-bot.sh`

## manual actions

Check the help page for manual actions

```
./mirror-bot.sh -h
[*][2024-07-19 20:38] Running in dry mode. Run with ARG_DRY=0 to apply changes.
✓ Switched active account for github.com to teeworlds-mirror
usage: mirror-bot.sh [OPTION..]

description:
  it copies github pull requests
  from teeworlds/teeworlds to teeworlds-community/teeworlds
  but it can also be configured to mirror other repositories
  it depends on the github cli and jq

options:
  --force-recreate <upstream_id..>          Close pending downstream prs for given upstream ids
                                            and also force create one fresh pr for that upstream ids
                                            example: mirror-bot.sh --force-recreate 56 82

  --update <upstream_id..>                  Do a force push with new commits from upstream in an existing copied pr
                                            it will keep the downstream pr open. It will fail if there is no matching
                                            downstream pr.
```

## Is this script useful for you?

This script was built specifically to mirror the teeworlds repository.
While technically you can use it to mirror any repository, that is not really tested.
I am sure there are other better maintained mirror tools out there already.

