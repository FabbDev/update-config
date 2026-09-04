#!/usr/bin/env bats
#
# Tests for scripts/check-and-push-config.sh
# Uses a local bare git repo as CONFIG_REPO_URL and a drush stub on PATH.
# No network access or Drupal instance required.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-and-push-config.sh"

setup() {
    # Hermetic git: prevent host ~/.gitconfig and /etc/gitconfig from leaking
    # push.default, init.defaultBranch, or identity into the test.
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    export GIT_CONFIG_SYSTEM="$BATS_TEST_TMPDIR/gitconfig.system"
    touch "$GIT_CONFIG_SYSTEM"
    git config --global user.name "Test User"
    git config --global user.email "test@test.com"
    git config --global init.defaultBranch "main"
    git config --global push.default "simple"

    # Drush stub: all subcommand invocations appended to DRUSH_CALL_LOG.
    # Behaviour controlled per-test via NEEDS_EXPORT and EXPORT_FILES_DIR.
    local bin_dir="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$bin_dir"
    export DRUSH_CALL_LOG="$BATS_TEST_TMPDIR/drush-calls.log"
    touch "$DRUSH_CALL_LOG"
    cat > "$bin_dir/drush" << 'STUB'
#!/usr/bin/env bash
subcommand="$1"; shift
echo "$subcommand $*" >> "$DRUSH_CALL_LOG"
case "$subcommand" in
  config-change-track:needs-export)
    echo "${NEEDS_EXPORT:-0}"
    ;;
  config:export)
    dest=""
    for arg in "$@"; do
      case "$arg" in --destination=*) dest="${arg#--destination=}" ;; esac
    done
    if [[ -n "${EXPORT_FILES_DIR:-}" && -n "$dest" ]]; then
      # -type f so dotfile fixtures are copied too (a plain glob would miss
      # them).
      find "$EXPORT_FILES_DIR" -mindepth 1 -maxdepth 1 -type f \
        -exec cp {} "$dest/" \;
    fi
    # Drupal always writes an .htaccess into the config directory.
    if [[ -n "$dest" ]]; then
      printf 'deny from all\n' > "$dest/.htaccess"
    fi
    ;;
esac
STUB
    chmod +x "$bin_dir/drush"
    export PATH="$bin_dir:$PATH"

    # Bare config repo seeded with one commit on 'main'.
    local bare="$BATS_TEST_TMPDIR/config-repo.git"
    git init --bare "$bare"
    local seed="$BATS_TEST_TMPDIR/seed"
    git clone "$bare" "$seed" 2>/dev/null
    echo "initial" > "$seed/initial.yml"
    git -C "$seed" add .
    git -C "$seed" commit -m "Initial commit" --quiet
    git -C "$seed" push origin main --quiet
    rm -rf "$seed"

    export CONFIG_REPO_URL="$bare"
    export CONFIG_REPO_TEMP_DIR="$BATS_TEST_TMPDIR/config-checkout"

    # Default export: one new file not yet present in the repo.
    export EXPORT_FILES_DIR="$BATS_TEST_TMPDIR/export-files"
    mkdir -p "$EXPORT_FILES_DIR"
    echo "exported" > "$EXPORT_FILES_DIR/config.yml"

    unset CONFIG_REPO_BRANCH UPDATE_CONFIG_GIT_NAME UPDATE_CONFIG_GIT_EMAIL \
          UPDATE_CONFIG_GIT_MESSAGE NEEDS_EXPORT
}

_remote_commit_count() { git -C "$1" rev-list HEAD --count; }
_remote_head()         { git -C "$1" rev-parse "${2:-HEAD}"; }

# Early out

@test "exits 0 without exporting or pushing when needs-export returns 0" {
    export NEEDS_EXPORT=0
    local initial_head; initial_head=$(_remote_head "$CONFIG_REPO_URL")

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    ! grep -q "config:export" "$DRUSH_CALL_LOG"
    ! grep -q "set-last-export" "$DRUSH_CALL_LOG"
    [[ "$(_remote_head "$CONFIG_REPO_URL")" == "$initial_head" ]]
}

# Fresh clone

@test "clones repo and pushes exported config when temp dir is empty" {
    export NEEDS_EXPORT=1

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [ "$(_remote_commit_count "$CONFIG_REPO_URL")" -eq 2 ]
    # Exported file present in the pushed commit.
    git -C "$CONFIG_REPO_URL" show HEAD:config.yml
    grep -q "set-last-export --time" "$DRUSH_CALL_LOG"
}

# Existing checkout (fetch + reset path)

@test "fetches and resets a stale checkout before exporting and pushing" {
    export NEEDS_EXPORT=1

    # Pre-clone so the script enters the fetch+reset branch.
    git clone "$CONFIG_REPO_URL" "$CONFIG_REPO_TEMP_DIR" --quiet 2>/dev/null

    # Advance the remote by one commit so the local checkout is stale.
    local update="$BATS_TEST_TMPDIR/update"
    git clone "$CONFIG_REPO_URL" "$update" --quiet 2>/dev/null
    echo "upstream" > "$update/upstream.yml"
    git -C "$update" add .
    git -C "$update" commit -m "Upstream" --quiet
    git -C "$update" push origin main --quiet
    rm -rf "$update"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    # initial(1) + upstream(2) + export(3) = 3 commits.
    [ "$(_remote_commit_count "$CONFIG_REPO_URL")" -eq 3 ]
    git -C "$CONFIG_REPO_URL" show HEAD:config.yml
    grep -q "set-last-export --time" "$DRUSH_CALL_LOG"
}

# Existing checkout, but CONFIG_REPO_URL now points elsewhere (e.g. rotated token)

@test "uses the current CONFIG_REPO_URL when it changed after the checkout was created" {
    export NEEDS_EXPORT=1

    local original_bare="$CONFIG_REPO_URL"

    # Pre-clone from the original bare repo so the script enters the
    # fetch+reset branch with a stored origin URL that is about to go stale.
    git clone "$original_bare" "$CONFIG_REPO_TEMP_DIR" --quiet 2>/dev/null
    local original_head; original_head=$(_remote_head "$original_bare")

    # Seed a second bare repo and repoint CONFIG_REPO_URL at it, simulating
    # the URL (and embedded token) changing since the checkout was made.
    local new_bare="$BATS_TEST_TMPDIR/new-repo.git"
    git init --bare "$new_bare"
    local seed="$BATS_TEST_TMPDIR/new-seed"
    git clone "$new_bare" "$seed" --quiet 2>/dev/null
    echo "other initial" > "$seed/other-initial.yml"
    git -C "$seed" add .
    git -C "$seed" commit -m "Initial commit" --quiet
    git -C "$seed" push origin main --quiet
    rm -rf "$seed"

    export CONFIG_REPO_URL="$new_bare"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    # Exported config lands in the new repo, not the original.
    git -C "$new_bare" show HEAD:config.yml
    grep -q "set-last-export --time" "$DRUSH_CALL_LOG"
    # Original bare repo was never touched.
    [[ "$(_remote_head "$original_bare")" == "$original_head" ]]
    # Checkout is left pointing at the current URL, not the stale one.
    [[ "$(git -C "$CONFIG_REPO_TEMP_DIR" remote get-url origin)" == "$new_bare" ]]
}

# Existing checkout, but CONFIG_REPO_BRANCH now points elsewhere

@test "uses the current CONFIG_REPO_BRANCH when it changed after the checkout was created" {
    export NEEDS_EXPORT=1

    # Pre-clone on 'main' so the script enters the fetch+reset branch.
    git clone "$CONFIG_REPO_URL" "$CONFIG_REPO_TEMP_DIR" --quiet 2>/dev/null
    local main_head; main_head=$(_remote_head "$CONFIG_REPO_URL" "refs/heads/main")

    # Add a second branch to the same bare repo and switch to it.
    local seed="$BATS_TEST_TMPDIR/branch-seed"
    git clone "$CONFIG_REPO_URL" "$seed" --quiet 2>/dev/null
    git -C "$seed" checkout -b other-branch --quiet
    echo "other" > "$seed/other.yml"
    git -C "$seed" add .
    git -C "$seed" commit -m "Other branch commit" --quiet
    git -C "$seed" push origin other-branch --quiet
    rm -rf "$seed"

    export CONFIG_REPO_BRANCH="other-branch"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    # Exported config lands on the new branch.
    git -C "$CONFIG_REPO_URL" show refs/heads/other-branch:config.yml
    grep -q "set-last-export --time" "$DRUSH_CALL_LOG"
    # main is untouched.
    [[ "$(_remote_head "$CONFIG_REPO_URL" "refs/heads/main")" == "$main_head" ]]
}

# Export produces no diff

@test "skips commit and push but still calls set-last-export when export yields no diff" {
    export NEEDS_EXPORT=1
    # Export exactly what is already committed: initial.yml with "initial".
    echo "initial" > "$EXPORT_FILES_DIR/initial.yml"
    rm -f "$EXPORT_FILES_DIR/config.yml"

    local initial_head; initial_head=$(_remote_head "$CONFIG_REPO_URL")

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$(_remote_head "$CONFIG_REPO_URL")" == "$initial_head" ]]
    grep -q "set-last-export --time" "$DRUSH_CALL_LOG"
}

# .htaccess is site-repo-owned and must never reach the config repo

@test "does not commit the .htaccess written by the export" {
    export NEEDS_EXPORT=1

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    # The rest of the export still landed.
    git -C "$CONFIG_REPO_URL" show HEAD:config.yml
    ! git -C "$CONFIG_REPO_URL" show HEAD:.htaccess
}

@test "removes an .htaccess already tracked in the config repo" {
    export NEEDS_EXPORT=1

    # Seed the repo with a legacy tracked .htaccess.
    local seed="$BATS_TEST_TMPDIR/htaccess-seed"
    git clone "$CONFIG_REPO_URL" "$seed" --quiet 2>/dev/null
    printf 'stale\n' > "$seed/.htaccess"
    git -C "$seed" add .htaccess
    git -C "$seed" commit -m "Legacy .htaccess" --quiet
    git -C "$seed" push origin main --quiet
    rm -rf "$seed"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    git -C "$CONFIG_REPO_URL" show HEAD:config.yml
    ! git -C "$CONFIG_REPO_URL" show HEAD:.htaccess
}

@test "skips commit and push when the .htaccess is the only difference" {
    export NEEDS_EXPORT=1
    # Export exactly what is already committed; the stub still writes an
    # .htaccess, which must not be treated as a change to push.
    echo "initial" > "$EXPORT_FILES_DIR/initial.yml"
    rm -f "$EXPORT_FILES_DIR/config.yml"

    local initial_head; initial_head=$(_remote_head "$CONFIG_REPO_URL")

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$(_remote_head "$CONFIG_REPO_URL")" == "$initial_head" ]]
    grep -q "set-last-export --time" "$DRUSH_CALL_LOG"
}

# Commit metadata - custom values

@test "uses custom git identity and message when env vars are set" {
    export NEEDS_EXPORT=1
    export UPDATE_CONFIG_GIT_NAME="Custom Bot"
    export UPDATE_CONFIG_GIT_EMAIL="custom@bot.com"
    export UPDATE_CONFIG_GIT_MESSAGE="My custom message"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$(git -C "$CONFIG_REPO_URL" log -1 --format='%an <%ae>')" \
       == "Custom Bot <custom@bot.com>" ]]
    [[ "$(git -C "$CONFIG_REPO_URL" log -1 --format='%s')" \
       == "My custom message" ]]
}

# Commit metadata - defaults

@test "uses default git identity and message when env vars are unset" {
    export NEEDS_EXPORT=1

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$(git -C "$CONFIG_REPO_URL" log -1 --format='%an <%ae>')" \
       == "R2D2 <config-update@example.com>" ]]
    [[ "$(git -C "$CONFIG_REPO_URL" log -1 --format='%s')" \
       == "Export config from Prod" ]]
}

# Custom branch

@test "clones and pushes to the configured branch when CONFIG_REPO_BRANCH is set" {
    local custom_bare="$BATS_TEST_TMPDIR/custom-repo.git"
    git init --bare "$custom_bare"
    local seed="$BATS_TEST_TMPDIR/custom-seed"
    git clone "$custom_bare" "$seed" --quiet 2>/dev/null
    git -C "$seed" checkout -b config-branch --quiet
    echo "initial" > "$seed/initial.yml"
    git -C "$seed" add .
    git -C "$seed" commit -m "Initial commit" --quiet
    git -C "$seed" push --set-upstream origin config-branch --quiet
    rm -rf "$seed"

    export CONFIG_REPO_URL="$custom_bare"
    export CONFIG_REPO_BRANCH="config-branch"
    export NEEDS_EXPORT=1

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    # config.yml must appear on config-branch in the bare repo.
    git -C "$custom_bare" show refs/heads/config-branch:config.yml
}
