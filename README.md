# Automatic configuration export

** TODO: Extract the Drupal module config_change_track **

This project supports automatically exporting configuration from a Drupal site
and creating a PR with the changes.

## Goals

1. Don't remotely access the host: ideally we avoid adding a token with SSH
   access to the production environment to our CI. (And in many cases we only
   have a shared account with access to multiple sites, which makes it worse.)
2. Ensure the GitHub token deployed on the Drupal site can't push to the source
   repository: if it got exfiltrated it could be used to add code without review
   and make deployments.

## Overview

1. Use an intermediate configuration (only) repository.
2. Give the Drupal site write access to the repo and have it regularly update a
   branch with the current config.
3. Give the Drupal site source repository read access to the config repo and
   have it regularly check for updates, creating a PR when found.

## Usage

TBD
