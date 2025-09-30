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
### 🔑 Log in to the Cluster

From your local machine:

```bash
ssh <USERNAME>@raven.mpcdf.mpg.de
```
> ⚠️  Set up this [SSH config](#-ssh-setup) so you can just type `ssh raven` to upload/download files from/to the cluster and stay logged in a long time.

### 📥 Transfer Pipeline & Test Data

Open a new terminal window on your **LOCAL machine** (NOT the cluster) and have access to the **DATA-TAY** as per IT instructions.

```bash
rsync -a /Volumes/TAYLOR-LAB/Finn_v2/PIPELINE_RESOURCES/ raven:/u/<USERNAME>/
```

On the cluster, confirm that the files arrived:

```bash
ls
# should now list dynamics_pipeline_v2.zip, fiji-linux64.zip, dark_frames.tar.gz, BATCH.tar.gz, and Miniconda3-latest-Linux-x86_64.sh
```

---

## 2. Environment Setup
### Unpack resources

```bash
cd
# unpack pipeline & resources
unzip dynamics_pipeline_v2.zip
unzip fiji-linux64.zip
tar -xvzf dark_frames.tar.gz
tar -xvzf TEST_BATCH.tar.gz
```

### Conda & R setup

Install Miniconda (if not already installed):

```bash
bash Miniconda3-latest-Linux-x86_64.sh
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

### Install UV (Python package manager)

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
### Create folder structure

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

## Start the pipeline

```bash
cd ~/dynamics_pipeline_v2
sbatch submit_node.sh # adjust submit_node.sh to match your batch names for future runs
```

### Monitor job status

```bash
# check your job status with
squeue -u $USER

# monitor your queue with
./check_squeue.sh

# monitor live output with
./tail_current_jobs.sh
```

### Check output
After the job completes, check the output files in:

```bash
ls ~/pipeline/pending_processing/BATCH/Output/
# should contain essentials.csv.gz and parameters.csv.gz

# the slurm logs are in the `slurm_reports` folder and contain error and output logs, e.g. job.err.123456 and job.out.123456
ls ~/dynamics_pipeline_v2/slurm_reports/

```

You can now download these files to your local machine for further analysis or install and configure Studio Visual Code to connect to the cluster and work directly there.
Use `rsync` or `scp` to download the output files to your local machine:

> ⚠️  Run this command from your **LOCAL machine**, NOT the cluster!

```bash
rsync -a raven:/u/<USERNAME>/pipeline/pending_processing/BATCH/Output/ ~/local_folder/
```

---

# SSH Setup

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

# Parameter Tables
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

# 📤 Output Files

Main outputs in Output/:
- `essentials.csv.gz`: Key results for each detected cluster
- `parameters.csv.gz`: Metadata and analysis parameters

---

# Optional Customization
You can improve terminal readability with:

- [iTerm2](https://iterm2.com/) on macOS
- [Oh My Posh](https://ohmyposh.dev/) for prompt theming











# Installation

Follow this guide, step by step

## Requirements

- Linux cluster (Raven)
- R 4.3

## **1. Connect to the Cluster**

Paste the following in the terminal (**change `<USERNAME>` to your user name**):

```bash
ssh <USERNAME>@raven.mpcdf.mpg.de
```

On the cluster computer, your `<USERNAME>` will be available as `$USER`

---

## **2. Set Up SSH Tunnel and File Transfer**

### Configure SSH

Create `~/.ssh/config`  by typing `nano ~/.ssh/config` . Paste the following snippet into your `~/.ssh/config` file. This creates the infrastructure necessary for extended logins and file transfers. Change the `<USERNAME>` to match your user name on the cluster.

```bash
Host *
    ControlMaster auto
    ControlPath ~/.ssh/control-%h-%p-%r
    ControlPersist yes
    LogLevel ERROR
    Port 22
    StrictHostKeyChecking ask
    UserKnownHostsFile ~/.ssh/known_hosts

Host gate1 gate2 raven viper
    User <USERNAME>
    HostName %h.mpcdf.mpg.de
    GSSAPIAuthentication yes
    GSSAPIDelegateCredentials yes

Host raven viper
    ProxyJump gate1

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

⚠️ After adding this on the cluster, it’s important to create the same file locally (new terminal window, not connected to the cluster) and paste the same info, otherwise the tunnel won’t work.

### Use the tunnel

Try to connect to the cluster again, this time with:

```bash
ssh raven
```

After adding this information to your `~/.ssh/config` files, you can now log in to raven using only `ssh raven`, type in your password and OTP once and stay logged in for 8 hours.

### **File Transfer**

You can transfer files to/from the cluster using `rsync` or `scp`. This only works from your local machine, not directly from the cluster!

`rsync` checks timestamps and sizes to avoid re-transferring files. For instance, from your local machine, you can transfer a folder to and from a remote. The slash (/) at the end of the directory name instructs rsync to synchronize the entire directories:

```bash
## rsync principle (actual use case in the next code chunk below)
rsync −a /path/to/dir/ <REMOTE>:dir/
rsync −a <REMOTE>:dir/ /path/to/dir/
```

---

## **3. Clone the Repository**

We want to use `rsync` to transfer three important zipped (tarball ~ zip file) files onto the cluster. They are stored on `data-tay` (your first email from IT contains all the info on how to connect).

```bash
rsync -a /Volumes/TAYLOR-LAB/Finn_v2/PIPELINE_RESOURCES/ raven:/u/<USER>/
```

On the cluster, you should see the files we uploaded when typing `ls`.

---

## 4. Prepare Pipeline Environment

### 4.1 Unpack resources

```bash
# extract zip files
unzip dynamics_pipeline_v2.zip
unzip fiji-linux64.zip

# extract tarballs
tar -xvzf dark_frames.tar.gz
tar -xvzf TEST_BATCH.tar.gz
```

### 4.2 Install Conda

```bash
cd
bash Miniconda3-latest-Linux-x86_64.sh
# follow the instructions, type 'yes' when prompted
export PATH=~/miniconda/bin:$PATH
export PATH=~/miniconda3/bin:$PATH
source ~/miniconda3/bin/activate
```

### 4.3 Create Conda environment

```bash
# install general and R packages that need R 4.3
conda create -n rdpipe -c conda-forge r-base=4.3 r-xml r-data.table r-dplyr pkg-config libtiff zlib libjpeg-turbo javabridge python=3.8

conda activate rdpipe

R # should load R version 4.3.3 (2024-02-29) -- "Angel Food Cake"

install.packages("pacman") # type [1] to select a mirror (any number should work)

pacman::p_load(XML, dplyr, data.table, parallel, tidyr, ff, changepoint, compiler, stringr, dtplyr, RANN, R.utils, ijtiff) # will take a while
```

---

## 5. Install UV

Install this python package manager (much faster and more reliable than pip):

```bash
cd
curl -LsSf <https://astral.sh/uv/install.sh> | sh
## or alternatively
# wget -qO- <https://astral.sh/uv/install.sh> | sh

```

Prepare the environment:

```bash
cd ~/dynamics_pipeline_v2/dypi_env
uv sync
# and add the environment bin to your path and to your bashrc
echo 'export PATH="/u/$USER/dynamics_pipeline_v2/dypi_env/.venv/bin/:$PATH"' >> ~/.bashrc
```

---

## [Optional] Customization

ℹ️ You can skip this section entirely if you prefer the default terminal appearance.

### iTerm2 App (local)

These steps are purely cosmetic and help make the terminal more readable and pleasant. They are **not required** for the pipeline. This remark is from the developers:

> iTerm2 brings the terminal into the modern age with features you never knew you always wanted... If you spend a lot of time in a terminal, then you’ll appreciate all the little things that add up to a lot.
> 

Download the latest release from [https://iterm2.com/downloads.html](https://iterm2.com/downloads.html).

### Oh My Posh (cross-platform)

You can stylize your terminal prompt with “Oh My Posh”. This is a prompt theme engine for any shell. Many different customizations are possible. To download the latest release:

```bash
curl -s <https://ohmyposh.dev/install.sh> | bash -s
```

Add the following font (*Meslo*) to support additional symbols. After installing it, open your terminal settings and select **"MesloLGM Nerd Font"** to ensure proper display compatibility. Type the following line to install it:

```bash
oh−my−posh font install meslo
```

Available themes: [https://ohmyposh.dev/docs/themes](https://ohmyposh.dev/docs/themes)

Built-in themes are located in: `/raven/u/$USER/.cache/oh-my-posh/themes`

To load a theme automatically on login, add this to your `~/.bashrc`:

```bash
# OH-MY-POSH
#THEME=agnoster
#THEME=bubbles
#THEME=probua.minimal
#THEME=dracula
THEME=powerlevel10k_classic
#THEME=emodipt
eval "$(oh-my-posh init bash --config /u/$USER/.cache/oh-my-posh/themes/${THEME}.omp.json)"
```

---

# 7. Input Preparation and Execution Guide

## Create Folder Structure

First, set up the pipeline directory with subfolders for your imaging data:

```bash
mkdir -p ~/pipeline/{raw,pending_processing,finished}

```

Then, move the provided test data (TEST_BATCH) and dark frames into place:

```bash
mv ~/TEST_BATCH ~/pipeline/pending_processing/
mv ~/darkframes ~/pipeline/
```

## Adjust submit_node.sh to match path to parameters_table

```bash
cd ~/dynamics_pipeline_v2
nano submit_node.sh
```

Change this path to match your `<USER>` name

`path=$'/raven/u/<USER>/pipeline/pending_processing/TEST_BATCH/Input/parameter_tables’`

## Start the Pipeline

In the command line, type `sbatch submit_node.sh` to start your job on the cluster.

## Input: The parameter_tables

Place your input files in the parameter_tables folder inside your Input directory. For the test batch, these are already prepared, but you need to adjust fields like your username. The folder should contain the following files:

- constants.csv – fixed analysis parameters
- dark_frames.csv – camera noise reference images
- directories.csv – paths for input, output, and processing
- exclusion_channels.csv – channels to ignore
- images.csv – metadata for each image

### directories.csv (leave as is for TEST_BATCH, but check and adjust for your own analysis!)

Adjust the paths to match the analysis batch names and replace <USER> with your own user name. Relative paths don't work here (like ~).

| contains | path |
| --- | --- |
| input | /u/<USER>/pipeline/pending_processing/TEST_BATCH/Input |
| processing | /u/<USER>/pipeline/pending_processing/TEST_BATCH/Processing |
| output | /u/<USER>/pipeline/pending_processing/TEST_BATCH/Output |
| dark_frames | /u/<USER>/pipeline/dark_frames |
| ImageJ | /u/<USER>/Fiji.app/ImageJ-linux64 |

### dark_frames.csv (leave as is for TEST_BATCH, but check for your own analysis!)

The dark frame is the camera noise ([https://en.wikipedia.org/wiki/Dark-frame_subtraction](https://en.wikipedia.org/wiki/Dark-frame_subtraction)). This typically is 1000 frames averaged, though 50 frames could do, so long as the standard deviation does not change with more images added. It should be at the same exposure as the images using >

The table contains the image names of the dark frame average and their exposures **with units**. You might need other darkframes, depending on your imaging settings. You can easily create your own or obtain darkframe images from other users.

| image | exposure |
| --- | --- |
| 20220530 Darkfield 60 ms binned 001.tif | 60 ms |
| 20220530 Darkfield 100 ms binned 002.tif | 100 ms |
| 20220530 Darkfield 200 ms binned 005.tif | 200 ms |
| 20220530 Darkfield 300 ms binned 003.tif | 300 ms |
| 20220530 Darkfield 400 ms binned 004.tif | 300 ms |

### constants.csv

Numbers which will be constant throughout the analysis

| parameter | value | comments |
| --- | --- | --- |
| tiff_compression_level | 5 | out of 10 |
| cell_diameter | 25 | px, odd number |
| puncta_diameter | 5 | px, odd number |

### exclusion_channels.csv (leave as is)

Channels to exclude from the pipeline analysis.

value

---

IL-1

---

Brightfield

---

WideField

---

### example images.csv

| image | cohort | segment_with | ligand | ligand_density | trackmate_max_link_distance | trackmate_threshold | trackmate_frame_gap | T Cy5 protein_name | T GFP protein_name | T RFP protein_name | WideField protein_name |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 20211218 0p8nM 069-1R_TRAF6_MyD88   Grid_1um_11mol 001.nd2 | MyD88 TRAF6 1um_grid | MyD88 | 0.8 nM IL-1 | 11 | 5 | 1.5 | 5 | IL-1 | MyD88 | TRAF6 | Brightfield |
| 20211218 GFP calibration_10pct_60ms   005.nd2 | Calibrations | GFP |  |  | 2.5 | 1.5 | 5 | IL-1 | GFP | mScarlet | Brightfield |
| 20211218 mScarlet calibration_10pct_60ms   001.nd2 | Calibrations | mScarlet |  |  | 2.5 | 1.5 | 5 | IL-1 | GFP | mScarlet | Brightfield |

## Start the pipeline using SLURM

You need to be connected to the cluster computer (Raven etc.).
Modify the parameters of `submit_node.sh` accordingly.
Paste `sbatch submit_node.sh` to submit your job on the cluster.

## Output Documentation

The pipeline processes your images by converting the nd2 files to a more readable TIFF format, extracts the image metadata, subtracts background, segments the cells, creates tracking and intensity images, tracks puncta, and normalizes your data.  Information from this part is stored in XML files for each cell.
The R scripts are used to extract the XMLs and to colocalize the different channels you imaged. In the end, this generates two main compressed CSV files: `essentials.csv.gz` and `parameters.csv.gz`. Below is the documentation of their content.

Load the `Essentials.csv.gz` in R for your downstream analysis.

### Essentials.csv.gz

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

### Parameters.csv.gz

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