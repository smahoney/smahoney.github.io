#!/bin/sh
#
# ** This script should only be run in macOS Monterey Recovery Mode, and only if macOS Monterey is the installed OS on the system. **
# ** THIS HAS ONLY BEEN TESTED ON AN INTEL-BASED MAC! **
#
# The purpose of this script is to alter the behavior of the SSH ('Remote Login') and VNC ('Screen Sharing') services in macOS Monterey such that:
#
# 1. SSH listens on a different port (22022) than the default (22).
# 2. Bonjour advertisement of SSH is disabled.
# 3. VNC listens on a different port (59059) than the default (5900).
# 4. VNC only listens to localhost.
# 5. Bonjour advertisement of VNC is disabled.
# 6. The ability for the 'root' user to log in via SSH is disabled.
# 7. Password authentication via SSH is disabled (only SSH key pair authentication is allowed).
# 8. SSH authentication is limited to one user on the system.
#
# The above changes make it possible to use VNC tunneled through SSH without those services being advertised via Bonjour, without using default port numbers,
# without allowing direct connections to VNC, while also restricting SSH access to one non-root user limited to SSH key pair authentication.
#
# ** THIS SCRIPT SHOULD ONLY BE RUN IF *ALL* OF THE FOLLOWING ARE TRUE: **
#
# 1. You want remote connectivity via tunneled VNC through SSH to the Mac this script is being run on.
# 2. The installed OS on the Mac is macOS Monterey.
# 3. The macOS Monterey installation only has one user (otherwise this script cannot determine the user who needs SSH access).
# 4. You will enable SSH ('System Preferences' > 'Sharing' > 'Remote Login') and VNC ('System Preferences' > 'Sharing' > 'Screen Sharing') for that one user.
# 5. You will configure SSH key pair authentication for that one user (this script does not do so, but it does disable SSH password authentication).
# 6. This script is being run on a Mac booted into macOS Monterey Recovery Mode (THIS SCRIPT *MUST* BE RUN IN RECOVERY MODE).
# 7. A Time Machine backup was completed prior to booting into Recovery Mode and you're comfortable with restoring from a backup if something goes wrong.
# 8. File Vault ('System Preferences' > 'Security & Privacy' > 'FileVault') was turned off in macOS Monterey prior to booting into Recovery Mode.
# 9. You fully understand that these changes rely on PERMANENTLY allowing booting from non-sealed system snapshots in order for the system to continue to boot.
# 10. You fully understand the potential security trade-offs involved with no longer booting from Apple's cryptographically signed 'sealed' APFS snapshot.
#
# If you're unsure what the last two points above are referring to, please see the following for more information:
#   - https://mobile.twitter.com/enhancedscurry/status/1275454103900971012
#   - https://eclecticlight.co/2020/06/25/big-surs-signed-system-volume-added-security-protection/
#   - https://forums.macrumors.com/threads/words-of-caution-regarding-modification-of-system-files-using-csrutil-authenticated-root-disable.2276764/

# Intro Text
# ----------
echo
echo "======================================"
echo "macOS Monterey SSH/VNC Lockdown Script"
echo "======================================"
echo


# Gather System Volume Information
# --------------------------------
system_volume_device=`mount | grep '(apfs, sealed, local, read-only, journaled, nobrowse)' | awk '{ print $1 }'`
if [[ -z "$system_volume_device" ]]
then
  echo "[ERROR] Unable to determine system volume device."
  exit 1
else
  echo "[x] Determining system volume device...  $system_volume_device"
fi

system_volume_name=`diskutil info $system_volume_device | grep 'Mount Point' | awk -F '/Volumes/' '{ print $NF }' | sed 's/ /\\ /g'`
if [[ -z "$system_volume_name" ]]
then
  echo "[ERROR] Unable to determine system volume name."
  exit 1
fi

system_volume_mount_point="/Volumes/$system_volume_name"
if [[ ! -d "$system_volume_mount_point" ]]
then
  echo "[ERROR] Unable to determine system volume mount point."
  exit 1
else
  echo "[x] Determining system volume mount point...  $system_volume_mount_point"
fi

readonly_ssh_plist_file="$system_volume_mount_point/System/Library/LaunchDaemons/ssh.plist"
if [[ ! -f "$readonly_ssh_plist_file" ]]
then
  echo "[ERROR] Unable to find /System/Library/LaunchDaemons/ssh.plist on system volume."
  exit 1
fi

readonly_screensharing_plist_file="$system_volume_mount_point/System/Library/LaunchDaemons/com.apple.screensharing.plist"
if [[ ! -f "$readonly_screensharing_plist_file" ]]
then
  echo "[ERROR] Unable to find /System/Library/LaunchDaemons/com.apple.screensharing.plist on system volume."
  exit 1
fi


# Gather Data Volume Information
# ------------------------------
data_volume_device=`mount | grep 'Data (apfs, local, journaled, nobrowse)' | awk '{ print $1 }'`
if [[ -z "$data_volume_device" ]]
then
  echo "[ERROR] Unable to determine data volume device."
  exit 1
else
  echo "[x] Determining data volume device...  $data_volume_device"
fi

data_volume_name=`diskutil info $data_volume_device | grep 'Mount Point' | awk -F '/Volumes/' '{ print $NF }' | sed 's/ /\\ /g'`
if [[ -z "$data_volume_name" ]]
then
  echo "[ERROR] Unable to determine data volume name."
  exit 1
fi

data_volume_mount_point="/Volumes/$data_volume_name"
if [[ ! -d "$data_volume_mount_point" ]]
then
  echo "[ERROR] Unable to determine data volume mount point."
  exit 1
else
  echo "[x] Determining data volume mount point...  $data_volume_mount_point"
fi

sshd_config_file="$data_volume_mount_point/private/etc/ssh/sshd_config"
if [[ ! -f "$sshd_config_file" ]]
then
  echo "[ERROR] Unable to find /private/etc/ssh/sshd_config on data volume."
  exit 1
fi

root_home_directory="$data_volume_mount_point/private/var/root"
if [[ ! -d "$root_home_directory" ]]
then
  echo "[ERROR] Unable to find /private/var/root (root's home directory) on data volume."
  exit 1
fi

users_directory="$data_volume_mount_point/Users"
if [[ ! -d "$users_directory" ]]
then
  echo "[ERROR] Unable to find /Users (parent directory of non-root user home directories) on data volume."
  exit 1
fi

# Determine the number of users on the system (this script cannot determine the macOS Monterey user who needs SSH access if there's more than one user).
number_of_users=`ls "$users_directory" | grep -v '.localized' | grep -v 'Shared' | wc -l`
if [[ "$number_of_users" != "1" ]]
then
  echo "[ERROR] This script can only be used on macOS Monterey installations with one user."
  exit 1
else
  echo "[x] Determining number of macOS Monterey users...  $number_of_users"
fi

# Determine the username of the macOS Monterey user who needs SSH access.
macos_username=`ls "$users_directory" | grep -v '.localized' | grep -v 'Shared'`
if [[ -z "$macos_username" ]]
then
  echo "[ERROR] Unable to determine username of macOS Monterey user."
  exit 1
else
  echo "[x] Determining username of macOS Monterey user...  $macos_username"
fi


# File Backups
# ------------
date_time_suffix=`date +%Y%m%d%H%M%S`

cp -a $readonly_ssh_plist_file $root_home_directory/System_Library_LaunchDaemons_ssh.plist.$date_time_suffix
if [[ ! -f "$root_home_directory/System_Library_LaunchDaemons_ssh.plist.$date_time_suffix" ]]
then
  echo "[ERROR] Backup of /System/Library/LaunchDaemons/ssh.plist to /var/root/System_Library_LaunchDaemons_ssh.plist.$date_time_suffix on data volume failed."
  exit 1
else
  echo "[x] Backing up /System/Library/LaunchDaemons/ssh.plist to /var/root/System_Library_LaunchDaemons_ssh.plist.$date_time_suffix on data volume..."
fi

cp -a $readonly_screensharing_plist_file $root_home_directory/System_Library_LaunchDaemons_com.apple.screensharing.plist.$date_time_suffix
if [[ ! -f "$root_home_directory/System_Library_LaunchDaemons_com.apple.screensharing.plist.$date_time_suffix" ]]
then
  echo "[ERROR] Backup of /System/Library/LaunchDaemons/com.apple.screensharing.plist to /var/root/System_Library_LaunchDaemons_com.apple.screensharing.plist.$date_time_suffix on data volume failed."
  exit 1
else
  echo "[x] Backing up /System/Library/LaunchDaemons/com.apple.screensharing.plist to /var/root/System_Library_LaunchDaemons_com.apple.screensharing.plist.$date_time_suffix on data volume..."
fi

cp -a $sshd_config_file $root_home_directory/etc_ssh_sshd_config.$date_time_suffix
if [[ ! -f "$root_home_directory/etc_ssh_sshd_config.$date_time_suffix" ]]
then
  echo "[ERROR] Backup of /etc/ssh/sshd_config to /var/root/etc_ssh_sshd_config.$date_time_suffix on data volume failed."
  exit 1
else
  echo "[x] Backing up /etc/ssh/sshd_config to /var/root/etc_ssh_sshd_config.$date_time_suffix on data volume..."
fi


# Allow Booting From Non-Sealed System Snapshots
# ----------------------------------------------
echo "[x] Allow booting from non-sealed system snapshots ('csrutil authenticated-root disable')..."
echo
#csrutil authenticated-root disable
csrutil authenticated-root status
echo


# Remount System Volume Read-Write
# --------------------------------
readwrite_system_volume_mount_point="/tmp/system_volume_mnt"

echo "[x] Creating temporary mount point for mounting system volume read-write..."
mkdir -p $readwrite_system_volume_mount_point

echo "[x] Unmounting read-only system volume..."
umount $system_volume_device

echo "[x] Remounting system volume read-write..."
mount -o nobrowse -t apfs $system_volume_device $readwrite_system_volume_mount_point


# File Updates
# ------------
readwrite_ssh_plist_file="$readwrite_system_volume_mount_point/System/Library/LaunchDaemons/ssh.plist"
readwrite_screensharing_plist_file="$readwrite_system_volume_mount_point/System/Library/LaunchDaemons/com.apple.screensharing.plist"

echo "[x] Updating /System/Library/LaunchDaemons/ssh.plist on system volume..."
#perl -0777 -i -pe 's/<string>ssh<\/string>\s+<key>Bonjour<\/key>\s+<array>\s+<string>ssh<\/string>\s+<string>sftp-ssh<\/string>\s+<\/array>/<string>22022<\/string>/' $readwrite_ssh_plist_file
perl -0777 -i -pe 's/<string>ssh<\/string>\s+<key>Bonjour<\/key>\s+<array>\s+<string>ssh<\/string>\s+<string>sftp-ssh<\/string>\s+<\/array>/<string>22022<\/string>/' $root_home_directory/System_Library_LaunchDaemons_ssh.plist.$date_time_suffix

echo "[x] Updating /System/Library/LaunchDaemons/com.apple.screensharing.plist on system volume..."
#perl -0777 -i -pe 's/<key>Bonjour<\/key>(\s+)<string>rfb<\/string>(\s+)<key>SockServiceName<\/key>(\s+)<string>vnc-server<\/string>/<key>SockNodeName<\/key>$1<string>localhost<\/string>$2<key>SockServiceName<\/key>$3<string>59059<\/string>/' $readwrite_screensharing_plist_file
perl -0777 -i -pe 's/<key>Bonjour<\/key>(\s+)<string>rfb<\/string>(\s+)<key>SockServiceName<\/key>(\s+)<string>vnc-server<\/string>/<key>SockNodeName<\/key>$1<string>localhost<\/string>$2<key>SockServiceName<\/key>$3<string>59059<\/string>/' $root_home_directory/System_Library_LaunchDaemons_com.apple.screensharing.plist.$date_time_suffix

echo "[x] Updating /private/etc/ssh/sshd_config on data volume..."
echo >> "$sshd_config_file"
echo "[x] Disabling the ability for the 'root' user to log in via SSH..."
echo "PermitRootLogin no" >> "$sshd_config_file"
echo "[x] Disabling SSH password authentication (only SSH key pair authentication will be allowed)..."
echo "PasswordAuthentication no" >> "$sshd_config_file"
echo "ChallengeResponseAuthentication no" >> "$sshd_config_file"
echo "[x] Limiting SSH authentication to macOS Monterey user ${macos_username}..."
echo "AllowUsers $macos_username" >> "$sshd_config_file"


# Save New APFS Snapshot
# ----------------------
echo "[x] Saving new APFS snapshot..."
echo "bless --folder $readwrite_system_volume_mount_point/System/Library/CoreServices --bootefi --create-snapshot"


# Ending Text
# -----------
echo
echo "This script has successfully completed and the system can now be rebooted."
echo
