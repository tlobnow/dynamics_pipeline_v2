#!/bin/bash -l

#SBATCH -o ./slurm_reports/job.out.%j
#SBATCH -e ./slurm_reports/job.err.%j
#SBATCH -D ./
#SBATCH -J dynamics_pipeline
#SBATCH --mail-type=ALL
#SBATCH --mail-user=slurm@<USERNAME>.me
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=72
#SBATCH --time=3:00:00

# Set to TRUE if you want to run main pipeline (mission_control.py) or the R scripts (default = both set to TRUE)
run_main_pipe=TRUE
run_r_scripts=TRUE

## Specify path to  parameter tables
path=$'/raven/u/<USERNAME>/pipeline/pending_processing/BATCH/Input/parameter_tables'

## Scripts folder
cd /raven/u/<USERNAME>/dynamics_pipeline_v2

## Source uv environment
source /u/<USERNAME>/dynamics_pipeline_v2/dypi_env/.venv/bin/activate
echo 'uv environment sourced'

## Run scripts
if [ "$run_main_pipe" = TRUE ]; then

    echo 'run_main_pipe = TRUE'

    # Load all needed packages
    module purge
    module load jdk/8.265 gcc/10 impi/2021.2 fftw-mpi
    echo 'modules loaded'

    # Activate conda environment
    conda activate rdpipe
    echo 'rdpipe env activated'

    # Run main pipeline
    python mission_control.py $path 12 ; echo 'end of mission_control.py'
    conda deactivate
else
    echo 'run_main_pipe = FALSE, skipping mission_control.py'
fi

# Activate r_scripts environment if run_r_scripts = TRUE
if [ "$run_r_scripts" = TRUE ]; then

    echo 'run_r_scripts = TRUE'

    ## Cores for parallel processing in R
    export NUMEXPR_MAX_THREADS=144
    export OMP_NUM_THREADS=144

    conda deactivate
    conda activate rdpipe
    echo 'rdpipe env activated'

    # Run R Scripts
    Rscript --vanilla --verbose r_scripts/extract_intensity.R $path ; echo 'end of extract_intensity.R'
    Rscript --vanilla --verbose r_scripts/colocalization.R $path    ; echo 'end of colocalization.R'
    Rscript --vanilla --verbose r_scripts/compile_tables.R $path    ; echo 'end of compile_tables.R'
    ## Rscript --vanilla --verbose r_scripts/compress_everything.R $path
else
    echo 'run_r_scripts = FALSE, skipping r_scripts'
fi

echo 'end of submit_node.sh script'

sleep 3
