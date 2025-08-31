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
#SBATCH --time=3:00:00

# Load all needed packages
module purge
module load jdk/8.265 gcc/10 impi/2021.2 fftw-mpi R/4.0.2
echo 'modules loaded'

## Ensure that the environment is available
source /u/flobnow/dynamics_pipeline_v2/dypi_env/.venv/bin/activate
echo 'environment activated'
#conda activate dynamics_pipeline
#echo 'conda activated'

## Specify path to  parameter tables
path=$'/raven/u/flobnow/pipeline/pending_processing/TEST_BATCH/Input/parameter_tables'

## Scripts folder
cd /raven/u/flobnow/dynamics_pipeline_v2

## Cores for parallel processing in R
export NUMEXPR_MAX_THREADS=144
export OMP_NUM_THREADS=144

# Run scripts
## Python scripts
python mission_control.py $path 12

# Run R Scripts
Rscript --vanilla --verbose r_scripts/extract_intensity.R $path
Rscript --vanilla --verbose r_scripts/colocalization.R $path
Rscript --vanilla --verbose r_scripts/compile_tables.R $path
## Rscript --vanilla --verbose r_scripts/compress_everything.R $path

sleep 3
