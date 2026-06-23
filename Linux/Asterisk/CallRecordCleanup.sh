#!/bin/bash

###=========================================================================================
# Description:
# This script cleans up old Asterisk call recordings from a specified directory.
# It performs the following actions:
#
# 1. Scans the target directory (and all subdirectories) for files older than 90 days.
# 2. Deletes each file while keeping track of:
#   - Total number of deleted files
#   - Cumulative size of deleted files
# 4. Removes any empty directories after file deletion.
# 5. Logs the cleanup operation to a log file with timestamps, including:
#    - Start and finish of the cleanup
#    - Number of files deleted
#    - Total size of deleted files
# 
# Notes:
# - Only summary information is logged; individual file names are not logged.
###==========================================================================================


TARGET_DIR="/var/spool/asterisk/monitor"
LOG_FILE="/var/log/recordings_cleanup.log"

timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

echo "$(timestamp) - Cleanup started..." >> "$LOG_FILE"
echo "$(timestamp) - Target directory: $TARGET_DIR" >> "$LOG_FILE"

###==== Find old recordings and store in an array=============================================
mapfile -t OLD_FILES < <(find "$TARGET_DIR" -type f -mtime +90)

TOTAL_COUNT=${#OLD_FILES[@]}
TOTAL_SIZE=0

###==== Delete files and accumulate total size ================================================
for file in "${OLD_FILES[@]}"; do
    if [ -f "$file" ]; then
        FILE_SIZE=$(stat -c%s "$file")
        TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))
        rm -f "$file"
    fi
done

###=== Remove empty directories ===============================================================
find "$TARGET_DIR" -type d -empty -delete

###=== Convert total size to human-readable format (KB/MB/GB) =================================
TOTAL_HUMAN=$(numfmt --to=iec "$TOTAL_SIZE")

echo "$(timestamp) - Deleted $TOTAL_COUNT old recordings, total size $TOTAL_HUMAN" >> "$LOG_FILE"
echo "$(timestamp) - Cleanup finished." >> "$LOG_FILE"
