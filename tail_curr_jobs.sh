#!/usr/bin/env bash

path="/u/$USER/dynamics_pipeline_v2/slurm_reports"
runtime="600 minute"  # 10 hours
interval=3             # seconds between updates
n_lines=8

endtime=$(date -ud "$runtime" +%s)

while [[ $(date -u +%s) -le $endtime ]]; do
    clear
    echo "______________________________________________"
    echo "current squeue"
    squeue -u "$USER"
    echo "$(date +%H:%M:%S)"
    echo "______________________________________________"

    # Refresh the list of latest files each iteration
    files=$(ls -1t "$path"/job.err* "$path"/job.out* 2>/dev/null | head -n 2)

    if [ -z "$files" ]; then
        echo "No matching files found."
    else
        for file in $files; do
            echo ""
            echo ">>>>>>>> $file <<<<<<<<"
            tail -n "$n_lines" "$file"
            echo "______________________________________________"
        done
    fi

    sleep "$interval"
done
