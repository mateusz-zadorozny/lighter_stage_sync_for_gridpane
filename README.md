# Why I created Lighter Stage sync?

Some of the sites deployed on my GridPane servers have massive media files (over 10GB), so creating staging sites with full sync uses a lot of disk space.

With proper config we sync the staging with our live site, but we use the media just from the live site - saving the disk space on the server.

## How to use?

### One-time setup

1. Make sure you can reach each server with a plain `ssh <alias>` (e.g. `ssh bo`).
   This means having a matching `Host` entry in your `~/.ssh/config` that carries
   the user, hostname and key:

   ```
   Host bo
       HostName 231.x.x.x
       User root
       IdentityFile ~/.ssh/your_key
   ```

2. Copy the example config and fill in your own sites:

   ```
   cp .env.example .env
   ```

   In `.env`, `SITES` is a newline-separated list of `<ssh_alias>|<live_domain>`
   entries. Staging is derived automatically as `staging.<live_domain>`:

   ```
   SITES="
   bo|example.com
   bo|shop.example.com
   ko|another-site.com
   "
   ```

   `.env` is git-ignored, so your connection details never get committed.

### Each sync

1. Create a staging site through the GridPane panel, set SSL (or not) and check it works.
2. Create a backup of your primary site in the GridPane panel, in case of an error.
3. In a terminal in this folder run: `bash lighter_stage_sync_for_gridpane.sh`
4. Pick the site you want to sync (the SSH connection is chosen automatically from `.env`).
5. Choose a sync method:
   - **1** — full process: full database, then *asks* about copying files and the nginx rule.
   - **2** — quick sync of `wp_posts` & `wp_postmeta` only (does not trigger neutralization).
   - **3** — full database sync & rewrite only (no files).
   - **4** — EVERYTHING, no questions: full database + all files + nginx rule + neutralization.
6. After the database sync the script will ask you to sync plugins, theme or folders in wp-content/uploads (not the media ones).
7. Finally the script will ask you for an nginx rule rewrite, to use the live site media instead of ones in `staging.yoursite.com/...` folders.

After initial sync - rewriting nginx is not necessary. The staging site should use the media from the live site.