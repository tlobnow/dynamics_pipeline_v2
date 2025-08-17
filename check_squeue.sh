#!/usr/bin/env bash

countdown() {
    start="$(( $(date '+%s') + $1))"
    while [ $start -ge $(date +%s) ]; do
        time="$(( $start - $(date +%s) ))"
        printf '%s\r' "$(date -u -d "@$time" +%H:%M:%S)"
        sleep 0.1
    done
}

runtime="600 minute"
endtime=$(date -ud "$runtime" +%s)
N=10

while [[ $(date -u +%s) -le $endtime ]]
do
    clear
    squeue -u $USER
    echo "`date +%H:%M:%S`"
    countdown $N & sleep $N
done
