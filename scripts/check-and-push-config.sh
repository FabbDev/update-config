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
#
# Any failure is logged to the Drupal watchdog on the channel 'update_config',
# with credentials in URLs redacted. That requires drush to be able to bootstrap
# Drupal from the directory cron starts in, so run this from the project root.
# Diagnose a stalled export with `drush watchdog:show --type=update_config`.

set -Eeuo pipefail

# Capture everything the run produces so a failure can be logged with its
# output. The exit handler replays it to the real stdout/stderr, so cron mail
# is unaffected; the cost is that an interactive run shows nothing until it
# finishes.
start_dir=$PWD # drush bootstraps here; $temp_dir is not a Drupal root.
output_file=$(mktemp)
exec 3>&1 4>&2
exec >"$output_file" 2>&1

redact() {
  # The config repo token rides in $CONFIG_REPO_URL and git prints the URL back
  # in auth errors; watchdog is readable by anyone with 'access site reports'.
  sed -E 's#(://)[^/@[:space:]]+@#\1***@#g'
}

on_exit() {
  local status=$1
  # No recursion, and don't let a failing command in here abort the handler.
  trap - ERR EXIT
  set +e

  exec 1>&3 2>&4
  redact < "$output_file"

  if [[ $status -ne 0 ]]; then
    local message
    message=$(printf '%s failed (exit %s, line %s).\n--- last output ---\n%s\n' \
      "$(basename "$0")" "$status" "${failure_line:-unknown}" \
      "$(tail -c 2000 "$output_file" | redact)")
    cd "$start_dir"
    # Drush has no watchdog-writing command, so go through php:eval. The
    # message is passed in the environment and bound as a placeholder, never
    # interpolated into the snippet.
    UPDATE_CONFIG_LOG_MESSAGE="$message" drush php:eval \
      '\Drupal::logger("update_config")->error("@message", ["@message" => getenv("UPDATE_CONFIG_LOG_MESSAGE")]);' \
      || printf 'Could not write the failure to the Drupal watchdog.\n' >&2
  fi

  rm -f "$output_file"
  # The handler's own commands have overwritten $?, so restore the real status.
  exit "$status"
}

# A `set -u` abort doesn't fire the ERR trap, only EXIT, so EXIT does the
# logging and ERR only records where things went wrong.
failure_line=
trap 'failure_line=$LINENO' ERR
trap 'on_exit $?' EXIT

: "${CONFIG_REPO_URL:?CONFIG_REPO_URL is not set}"

commit_message="Export config from Prod"
config_repo_branch=${CONFIG_REPO_BRANCH:-main}

# Check if config needs to be exported. Assign rather than test the command
# substitution inline: `[[ $(drush …) == "0" ]]` doesn't trip `set -e`, so a
# failing or missing drush command would fall through to exporting and pushing.
needs_export=$(drush config-change-track:needs-export)
case "$needs_export" in
  0) exit ;; # No changes to export so early out.
  1) ;;
  *) echo "Unexpected needs-export output: $needs_export" >&2; exit 1 ;;
esac

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
