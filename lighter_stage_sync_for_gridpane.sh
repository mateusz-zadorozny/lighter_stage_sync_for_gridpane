#!/bin/bash

# ---------------------------------------------------------------------------
# Lighter Stage Sync for GridPane
#
# Connections are read from a .env file (git-ignored). Each site maps an SSH
# host alias (the "Host" entry from your ~/.ssh/config, e.g. you connect with
# `ssh bo`) to a live domain. The staging site is derived as staging.<domain>.
#
# See .env.example for the format. Copy it to .env and fill in your sites:
#     cp .env.example .env
# ---------------------------------------------------------------------------

# Resolve the directory this script lives in, so .env is found regardless of CWD
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Trim leading/trailing whitespace
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # remove leading whitespace
    s="${s%"${s##*[![:space:]]}"}"   # remove trailing whitespace
    printf '%s' "$s"
}

# Ask a yes/no question. When AUTO_ALL=true (the "everything, no prompts" mode),
# every question is auto-answered "yes". Returns 0 for yes, 1 for no.
AUTO_ALL=false
confirm() {
    local prompt="$1" answer
    if [[ "$AUTO_ALL" == "true" ]]; then
        echo "${prompt}y  (auto)"
        return 0
    fi
    read -p "$prompt" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# --- Load configuration -----------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env not found at $ENV_FILE"
    echo "Copy .env.example to .env and add your sites:"
    echo "    cp .env.example .env"
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

# Optional: path to the PRIVATE staging-neutralize-kit repo. When set and a
# matching sites/<domain>/ folder exists there, full-DB imports are neutralized
# automatically. Empty/unset = neutralization disabled.
STAGING_KIT_DIR="${STAGING_KIT_DIR:-}"

if [[ -z "$SITES" ]]; then
    echo "Error: SITES is empty in $ENV_FILE (see .env.example)."
    exit 1
fi

# Parse SITES ("<ssh_alias>|<live_domain>" per line) into parallel arrays
site_aliases=()
site_domains=()
while IFS= read -r line; do
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue        # skip blank lines
    [[ "$line" == \#* ]] && continue    # skip comments
    if [[ "$line" != *"|"* ]]; then
        echo "Warning: ignoring malformed SITES line (missing '|'): $line"
        continue
    fi
    alias="$(trim "${line%%|*}")"
    domain="$(trim "${line#*|}")"
    [[ -z "$alias" || -z "$domain" ]] && continue
    site_aliases+=("$alias")
    site_domains+=("$domain")
done <<< "$SITES"

if [[ ${#site_domains[@]} -eq 0 ]]; then
    echo "Error: no valid sites found in $ENV_FILE (see .env.example)."
    exit 1
fi

# Function to list and select a site (sets SSH_HOST and LIVE_SITE)
select_site() {
    echo ""
    echo "Available sites:"
    local options=()
    for i in "${!site_domains[@]}"; do
        options+=("${site_domains[i]}  (ssh: ${site_aliases[i]})")
    done

    echo ""
    PS3="Select a site or pick Cancel: "
    select opt in "${options[@]}" "Cancel"; do
        if [[ "$opt" == "Cancel" ]]; then
            return 1
        elif [[ -n "$opt" ]]; then
            local idx=$((REPLY - 1))
            SSH_HOST="${site_aliases[idx]}"
            LIVE_SITE="${site_domains[idx]}"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
    return 0
}

# Main loop
while true; do
    select_site || continue

    echo ""
    echo "Using SSH host '$SSH_HOST' for $LIVE_SITE -> staging.$LIVE_SITE"

    # Pre-flight guard: never run destructive commands against a staging site
    # that doesn't exist. Aborts back to site selection instead of failing
    # halfway through (or, worse, touching the wrong site).
    echo ""
    echo "Checking that staging.$LIVE_SITE exists on '$SSH_HOST'..."
    if ! ssh "$SSH_HOST" "test -d /var/www/staging.$LIVE_SITE/htdocs"; then
        echo ""
        echo "Error: staging.$LIVE_SITE not found on '$SSH_HOST'"
        echo "       (/var/www/staging.$LIVE_SITE/htdocs is missing, or the host is unreachable)."
        echo "Create the staging site in GridPane first, or fix the domain in .env. Skipping."
        continue
    fi
    echo "OK: staging.$LIVE_SITE found."

    STAGING_DB="/var/www/staging.$LIVE_SITE/htdocs/db_stage_sync.sql"
    WP_POSTS_DB="/var/www/staging.$LIVE_SITE/htdocs/wp_posts.sql"

    echo ""
    echo "Select sync method:"
    echo "1) Full process (full database + ask about files and nginx rule)"
    echo "2) Just wp_posts & wp_postmeta quick sync"
    echo "3) Full database sync & rewrite (database only)"
    echo "4) EVERYTHING, no questions (full database + all files + nginx rule + neutralize)"
    read -p "Your choice [1/2/3/4]: " sync_choice

    # Option 4 = option 1 with every prompt auto-answered "yes".
    if [[ $sync_choice == "4" ]]; then AUTO_ALL=true; else AUTO_ALL=false; fi

    if [[ $sync_choice == "1" || $sync_choice == "3" || $sync_choice == "4" ]]; then
        # Full database: export from live, import to staging, rewrite URLs.
        # Identical for options 1, 3 and 4 — they differ only in the optional
        # file/nginx steps afterward (1 asks, 4 does everything, 3 does none).
        echo ""
        echo "Exporting the full database from $LIVE_SITE..."
        ssh "$SSH_HOST" "gp wp $LIVE_SITE db export $STAGING_DB --add-drop-table --allow-root"

        echo ""
        echo "Importing the full database to staging.$LIVE_SITE..."
        ssh "$SSH_HOST" "gp wp staging.$LIVE_SITE db import $STAGING_DB --allow-root"

        # Rewrite URLs from live to staging. Do BOTH https:// and http:// —
        # production DBs accumulate http:// refs (older content, pre-SSL), and
        # replacing only https:// leaves them pointing at live. Both map to the
        # staging https URL (GridPane staging enforces https).
        echo ""
        echo "Rewriting URLs from $LIVE_SITE to staging.$LIVE_SITE (https + http)..."
        ssh "$SSH_HOST" "gp wp staging.$LIVE_SITE search-replace 'https://$LIVE_SITE' 'https://staging.$LIVE_SITE' --skip-columns=guid --all-tables --allow-root"
        ssh "$SSH_HOST" "gp wp staging.$LIVE_SITE search-replace 'http://$LIVE_SITE' 'https://staging.$LIVE_SITE' --skip-columns=guid --all-tables --allow-root"

    elif [[ $sync_choice == "2" ]]; then
        # Quick sync
        echo ""
        echo "Exporting wp_posts and wp_postmeta from $LIVE_SITE..."
        ssh "$SSH_HOST" "gp wp $LIVE_SITE db export $WP_POSTS_DB --tables=wp_posts,wp_postmeta --allow-root" && export_success=true

        if [[ $export_success == true ]]; then
            echo ""
            echo "Importing wp_posts and wp_postmeta to staging.$LIVE_SITE..."
            ssh "$SSH_HOST" "gp wp staging.$LIVE_SITE db import $WP_POSTS_DB --allow-root"

            # Rewrite URLs in wp_posts and wp_postmeta
            echo ""
            echo "Rewriting URLs in wp_posts and wp_postmeta from $LIVE_SITE to staging.$LIVE_SITE (https + http)..."
            ssh "$SSH_HOST" "gp wp staging.$LIVE_SITE search-replace 'https://$LIVE_SITE' 'https://staging.$LIVE_SITE' wp_post* --skip-columns=guid --allow-root"
            ssh "$SSH_HOST" "gp wp staging.$LIVE_SITE search-replace 'http://$LIVE_SITE' 'https://staging.$LIVE_SITE' wp_post* --skip-columns=guid --allow-root"

        else
            echo "Export failed. Skipping import."
        fi

    else
        echo "Invalid selection. Please try again."
        continue
    fi

    # Common steps for all sync methods
    # Clear the cache for the staging site
    echo ""
    echo "Clearing cache for staging.$LIVE_SITE..."
    ssh "$SSH_HOST" "gp fix cached staging.$LIVE_SITE"

    # Delete the temporary database export files, if they exist
    echo ""
    echo "Deleting temporary database export files, if they exist..."
    ssh "$SSH_HOST" "rm -f $STAGING_DB $WP_POSTS_DB"

    # Additional steps for full process (option 1 asks; option 4 auto-confirms all)
    if [[ $sync_choice == "1" || $sync_choice == "4" ]]; then
        # Ask about syncing themes and plugins
        echo ""
        if confirm "Do you want to copy themes from $LIVE_SITE? [y/N] "; then
            # cp runs as root, so chown the result back to the staging site's
            # system user (matches htdocs) — otherwise WP can't write to it.
            ssh -T "$SSH_HOST" "cp -R /root/www/$LIVE_SITE/htdocs/wp-content/themes /root/www/staging.$LIVE_SITE/htdocs/wp-content/ && chown -R --reference=/var/www/staging.$LIVE_SITE/htdocs /var/www/staging.$LIVE_SITE/htdocs/wp-content/themes"
        fi

        echo ""
        if confirm "Do you want to copy plugins from $LIVE_SITE? [y/N] "; then
            ssh -T "$SSH_HOST" "cp -R /root/www/$LIVE_SITE/htdocs/wp-content/plugins /root/www/staging.$LIVE_SITE/htdocs/wp-content/ && chown -R --reference=/var/www/staging.$LIVE_SITE/htdocs /var/www/staging.$LIVE_SITE/htdocs/wp-content/plugins"
        fi

        # Ask about copying additional folders from wp-content/uploads
        echo ""
        if confirm "Do you want to copy specific folders from wp-content/uploads? [y/N] "; then
            # List non-year directories in wp-content/uploads and store them in an array.
            # Also always skip the WooCommerce placeholder thumbnails (woocommerce-placeholder*.png),
            # which are regenerated by Woo and just clutter the prompt.
            IFS=$'\n' non_year_dirs=($(ssh "$SSH_HOST" "ls -1 /var/www/$LIVE_SITE/htdocs/wp-content/uploads | grep -vE '^(2003|2004|2005|2006|2007|2008|2009|201[0-9]|20[2-9][0-9])$' | grep -viE '^woocommerce-placeholder.*\.png$'"))

            # Ask whether to copy each of these directories
            for dir in "${non_year_dirs[@]}"; do
                echo ""
                if confirm "Do you want to copy $dir? [y/N] "; then
                    echo "Copying $dir..."
                    ssh "$SSH_HOST" "cp -R /var/www/$LIVE_SITE/htdocs/wp-content/uploads/$dir /var/www/staging.$LIVE_SITE/htdocs/wp-content/uploads/ && chown -R --reference=/var/www/staging.$LIVE_SITE/htdocs/wp-content/uploads /var/www/staging.$LIVE_SITE/htdocs/wp-content/uploads/$dir"
                fi
            done
        fi

        # Ask about creating Nginx custom rules for media files
        echo ""
        if confirm "Do you want to create nginx custom rules for media files? [y/N] "; then
            NGINX_CONFIG_FILE="/var/www/staging.$LIVE_SITE/nginx/live-media-main-context.conf"
            LIVE_DOMAIN=${LIVE_SITE/www./}

            # Create Nginx configuration for redirecting media
            echo "Creating Nginx configuration for media redirects..."
            ssh "$SSH_HOST" "echo 'location ~* ^/wp-content/uploads/(.*)\$ { rewrite ^/wp-content/uploads/(.*)\$ https://$LIVE_DOMAIN/wp-content/uploads/\$1 redirect; }' > $NGINX_CONFIG_FILE"

            # Test and reload Nginx
            echo "Testing and reloading Nginx..."
            ssh "$SSH_HOST" "nginx -t && gp ngx reload"
        fi
    fi

    # Automatic staging neutralization — ONLY after a full-database import.
    # Option 2 (wp_posts/postmeta) never touches wp_options, so a staging site
    # that was already neutralized stays neutralized; no need to re-run.
    if [[ "$sync_choice" == "1" || "$sync_choice" == "3" || "$sync_choice" == "4" ]]; then
        if [[ -n "$STAGING_KIT_DIR" && -d "$STAGING_KIT_DIR/sites/$LIVE_SITE" ]]; then
            echo ""
            echo "Neutralization kit found for $LIVE_SITE — neutralizing staging.$LIVE_SITE..."
            bash "$STAGING_KIT_DIR/run.sh" "$SSH_HOST" "$LIVE_SITE"
        else
            echo ""
            echo "############################################################"
            echo "# WARNING: NO neutralization kit applied for $LIVE_SITE."
            echo "# staging.$LIVE_SITE just received a FULL production database:"
            echo "# it may hold live email senders, payment keys, API tokens,"
            echo "# tracking pixels and active webhooks/crons."
            if [[ -z "$STAGING_KIT_DIR" ]]; then
                echo "# Reason: STAGING_KIT_DIR is not set in .env"
            else
                echo "# Reason: no folder $STAGING_KIT_DIR/sites/$LIVE_SITE"
            fi
            echo "############################################################"
        fi
    fi

    # Add more steps as needed
    echo ""
    read -p "Do you want to sync another site? [y/N] " sync_another
    [[ $sync_another =~ ^[Yy]$ ]] || break
done

echo "Synchronization complete."
