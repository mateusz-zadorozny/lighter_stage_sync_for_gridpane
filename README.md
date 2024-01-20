# Why I created Lighter Stage sync?

Some of the sites deployed on my GridPane servers have massive media files (over 10GB), so creating staging sites with full sync uses a lot of disk space.

With proper config we sync the staging with our live site, but we use the media just from the live site - saving the disk space on the server.

## How to use?

1. Create a staging site through the GridPane panel, set SSL (or not) and check if it works
2. Create backup for your primary site in GridPane panel in case you make an error while editing the bash file
2. Create a copy of lighter_stage_sync_for_gridpane.sh file and name it sync_light.sh (to be ignored by Git)
3. Fill in your private key location in sync_light.sh in line 4
4. Add GridPane servers you want to work with (line 7 for friendly names, line 8 for IPs)
5. Save the file
6. In terminal in the folder run following command: bash sync_light.sh
7. Pick the server and choose the staging site you want to sync
8. After database sync the script will ask you to sync plugins, theme or folders in in wp-uploads/content (not the media ones)
9. Finally the script will ask you for nginx rules rewrite to use the live site media instead of ones in staging.yoursite.com/... folders

After initial sync - rewriting nginx is not necessary. The staging site should use the media from the live site.