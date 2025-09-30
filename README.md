# Dynamics Pipeline v2

High-throughput image analysis pipeline for TIRF-M. 
Packaged for use on **Raven**.

## 🚀 Quick Start

1. [Prerequisites](#prerequisites)
2. [Cluster login & SSH tunnel](#1-cluster-login--ssh-tunnel)
3. [Environment setup](#2-environment-setup)
4. [Run the test batch](#3-run-the-test-batch)
5. [Next steps: customize for your own data](#4-analyze-your-own-data)

> ⚡ **If you just want to test the pipeline, follow the Quick Start before adapting it for your own data.**

---

## Prerequisites
- Raven HPC access with your `<USERNAME>`
- R ≥ 4.3

---

## 1. Cluster Login & SSH Tunnel
### 1.1 🔑 Log in to the Cluster

From your local machine:

```bash
ssh <USERNAME>@raven.mpcdf.mpg.de
```
> ⚠️  Set up this [SSH config](#-ssh-setup) so you can just type `ssh raven` to upload/download files from/to the cluster and stay logged in a long time.

### 1.2 📥 Transfer Pipeline & Test Data

Open a new terminal window on your **LOCAL machine** (NOT the cluster) and have access to the **DATA-TAY** as per IT instructions.

```bash
rsync -a /Volumes/TAYLOR-LAB/Finn_v2/PIPELINE_RESOURCES/ raven:/u/<USERNAME>/
```

On the cluster, confirm that the files arrived:

```bash
ls
# should now list:
#   dynamics_pipeline_v2.zip
#   fiji-linux64.zip
#   dark_frames.tar.gz
#   BATCH.tar.gz
#   Miniconda3-latest-Linux-x86_64.sh
```

---

## 2. Environment Setup
### 2.1 Unpack resources

```bash
cd
# unpack pipeline & resources
unzip dynamics_pipeline_v2.zip
unzip fiji-linux64.zip
tar -xvzf dark_frames.tar.gz
tar -xvzf TEST_BATCH.tar.gz
```

### 2.2 Conda & R setup

Install Miniconda (if not already installed):

```bash
bash Miniconda3-latest-Linux-x86_64.sh # follow the instructions, type 'yes' when prompted

# add conda to your PATH
export PATH=~/miniconda/bin:$PATH
export PATH=~/miniconda3/bin:$PATH
source ~/miniconda3/bin/activate
```

To avoid conda issues with the defaults channel [see announcement from Aug 2024](https://www.theregister.com/2024/08/08/anaconda_puts_the_squeeze_on/), we need to adjust the `~/.condarc` file by replacing its contents. Open/Create the file with nano or your favorite text editor:

```bash
nano ~/.condarc
```

```yaml
channel_priority: strict
channels:
  - conda-forge
  - bioconda
  - r
  - anaconda
```

Create and activate the conda environment:

```bash
# create R environment with required packages
conda create -n r-xml-env -c conda-forge r-base=4.3 r-xml r-data.table r-dplyr pkg-config libtiff zlib libjpeg-turbo javabridge python=3.8
conda activate r-xml-env
R --version # should show R version 4.3.3 (2024-02-29) -- "Angel Food Cake"
```

Install R packages inside the R console:

```R
install.packages("pacman") # type [1] to select a mirror (any number should work)
pacman::p_load(XML, dplyr, data.table, parallel, tidyr, ff, changepoint, compiler, stringr, dtplyr, RANN, R.utils, ijtiff) # will take a while
# quit R by typing q() and pressing ENTER, then type 'n' when prompted to save workspace
```
> ✅ You only do this once per user account.

### 2.3 Install UV (Python package manager)

```bash
cd ~/dynamics_pipeline_v2/dypi_env
curl -LsSf https://astral.sh/uv/install.sh | sh
```

```bash
uv sync
# and add the environment bin to your path and to your bashrc
echo 'export PATH="/u/$USER/dynamics_pipeline_v2/dypi_env/.venv/bin/:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

[More info on uv](https://docs.astral.sh/uv/)

---

## 3. Run the Test Batch
### 3.1 Create folder structure

```bash
mkdir -p ~/pipeline/{raw,pending_processing,finished}
mv ~/BATCH ~/pipeline/pending_processing/
mv ~/dark_frames ~/pipeline/

# Expected folder structure of the ``pipeline`` directory:
# pipeline
# ├── dark_frames
# ├── finished
# ├── pending_processing
# │   └── BATCH
# │       ├── Input
# │       │   └── parameter_tables
# │       │       ├── constants.csv
# │       │       ├── dark_frames.csv
# │       │       ├── directories.csv
# │       │       ├── exclusion_channels.csv
# │       │       └── images.csv
# │       ├── Output                            # will be created by the pipeline
# │       └── Processing                        # will be created by the pipeline
# └── raw
```

Replace all occurrences of `<USERNAME>` in the dynamics_pipeline_v2 repository with your actual username:

```bash
cd ~/dynamics_pipeline_v2
grep -rl '<USERNAME>' . | xargs sed -i 's/<USERNAME>/your_actual_username/g'
```

### 3.2 Start the pipeline

```bash
cd ~/dynamics_pipeline_v2
sbatch submit_node.sh # adjust submit_node.sh to match your batch names for future runs
```

### 3.3 Monitor job status

```bash
# check your job status with
squeue -u $USER

# monitor your queue with
./check_squeue.sh

# monitor live output with
./tail_current_jobs.sh
```

### 3.4 Check output
After the job completes, check the output files in:

```bash
ls ~/pipeline/pending_processing/BATCH/Output/
# should contain essentials.csv.gz and parameters.csv.gz

# the slurm logs are in the `slurm_reports` folder and contain error and output logs, e.g. job.err.123456 and job.out.123456
ls ~/dynamics_pipeline_v2/slurm_reports/

```

### 3.5 Download output files
Download to your local machine for further analysis or install and configure [Visual Studio Code](https://code.visualstudio.com/) to connect to the cluster and work directly there.
Use `rsync` or `scp` to download the output files to your local machine:

> ⚠️  Run this command from your **LOCAL machine**, NOT the cluster!

```bash
rsync -a raven:/u/<USERNAME>/pipeline/pending_processing/BATCH/Output/ ~/local_folder/
```
---

## 4. Analyze Your Own Data

1. Prepare your raw images in `~/pipeline/raw/<your_analysis_folder>/`
2. Create a new analysis folder under `pending_processing/<your_analysis_folder>/`
3. Copy and adjust the `parameter_tables` (see Parameter Tables)
4. Update `directories.csv` with correct paths (absolute paths required)
5. Edit `submit_node.sh` to point to your new batch’s parameter table
6. Submit the job: `sbatch submit_node.sh`
7. Monitor job status and check output as before

---

## Additional Information
### SSH Setup

For frequent use, configure `~/.ssh/config` on both local machine and cluster:

```bash
mkdir -p ~/.ssh
nano ~/.ssh/config
```

Paste the snippet below and adjust `<USERNAME>`. You can replace <USERNAME> in nano by pressing `CTRL + \` and typing `<USERNAME>`, then pressing `ENTER` twice.

```bash
# General settings for all connections
Host *
    ControlMaster auto
    ControlPath ~/.ssh/control-%h-%p-%r
    ControlPersist yes
    LogLevel ERROR
    Port 22
    StrictHostKeyChecking ask
    UserKnownHostsFile ~/.ssh/known_hosts

# Gateway machines for Raven and Viper
Host gate1 gate2 raven viper
    User <USERNAME>
    HostName %h.mpcdf.mpg.de
    GSSAPIAuthentication yes
    GSSAPIDelegateCredentials yes

# Gateway machines for HPC nodes
Host raven viper
    ProxyJump gate1

# GitHub access (if needed)
Host github.com
        HostName github.com
        User git
        IdentityFile ~/.ssh/id_ed25519
        IdentitiesOnly yes

# Correctly resolve short names of gateway machines and HPC nodes
Match originalhost gate*,raven,viper
    CanonicalDomains mpcdf.mpg.de
    CanonicalizeFallbackLocal no
    CanonicalizeHostname yes

# Keep a tunnel open for the day when accessing the gate machines
Match canonical host gate*
    User <USERNAME>
    Compression yes
    ServerAliveInterval 120

# Keep a tunnel open for the day when accessing the HPC nodes
Match canonical host raven*,viper*
    User <USERNAME>
    Compression yes
    ProxyJump gate1

# It's possible to add more users here (not recommended for default users)
# Match user <USER> host gate1,gate2,raven,viper
#    IdentityFile ~/.ssh/id_<USER>
```

---

### Parameter Tables
These CSV files configure each run.
Templates are provided in the test batch.

File | Purpose
---- | -------
constants.csv | Global analysis parameters (e.g. puncta size)
dark_frames.csv | Camera noise reference images
directories.csv | Absolute paths to input / output folders
exclusion_channels.csv | Channels to ignore
images.csv | Metadata for each image

---

### Output Files

Main outputs in Output/:
- `essentials.csv.gz`: Key results for each detected cluster
- `parameters.csv.gz`: Metadata and analysis parameters

---

### Optional Customization
You can improve terminal readability with:

- [iTerm2](https://iterm2.com/) on macOS
- [Oh My Posh](https://ohmyposh.dev/) for prompt theming

### Output Documentation

The pipeline processes your images by converting the nd2 files to a more readable TIFF format, extracts the image metadata, subtracts background, segments the cells, creates tracking and intensity images, tracks puncta, and normalizes your data.  Information from this part is stored in XML files for each cell.
The R scripts are used to extract the XMLs and to colocalize the different channels you imaged. In the end, this generates two main compressed CSV files: `essentials.csv.gz` and `parameters.csv.gz`. Below is the documentation of their content.

Load the `Essentials.csv.gz` in R for your downstream analysis.

#### Essentials.csv.gz

**Identification**

- `RELATIVE_PATH`: Relative path to cell folder.
- `COHORT`: Cell line name plus any perturbations.
- `IMAGE`: Name of image in the format: Date + Ligand concentration + Cell line + Plate/well.
- `PROTEIN`: Protein name.
- `UNIVERSAL_TRACK_ID`: Unique identifier for each cluster.
- `UNIVERSAL_SPOT_ID`: Unique identifier for each spot.
- `ANALYSIS_TIME_STAMP`: Date and time of analysis completion.

**Temporal measurements**

- `TIME`: Seconds from acquisition start.
- `FRAME`: Frame number.
- `TIME_SINCE_LANDING` & `FRAMES_SINCE_LANDING`: Relative time from first detected spot.
- `TIME_ADJUSTED` & `FRAMES_ADJUSTED`: Cluster time (normalized).
- `LIFETIME`: Cluster lifetime in seconds.

**Spatial measurements**

- `ABSOLUTE_POSITION_X/Y`: Cluster centroid in microns.
- `CELL_AREA`: Cell area in microns.
- `NEAREST_SPOT`: Distance to nearest cluster (px).
- `SPOTS_WITHIN_RADIUS`: Number of spots within puncta radius.

**Amount of substance data**

- `NORMALIZED_INTENSITY`: Molecule count estimate for reference protein.
- `STARTING_NORMALIZED_INTENSITY`: Starting amount.
- `MAX_NORMALIZED_INTENSITY`: Max amount.
- `START_TO_MAX_INTENSITY`: Growth between start and max.
- `COMPLEMENTARY_*`: Corresponding fields for additional channels.

#### Parameters.csv.gz

**Other information**

- `RELATIVE_PATH`: Identifies cell + protein.
- `LIGAND`: Ligand used.
- `SEGMENT_WITH`: Channel used for segmentation.

**Fluorophore data**

- `CALIBRATION_IMAGE`: Image used for normalization.
- `CALIBRATION_TOTAL_INTENSITY`: Median brightness (a.u.).
- `CALIBRATION_STANDARD_DEVIATION`: Variance of brightness (a.u.).

**Microscope information**

- `CHANNEL`: Microscope channel.
- `POWER`: Laser power.
- `EXCITATION` & `EMISSION`: Wavelengths.
- `ANGLE` & `DIRECTION`: TIRF angles.
- `FOCUS`: Z-axis objective position.
- `OBJECTIVE`: Magnification.
- `TIME_START`: Acquisition timestamp.
- `FRAME_RATE`: Frames per second.

**Spatial information**

- `WIDTH` & `HEIGHT`: Image size (µm).
- `CALIBRATION_UM`: Pixel size (µm).
- `CELL_DIAMETER` & `PUNCTA_DIAMETER`: Estimates used for median filtering.
- `SPOT_RADIUS_LIMIT`: Spot radius.
- `CELL_POSITION_X/Y`: Cell coordinates.

**TrackMate information**

- `TRACKMATE_THRESHOLD`: Detection threshold.
- `TRACKMATE_FRAME_GAP`: Max allowed missed frames.
- `TRACKMATE_GAP_LINK_DISTANCE`: Max gap distance (px).
- `TRACKMATE_MAX_LINK_DISTANCE`: Max link distance before new track.