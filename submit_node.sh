#!/bin/bash -l

#SBATCH -o ./slurm_reports/job.out.%j
#SBATCH -e ./slurm_reports/job.err.%j
#SBATCH -D ./
#SBATCH -J dynamics_pipeline
#SBATCH --mail-type=ALL
#SBATCH --mail-user=slurm@flobnow.me
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=72
#SBATCH --time=24:00:00

# =============================================================================
# CONFIGURE THE RUN HERE
#
# Layout:
#   $PIPELINE_ROOT/1_input/                                 all .nd2 files
#   $PIPELINE_ROOT/1_input/dark_frames/
#   $PIPELINE_ROOT/2_parameter_tables/defaults.csv          ImageJ path etc.
#   $PIPELINE_ROOT/2_parameter_tables/parameter_tables_RUN/ images.csv, ...
#   $PIPELINE_ROOT/3_processing/RUN/                        working data
#   $PIPELINE_ROOT/4_output/RUN/                            results
#
# Normally the only things to change between runs are RUN and images.csv.
# =============================================================================

PIPELINE_ROOT='/ptmp/flobnow/new_pipe'
# RUN='20260811'
# RUN='20260813'
# RUN='20260814'
# RUN='20260821'
RUN='20261105' # !!

#### CHARMS Myddosome
RUN='Myddosomes_FC' # !!
# RUN='CHARMS_MyD88' # done
# RUN='CHARMS-MyD88_FC' # done
# RUN='CHARMS_IRAK1' # done
# RUN='CHARMS_IRAK2' # done
# RUN='CHARMS_IRAK3' # done
# RUN='CHARMS_IRAK4' # done
# RUN='CHARMS_hMyD88' # done
# RUN='CHARMS-hMyD88-E52R' # done
# RUN='CHARMS_hIRAK1' # done

#### spCHARMS Myddosome
# RUN='spCHARMS_MyD88_MyD88' # add new replicates --> repeat
# RUN='spCHARMS_MyD88_IRAK4' # add new replicates --> repeat
# RUN='spCHARMS_IRAK4_IRAK1' # add new replicates --> repeat
# RUN='spCHARMS_IRAK4_IRAK2' # add new replicates --> repeat
# RUN='spCHARMS_IRAK4_IRAK3' # add new replicates --> repeat
# RUN='spCHARMS_IRAK4_IRAK4' # done
# RUN='spCHARMS_IRAK4_MyD88' # done
# RUN='spCHARMS_IRAK1_IRAK1' # !!

#### bDD & EAD7
# RUN='CHARMS-Calon' # !! corrected nd2 input file name --> CHARMS_Calon to CHARMS-Calon
# RUN='CHARMS-Camai'
# RUN='CHARMS-Camai-Sen-D26K' # cl857
# RUN='CHARMS-Camai-Sen-D26R' # cl858
# RUN='CHARMS_Nihal'
# RUN='CHARMS_Bradiu'
# RUN='cl707' # CHARMS-Nicom-Sen
# RUN='cl708' # CHARMS-Nicom-Eff

# RUN='spCHARMS_v1_Camai'
# RUN='spCHARMS_v2_Camai'
# RUN='spCHARMS-v2-Camai-Eff-D320K'
# RUN='spCHARMS-v2-Camai-Sen-D26K'                 # cl854
# RUN='spCHARMS-v2-Camai-Sen-D26R'                 # cl855
#RUN='spCHARMS-v2-Camai-Sen-D26K_Camai-Eff-320K'  # cl856

# RUN='spCHARMS-v1-Nihal-Eff_Nihal-Sen'
# RUN='spCHARMS-v2-Nihal-Eff_Nihal-Sen'
# RUN='spCHARMS_Nihal-Sen_Nihal-Eff'
# RUN='cl810' # spCHARMS-v2-Nicom-Eff-Nicom-Sen
# RUN='CHARMS_spCHARMS_Nicom'

# RUN='test_run'

### Bact Microscopy
#RUN='20260910'
# RUN='20261001'

# Which stages to run.
#   ''                  -> everything not yet recorded as done (normal case)
#   'track'             -> only tracking
#   'segment,substacks' -> only those two
# Order: convert darkframe median tracking_ref combine segment substacks track
STAGES=''
 
# Restart from / stop at a stage (ignored when STAGES is set).
FROM_STAGE=''
TO_STAGE=''
 
# Restrict to specific images from images.csv (comma-separated, exact names).
IMAGES=''
 
FORCE=FALSE            # redo work even if the manifest says it is done
STATUS_ONLY=FALSE      # print the image x stage table and exit
MEDIAN_PARALLEL=FALSE  # ray workers die on this stage; serial is the known-good path
 
# What to run
# !!
run_main_pipe=TRUE
# !!
run_r_scripts=TRUE
 
# Batch-level Parameters/Analysis/Essential.csv.gz in 4_output/RUN.
# These are only rbindlist() of the per-image files, which are written either
# way. FALSE saves the peak-memory step and loses no information.
MAKE_GRAND_TABLE=FALSE
export MAKE_GRAND_TABLE
 
# Run the R scripts when some SAMPLE images failed but the calibrations are
# intact (mission_control.py exit code 3)? The R scripts then run on the images
# that finished; the failed ones are excluded from summary.csv and moved to
# 3_processing/<RUN>/_incomplete.
# A calibration failure (exit 1) always stops the run: without calibrations the
# batch cannot be quantified.
run_r_on_partial=TRUE
 
# Run the R scripts even after a fatal failure (exit 1). Almost never right.
run_r_after_fatal=FALSE
 
N_CPUS=12
 
# =============================================================================
 
set -o pipefail
 
path="${PIPELINE_ROOT}/2_parameter_tables/parameter_tables_${RUN}"
 
if [ ! -d "$path" ]; then
    echo "FATAL: parameter table folder does not exist: $path"
    exit 2
fi
 
mkdir -p ./slurm_reports
 
## Scripts folder
cd /raven/u/flobnow/dynamics_pipeline_v2 || exit 2
 
## Source uv environment
source /u/flobnow/dynamics_pipeline_v2/dypi_env/.venv/bin/activate
echo 'uv environment sourced'
 
module purge
module load jdk/8.265 gcc/10 impi/2021.2 fftw-mpi
echo 'modules loaded'
 
conda activate rdpipe
echo 'rdpipe env activated'
 
# The R scripts read a generated, fully-resolved copy of the parameter tables
# from inside the processing folder. Ask mission_control.py where that is; this
# also creates the run folders on first use.
# stdout carries only the path (log output goes to stderr), but take the last
# line and validate it anyway -- a stray line here silently corrupts the
# --args value handed to every R script.
r_path=$(python mission_control.py "$path" --print-r-path 2>/dev/null | tail -n 1)
if [ -z "$r_path" ] || [ ! -d "$r_path" ]; then
    echo "FATAL: could not resolve the parameter tables path for the R scripts."
    echo "       got: '$r_path'"
    python mission_control.py "$path" --print-r-path
    exit 2
fi
 
echo "RUN         : $RUN"
echo "parameters  : $path"
echo "tables for R: $r_path"
 
# Assemble optional arguments
ARGS=()
[ -n "$STAGES" ]          && ARGS+=(--stages "$STAGES")
[ -n "$FROM_STAGE" ]      && ARGS+=(--from "$FROM_STAGE")
[ -n "$TO_STAGE" ]        && ARGS+=(--to "$TO_STAGE")
[ -n "$IMAGES" ]          && ARGS+=(--images "$IMAGES")
[ "$FORCE" = TRUE ]       && ARGS+=(--force)
[ "$STATUS_ONLY" = TRUE ] && ARGS+=(--status)
[ "$MEDIAN_PARALLEL" = TRUE ] && ARGS+=(--median-parallel)
 
echo "extra args  : ${ARGS[*]}"
 
pipeline_rc=0
 
## Run main pipeline
if [ "$run_main_pipe" = TRUE ]; then
    echo 'run_main_pipe = TRUE'
    python mission_control.py "$path" "$N_CPUS" "${ARGS[@]}"
    pipeline_rc=$?
    echo "end of mission_control.py (exit code $pipeline_rc)"
else
    echo 'run_main_pipe = FALSE, skipping mission_control.py'
fi
 
# Decide whether the R scripts should run.
#   0 -> everything finished
#   3 -> some sample images failed, calibrations intact, batch still analysable
#   * -> fatal
run_r=FALSE
case "$pipeline_rc" in
    0)
        run_r=TRUE
        ;;
    3)
        if [ "$run_r_on_partial" = TRUE ]; then
            echo "Some sample images failed, but the calibrations are intact."
            echo "Running the R scripts on the images that finished."
            run_r=TRUE
        else
            echo "Some sample images failed and run_r_on_partial=FALSE."
        fi
        ;;
    *)
        echo "Python pipeline exited $pipeline_rc (fatal)."
        echo "Inspect with:  python mission_control.py \"$path\" --status"
        if [ "$run_r_after_fatal" = TRUE ]; then
            echo "run_r_after_fatal=TRUE, continuing anyway."
            run_r=TRUE
        fi
        ;;
esac
 
if [ "$run_r" != TRUE ]; then
    echo "Skipping R scripts."
    exit "$pipeline_rc"
fi
 
## Run R scripts
if [ "$run_r_scripts" = TRUE ] && [ "$STATUS_ONLY" != TRUE ] && [ "$run_r" = TRUE ]; then
 
    echo 'run_r_scripts = TRUE'
 
    export NUMEXPR_MAX_THREADS=144
    export OMP_NUM_THREADS=144
 
    r_rc=0
    Rscript --vanilla --verbose r_scripts/extract_intensity.R "$r_path" || r_rc=$?
    echo "end of extract_intensity.R (rc $r_rc)"
 
    if [ "$r_rc" -eq 0 ]; then
        Rscript --vanilla --verbose r_scripts/colocalization.R "$r_path" || r_rc=$?
        echo "end of colocalization.R (rc $r_rc)"
    fi
 
    if [ "$r_rc" -eq 0 ]; then
        Rscript --vanilla --verbose r_scripts/compile_tables.R "$r_path" || r_rc=$?
        echo "end of compile_tables.R (rc $r_rc)"
    fi
 
    if [ "$r_rc" -ne 0 ]; then
        echo "R scripts failed (rc $r_rc)"
        exit "$r_rc"
    fi
else
    echo 'run_r_scripts = FALSE, skipping r_scripts'
fi
 
conda deactivate
 
echo 'end of submit_node.sh script'
sleep 3
 
# Exit 3 means "partial but analysable, and the R scripts ran". Report it as a
# success to Slurm so the mail notification is not alarming, but say so here.
if [ "$pipeline_rc" -eq 3 ]; then
    echo "NOTE: some sample images failed; the R scripts ran on the rest."
    echo "      See the SUMMARY table above and 3_processing/<RUN>/_incomplete."
    exit 0
fi
 
exit "$pipeline_rc"
