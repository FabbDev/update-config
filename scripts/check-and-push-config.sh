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
  # The URL may have changed since this checkout was created (typically a
  # rotated access token embedded in the URL) so always repoint origin at the
  # current value rather than reusing the stored one.
  git remote set-url origin "$CONFIG_REPO_URL"
  git fetch origin
  # -f -B copes with $CONFIG_REPO_URL potentially pointing at a different repo
  # (unrelated history) or a different branch.
  git checkout -f -B "$config_repo_branch" "origin/$config_repo_branch"
else
  git clone --branch "$config_repo_branch" "$CONFIG_REPO_URL" .
fi
time=$(date '+%s')
# Note if using config_split, this will only work with 2.x and collection
# storage.
# See https://www.drupal.org/node/3001485#comment-14474479
# (An alternative solution would be to modify $settings['config_sync_director']
# just for this command.)
drush config:export --destination="$temp_dir" --yes
# Drupal writes an .htaccess into the config directory to block web access to
# it. It belongs to the site repo, not the config export, so keep it out of the
# config repo (and drop it if an earlier run committed one).
git rm --cached --quiet --ignore-unmatch -- '*.htaccess'
git add --all -- . ':(exclude)*.htaccess'
git config user.name "${UPDATE_CONFIG_GIT_NAME:-R2D2}"
git config user.email "${UPDATE_CONFIG_GIT_EMAIL:-config-update@example.com}"
# Allow for the possibility that there are no changes. The .htaccess is
# untracked and not ignored, so it always shows up in `git status`; only staged
# changes tell us whether there's anything to commit.
if ! git diff --cached --quiet; then
  git commit -m "${UPDATE_CONFIG_GIT_MESSAGE:-Export config from Prod}"
  # Explicit remote and refspec: a bare push honours the host user's
  # push.default / remote.pushDefault, which can silently push to the wrong
  # remote and still exit 0.
  git push origin "HEAD:$config_repo_branch"
fi
drush config-change-track:set-last-export --time $time

popd
