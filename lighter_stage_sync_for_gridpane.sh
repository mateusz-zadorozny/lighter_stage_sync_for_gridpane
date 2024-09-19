#!/bin/bash

# Define the path to your private key
PRIVATE_KEY_PATH="/your_private_key_location"

# Define server names and IP addresses
server_names=("Friendly Server name 01" "Friendly Server name 02")
server_ips=("231.x.x.x" "168.x.x.x")

# Function to list and select a server
select_server() {
    echo ""
    echo "Select a server:"
    for i in "${!server_names[@]}"; do
        echo "$((i+1))) ${server_names[i]} - ${server_ips[i]}"
    done
    read -p "#? " choice
    let choice-=1
    if [ "$choice" -ge 0 ] && [ "$choice" -lt "${#server_names[@]}" ]; then
        SERVER_IP="${server_ips[choice]}"
    else
        echo "Invalid selection. Please try again."
        return 1
    fi
    return 0
}

# Function to list and select a staging site
select_staging_site() {
    echo ""
    echo "Connecting to $SERVER_IP..."
    
    # Get the list of sites and store them in an array called 'sites'
    IFS=$'\n' sites=($(ssh -i "$PRIVATE_KEY_PATH" -T "root@$SERVER_IP" "ls /root/www/ | grep staging"))

    if [ ${#sites[@]} -eq 0 ]; then
        echo "No staging sites found."
        return 1
    fi

    echo ""
    echo "Available staging sites:"
    for site in "${sites[@]}"; do
        echo "$site"
    done
    
    echo ""
    echo "Select a staging site or type 'Cancel' to exit:"
    select site in "${sites[@]}" "Cancel"; do
        if [[ $site == "Cancel" ]]; then
            return 1
        elif [ -n "$site" ]; then
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
    return 0
}

# Main loop
while true; do
    select_server || continue

    select_staging_site || continue

    LIVE_SITE=${site/staging./}
    STAGING_DB="/var/www/staging.$LIVE_SITE/htdocs/db_stage_sync.sql"
    WP_POSTS_DB="/var/www/staging.$LIVE_SITE/htdocs/wp_posts.sql"

    echo ""
    echo "Select sync method:"
    echo "1) Full process (full database and optional: files and nginx rule)"
    echo "2) Just wp_posts & wp_postmeta quick sync"
    echo "3) Full database sync & rewrite"
    read -p "Your choice [1/2/3]: " sync_choice

    if [[ $sync_choice == "1" ]]; then
        # Full process
        echo ""
        echo "Exporting the database from $LIVE_SITE..."
        ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "gp wp $LIVE_SITE db export $STAGING_DB --add-drop-table --allow-root"

        echo ""
        echo "Importing database to $site..."
        ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "gp wp staging.$LIVE_SITE db import $STAGING_DB --allow-root"

        # Rewrite URLs from live to staging
        echo ""
        echo "Rewriting URLs from $LIVE_SITE to staging.$LIVE_SITE..."
        ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "gp wp staging.$LIVE_SITE search-replace 'https://$LIVE_SITE' 'https://staging.$LIVE_SITE' --skip-columns=guid --all-tables --allow-root"

    elif [[ $sync_choice == "2" ]]; then
        # Quick sync
        echo ""
        echo "Exporting wp_posts and wp_postmeta from $LIVE_SITE..."
        ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "gp wp $LIVE_SITE db export $WP_POSTS_DB --tables=wp_posts,wp_postmeta --allow-root" && export_success=true

        if [[ $export_success == true ]]; then   
            echo ""
            echo "Importing wp_posts and wp_postmeta to $site..."
            ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "gp wp staging.$LIVE_SITE db import $WP_POSTS_DB --allow-root"

            # Rewrite URLs in wp_posts and wp_postmeta
            echo ""
            echo "Rewriting URLs in wp_posts and wp_postmeta from $LIVE_SITE to staging.$LIVE_SITE..."
            ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "gp wp staging.$LIVE_SITE search-replace 'https://$LIVE_SITE' 'https://staging.$LIVE_SITE' wp_post* --skip-columns=guid --allow-root"

        else
            echo "Export failed. Skipping import."
        fi

    elif [[ $sync_choice == "3" ]]; then
        # Full database sync & rewrite
        echo ""
        echo "Exporting the full database from $LIVE_SITE..."
        ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "gp wp $LIVE_SITE db export $STAGING_DB --add-drop-table --allow-root"

        echo ""
        echo "Importing the full database to $site..."
        ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "gp wp staging.$LIVE_SITE db import $STAGING_DB --allow-root"

        # Rewrite URLs from live to staging
        echo ""
        echo "Rewriting URLs from $LIVE_SITE to staging.$LIVE_SITE..."
        ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "gp wp staging.$LIVE_SITE search-replace 'https://$LIVE_SITE' 'https://staging.$LIVE_SITE' --skip-columns=guid --all-tables --allow-root"

    else
        echo "Invalid selection. Please try again."
        continue
    fi

    # Common steps for all sync methods
    # Clear the cache for the staging site
    echo ""
    echo "Clearing cache for staging.$LIVE_SITE..."
    ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "gp fix cached staging.$LIVE_SITE"

    # Delete the temporary database export files, if they exist
    echo ""
    echo "Deleting temporary database export files, if they exist..."
    ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "rm -f $STAGING_DB $WP_POSTS_DB"

    # Additional steps for full process
    if [[ $sync_choice == "1" ]]; then
        # Ask about syncing themes and plugins
        echo ""
        read -p "Do you want to copy themes from $LIVE_SITE? [y/N] " copy_themes
        if [[ $copy_themes =~ ^[Yy]$ ]]; then
            ssh -i "$PRIVATE_KEY_PATH" -T "root@$SERVER_IP" "cp -R /root/www/$LIVE_SITE/htdocs/wp-content/themes /root/www/$site/htdocs/wp-content/"
        fi

        echo ""
        read -p "Do you want to copy plugins from $LIVE_SITE? [y/N] " copy_plugins
        if [[ $copy_plugins =~ ^[Yy]$ ]]; then
            ssh -i "$PRIVATE_KEY_PATH" -T "root@$SERVER_IP" "cp -R /root/www/$LIVE_SITE/htdocs/wp-content/plugins /root/www/$site/htdocs/wp-content/"
        fi

        # Ask about copying additional folders from wp-content/uploads
        echo ""
        echo "Do you want to copy specific folders from wp-content/uploads? [y/N]"
        read -p "Your choice: " copy_upload_folders
        if [[ $copy_upload_folders =~ ^[Yy]$ ]]; then
            # List non-year directories in wp-content/uploads and store them in an array
            IFS=$'\n' non_year_dirs=($(ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "ls -1 /var/www/$LIVE_SITE/htdocs/wp-content/uploads | grep -vE '^(2003|2004|2005|2006|2007|2008|2009|201[0-9]|20[2-9][0-9])$'"))

            # Ask whether to copy each of these directories
            for dir in "${non_year_dirs[@]}"; do
                echo ""
                echo "Do you want to copy $dir? [y/N]"
                read -p "Your choice: " copy_dir
                if [[ $copy_dir =~ ^[Yy]$ ]]; then
                    echo "Copying $dir..."
                    ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "cp -R /var/www/$LIVE_SITE/htdocs/wp-content/uploads/$dir /var/www/staging.$LIVE_SITE/htdocs/wp-content/uploads/"
                fi
            done
        fi

        # Ask about creating Nginx custom rules for media files
        echo ""
        read -p "Do you want to create nginx custom rules for media files? [y/N] " create_nginx_rules
        if [[ $create_nginx_rules =~ ^[Yy]$ ]]; then
            NGINX_CONFIG_FILE="/var/www/staging.$LIVE_SITE/nginx/live-media-main-context.conf"
            LIVE_DOMAIN=${LIVE_SITE/www./}

            # Create Nginx configuration for redirecting media
            echo "Creating Nginx configuration for media redirects..."
            ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "echo 'location ~* ^/wp-content/uploads/(.*)\$ { rewrite ^/wp-content/uploads/(.*)\$ https://$LIVE_DOMAIN/wp-content/uploads/\$1 redirect; }' > $NGINX_CONFIG_FILE"

            # Test and reload Nginx
            echo "Testing and reloading Nginx..."
            ssh -i "$PRIVATE_KEY_PATH" root@"$SERVER_IP" "nginx -t && gp ngx reload"
        fi
    fi

    # Add more steps as needed
    echo ""
    read -p "Do you want to sync another site? [y/N] " sync_another
    [[ $sync_another =~ ^[Yy]$ ]] || break
done

echo "Synchronization complete."