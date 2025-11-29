# Portainer Backup & Restore

This project installs a systemd timer that backs up the `portainer_data` volume to `/opt/portainer/backups` and optionally syncs it to Google Drive using `rclone`.

## Backup behavior
- Archive name pattern: `portainer-YYYYMMDD-HHMMSS.tar.gz`.
- Location: `/opt/portainer/backups` (mounted from the host).
- Google Drive: uploaded to the remote `portainer_gdrive:portainer-backups/` if the remote exists.

To run a manual backup at any time:

```bash
sudo /usr/local/bin/portainer-gdrive-backup.sh
```

## Restore steps
1. Copy the desired backup archive back to the server (or download it from Google Drive).
2. Stop Portainer:
   ```bash
   sudo docker stop portainer
   ```
3. Restore the archive into the `portainer_data` volume:
   ```bash
   sudo docker run --rm -v portainer_data:/data -v /path/to/backups:/backup alpine \
     sh -c "rm -rf /data/* && tar xzf /backup/portainer-YYYYMMDD-HHMMSS.tar.gz -C /"
   ```
   Replace `YYYYMMDD-HHMMSS` and `/path/to/backups` with your values.
4. Start Portainer again:
   ```bash
   sudo docker start portainer
   ```

> Tip: keep the backup filenames intact so the restore command can find the archive easily.
