#!/bin/sh
# Name: Dropbear SSH
# Author: Akshay
# DontUseFBInk

if [ ! -x /var/local/kmc/bin/kpm ]; then
    echo "ERROR: KPM (Kindle Package Manager) not found at /var/local/kmc/bin/kpm."
    echo "Make sure your jailbreak includes KMC/KPM."
    sleep 6
    exit 1
fi

KPM=/var/local/kmc/bin/kpm
if [ ! -d /mnt/us/kmc/kpm/packages/dropbear-ssh ]; then
    echo "First time setup: downloading Dropbear SSH via Wi-Fi..."
    $KPM add-repo https://nealing.net/manifest.json
    $KPM install dropbear-ssh
    if [ $? -ne 0 ]; then
        echo "Install failed! Please make sure Kindle is connected to Wi-Fi."
        sleep 6
        exit 1
    fi
fi
$KPM launch dropbear-ssh
