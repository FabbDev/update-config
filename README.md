# Automatic configuration export

**TODO: Extract the Drupal module `config_change_track` from Subscriptions.**

This project supports automatically exporting configuration from a Drupal site
and creating a PR with the changes.

## Goals

1. Don't remotely access the host: ideally we avoid adding a token with SSH
   access to the production environment to our CI. (And in many cases we only
   have a shared account with access to multiple sites, which makes it worse.)
2. Ensure the GitHub token deployed on the Drupal site can't push to the source
   repo: if it got exfiltrated it could be used to add code without review and
   make deployments.

## Overview

1. Use an intermediate configuration (only) repo.
2. Give the Drupal site write access to the repo and have it regularly update a
   branch with the current config.
3. Give the Drupal site source repo read access to the config repo and have it
   regularly check for updates, creating a PR when found.

## Usage

1. Create an intermediate repo that the Drupal site will push config to and the
   Drupal site repo will poll for changes. Eg.
   ```shell
   # Assuming the config repo URL is in $config_repo_url.
   # Run from the project root.
   config_dir=config/sync
   config_repo_dir="$(mktemp -d)"
   cp "$config_dir"/* "$config_repo_dir"
   pushd "$config_repo_dir"
   git init
   git remote add origin "$config_repo_url"
   git push origin HEAD
   popd
   rm -rf "$config_repo_dir" 
   ```
2. Create two access tokens for the config repo:
   1. A write token for the Drupal site to push config changes;
   2. A read token for the Drupal site repo to pull config changes.
3. Set up the host to push to the config repo:
   1. Add the required environment variables, see [`check-and-push-config.sh`].
   2. Add _Config Change Track_ to the codebase and enable. **TODO: This needs
      extracting from Faith Subscriptions.**
   3. Schedule [`check-and-push-config.sh`] to run regularly.
4. Set up the Drupal site repo to pull from the config repo:
   1. Check [`update-config-branch.yml`] for required permissions, secrets and
      variables to set up.
   2. Add [`update-config-branch.yml`] to the Drupal site repo's `/.github`
      directory. It's configured to check for changes every 30 minutes (though
      GitHub doesn't guarantee it will run that frequently). It will create a
      branch `config-only` that mirrors the `main` branch of the config repo and
      keep it up-to-date. When there are changes a PR is created against
      `staging`.

[`check-and-push-config.sh`]: scripts/check-and-push-config.sh
[`update-config-branch.yml`]: workflow-templates/update-config-branch.yml
