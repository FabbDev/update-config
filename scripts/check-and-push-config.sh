#!/usr/bin/env bash
# Exports and pushes config to the intermediate repo, causing a PR to be
# created.
#
# Required environment variables:
# - CONFIG_REPO_URL: The config repo URL.
# Optional environment variables:
# - CONFIG_REPO_BRANCH: The config repo branch.
# - UPDATE_CONFIG_GIT_EMAIL: The email address to use for the commit.
# - UPDATE_CONFIG_GIT_NAME: The name to use for the commit.
# - UPDATE_CONFIG_GIT_MESSAGE: The message for the git commit.
#
# Note the repo's access token can be passed with the repo URL, eg.
# https://ABC123:@github.com/MyOrg/MySiteConfig

set -eu

commit_message="Export config from Prod"
config_repo_branch=${CONFIG_REPO_BRANCH:-main}

# Check if config needs to be exported
if [[ $(drush config-change-track:needs-export) == "0" ]]; then
  exit # No changes to export so early out.
fi

temp_dir=${CONFIG_REPO_TEMP_DIR-/tmp/config_change_track}
mkdir -p "$temp_dir"
pushd "$temp_dir"
if [[ -d .git ]]; then
  # Shouldn't really be necessary, but just in case.
  git fetch
  git reset --hard origin/$config_repo_branch
else
  git clone --branch $config_repo_branch "$CONFIG_REPO_URL" .
fi
time=$(date '+%s')
# Note if using config_split, this will only work with 2.x and collection
# storage.
# See https://www.drupal.org/node/3001485#comment-14474479
# (An alternative solution would be to modify $settings['config_sync_director']
# just for this command.)
drush config:export --destination="$temp_dir" --yes
git add .
git config user.name "${UPDATE_CONFIG_GIT_NAME:-R2D2}"
git config user.email "${UPDATE_CONFIG_GIT_EMAIL:-config-update@example.com}"
# Allow for the possibility that there are no changes.
if [[ -n "$(git status --porcelain)" ]]; then
  git commit -m "${UPDATE_CONFIG_GIT_MESSAGE:-Export config from Prod}"
  git push
fi
drush config-change-track:set-last-export --time $time

popd
