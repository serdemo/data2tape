# data2tape
 Offsite tape backups with IBM or Lenovo tape librarires

# Description:
 This script helps automate offsite tape backups.
 It will automatically select a drive and a tape to write a single given directory and all of its contents or a single given file to a tape, then export the tape to a free IO slot.

# Required configuration files:
 - ./cfg/lib.cfg: LIB_X_${SITE}:LIB_SERIAL:ACCESS(ALLOW|DENY)
 - ./cfg/drive.cfg: DRIVE_X_${SITE}:DRIVE_SERIAL:ACCESS(ALLOW|DENY)

# Command example:
 ./data2tape.sh site1 /directory "Archive description"

# Prerequisites:
 - ITDT utility: https://datacentersupport.lenovo.com/us/en/products/storage/tape-and-backup/ts4300-tape-library-for-lenovo/6741/downloads/driver-list/component?name=Software%20and%20Utilities&id=156BE23F-B536-4320-B35C-2F67EBDD9242
 - lin_tape driver: https://datacentersupport.lenovo.com/us/en/products/storage/tape-and-backup/ts4300-tape-library-for-lenovo/6741/downloads/driver-list/component?name=Software%20and%20Utilities&id=156BE23F-B536-4320-B35C-2F67EBDD9242

# Test environment:
 REDOS 7.3, kernel: 5.15.131-1.el7.3.x86_64, driver: lin_tape v3.0.59, ITDT v9.6.2.20231114, Tape library: TS4300 Type 6741

# CAUTION:
 To avoid data loss don't use this script with the libraries managed by another backup software. Use a separate library with a separate scratch tapes pool.
