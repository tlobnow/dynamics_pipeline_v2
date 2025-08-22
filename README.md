# Installation

Follow this guide, step by step

## Requirements
* Linux cluster (Raven)
* R 4.0.2

## Process

Paste the following in the terminal (**change `<USERNAME>` with your user name**):

Connect to the cluster computer:
    
    ssh <USERNAME>@raven.mpcdf.mpg.de

On the cluster computer, your <USERNAME> will be available as `$USER`

### R packages installation

Load interpreters

    cd ~
    module purge
    module load jdk/8.265 gcc/10 impi/2021.2 fftw-mpi R/4.2

Install libtiff 

    mkdir libtiff
    cd libtiff
    wget https://download.osgeo.org/libtiff/tiff-4.3.0.tar.gz
    tar -xvf tiff-4.3.0.tar.gz
    mkdir install
    cd tiff-4.3.0
    mkdir compile
    cd compile    
    ../configure --prefix=/u/$USER/libtiff/install
    make
    make install
    export PKG_CONFIG_PATH=/u/$USER/libtiff/install/lib/pkgconfig/
    
Change directory to home. Type `~` and press [Enter]

Load R. Enter `R` on the terminal and press [Enter]

Paste the following in the R console inside the terminal:

    if("pacman" %in% rownames(installed.packages()) == FALSE)
    {install.packages("pacman")}

When prompted, type `yes` to install and `yes` to create a personal library. After, another prompt will appear. Select which repository you would like to use. Enter `1` (cloud) and then press [Enter]

Then, paste the following:

    pacman::p_load(ijtiff)

After, paste the following:

    pacman::p_load(XML)

Lastly, paste the following:

    pacman::p_load(dplyr, stringr, parallel, tidyr, data.table, ff, dtplyr, compiler, changepoint, R.utils, lemon, ggquiver, ggplot2, ggdark, scales, ggforce, viridis, RcppRoll)

Exit R by typing `q()` and then `n` to not save

### ImageJ installation

Download the latest imagej version for analysis

    cd
    wget https://downloads.imagej.net/fiji/latest/fiji-latest-linux64-jdk.zip
    unzip fiji-*.zip
    
### Clone the dynamics_pipeline_v2 repo from Github

    cd
    git clone https://github.com/tlobnow/dynamics_pipeline_v2.git

If you are not successful (couldn't set up Github connection etc.) you can upload the zipped repository from data-tay `/Volumes/TAYLOR-LAB/Finn_v2/dynamics_pipeline_v2.zip` and Unzip it using `unzip dynamics_pipeline_v2.zip`

### Conda installation

Download the latest conda version

    cd 
    mv ~/dynamics_pipeline_v2/Miniconda3-latest-Linux-x86_64.sh ~

    chmod +x Miniconda3-latest-Linux-x86_64.sh
    ./Miniconda3-latest-Linux-x86_64.sh
    export PATH=~/miniconda/bin:$PATH
    source ~/miniconda3/bin/activate
    export PATH="/miniconda3/bin":$PATH

    # Follow Terminal instructions to install conda


### How to transfer files to and from the cluster

I prepared a couple of helpful, but large files for learning how to handle the pipeline. They are currently stored on our server `data-tay` and you can access this from your local computer while connected to the MPG network (by LAN or VPN). You got information on how to connect in your first email from IT.

#### Setting up a tunnel for file transfer and persistent log in

You can create or modify an existing SSH configuration file to give remotes nicknames, change log-in options, persist your log-in, etc. For MPCDF clusters, users must “jump” through a gateway remote, gate*.mpcdf.mpg.de; this can be configured directly in the SSH configuration file.
Add the following snippet to your `~/.ssh/config` files locally and on the cluster as well. This creates the infrastucture necessary for tunnels and transfers.

    ## This is a ssh config file to connect to the MPCDF cluster and establish a connection
    ## which persists for 8h without the need of re-entering the OTP every time (i.e. for data
    ## transfer or connection to MPCDF).

    #########
    ## Usage:
    ## Copy this file to `~/.ssh/config` and exchange the `User` names with your login user name
    ## After that you can connect to cobra or raven by typing `ssh cobra` and `ssh raven` respectively.

    Host gatezero
       Hostname gate1.mpcdf.mpg.de
       User flobnow
       Compression yes
       ServerAliveInterval 120
       ControlMaster auto
       ControlPersist 8h
       ControlPath ~/.ssh/master-%C
       GSSAPIAuthentication no

    Host raven
       Hostname raven.mpcdf.mpg.de
       User flobnow
       Compression yes
       ControlMaster auto
       ControlPersist 8h
       ControlPath ~/.ssh/master-%C
       GSSAPIAuthentication no
       ProxyJump gatezero

#### Using the tunnel

After adding this information to your `~/.ssh/config` files, you can now log in to raven using only `ssh raven`, type in your password and OTP once and stay logged in for 8 hours.

#### Sending files via SCP (Secure Copy)

The easiest tool for transferring files between your local machine and remotes is SCP. It works like cp, except it works over the network to copy files using the SSH protocol. After configuring SSH connections per Modifying the SSH configuration file, from your local machine, you can copy a file to and from a remote using:

    scp <SOURCE PATH> <REMOTE>:<SOURCE PATH>
    scp <REMOTE>:<SOURCE PATH> <SOURCE PATH>

#### Sending files or folders via rsync

Use rsync if you have complex hierarchies of files and directories to transfer (or synchronize). rsync checks timestamps and sizes to avoid re-transferring files, thus improving performance. For instance, from your local machine, you can transfer the entire dir/ folder tree to and from a remote using:

    rsync −a /path/to/dir/ <REMOTE>:dir/
    rsync −a <REMOTE>:dir/ /path/to/dir/

The slash (/) at the end of the directory name instructs rsync to synchronize the entire directories.

 ### Conda installation

Since the download link doesn't work on the cluster, download the conda installation file locally (we need the file for Linux-x86_64) by running:
If you don't have wget installed, you can use `curl -O https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh` instead.
    cd
    wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh

Transfer this script onto the cluster and into your main directory (replace <USER> with your own user name) via SCP or rsync, e.g.

    rsync -a ~/Miniconda3-latest-Linux-x86_64.sh raven:/u/<USER>/

Now the file should be available on the cluster and you can follow the remaining installation as follows:

    cd 
    chmod +x Miniconda3-latest-Linux-x86_64.sh
    ./Miniconda3-latest-Linux-x86_64.sh
    export PATH=~/miniconda/bin:$PATH
    source ~/miniconda3/bin/activate
    export PATH="/miniconda3/bin":$PATH

    # Follow Terminal instructions to install conda

### Obtain the python environment

I prepared a static environment that is stored on data-tay in `/Volumes/TAYLOR-LAB/Finn_v2/env_dynamics_pipeline.tar.gz`
Transfer this file to the cluster in a similar manner and store it in your `~/miniconda/envs` (perhaps your miniconda folder is called `miniconda3`, so you can either adjust the code below or the folder name)

    rsync -a /Volumes/TAYLOR-LAB/Finn_v2/env_dynamics_pipeline.tar.gz raven:/u/<USER>/miniconda/envs

On the cluster:

    cd ~/miniconda/envs
    tar -xvzf env_dynamics_pipeline.tar.gz

You should be able to activate this  environment with:

    conda activate dynamics_pipeline

Add missing pip packages

    pip install numpy tifffile pims>=0.3.0 pims_nd2 nd2reader opencv-python matplotlib

---

# Image Analysis Pipeline

## Create Folder Structure
We will create a folder that contains our imaging data. In subfolders, you can organize all your raw files (`.nd2`) by batch_date, just the creation date, by cell lines, or whatever is logical for you.

    mkdir -p ~/pipeline/{raw,pending_processing/TEST_BATCH/{Input/parameter_tables,Processing,Output},finished}

The following documentation will explain how you prepare your input for processing and I recommend to run my example set called `TEST_BATCH` that is stored on data-tay (`/Volumes/TAYLOR-LAB/Finn_v2/dynamics_pipeline_v2.zip`). Transfer it to `~/pipeline/pending_processing`.

In the same folder on data-tay, I have supplied a tarball (`dark_frames.tar.zip`) that contains files we need for analysis. Transfer this file to the cluster and move the unpacked folder to `~/pipeline`.

## Input: The parameter_tables

I will use TEST_BATCH for the walk through.

Your input data goes into `~/pipeline/pending_processing/TEST_BATCH/Input/parameter_tables`. You need to prepare the following five files:
* constants.csv
* dark_frames.csv
* directories.csv
* exclusion_channels.csv
* images.csv

### constants.csv
Numbers which will be constant throughout the analysis
| parameter          | value | comments       |
|------------------------|-------|----------------|
| tiff_compression_level | 5     | out of 10      |
| cell_diameter      | 25    | px, odd number |
| puncta_diameter    | 5     | px, odd number |

### dark_frames.csv
 The dark frame is the camera noise (https://en.wikipedia.org/wiki/Dark-frame_subtraction). This typically is 1000 frames averaged, though 50 frames could do, so long as the standard deviation does not change with more images added. It should be at the same exposure as the images using the same camera as the microscopy images. Thus, one image could be used for multiple channels.
 
 The table contains the image names of the dark frame average and their exposures **with units**.

| image                   | exposure |
|-------------------------------------|----------|
| 20201026 Darkfield 200ms binned.tif | 200 ms   |
| 20201026 Darkfield 50ms binned.tif  | 50 ms    |
| 20201026 Darkfield 100ms binned.tif | 100 ms   |

### directories.csv
| contains    | path              |
|-------------|---------------------------|
| input       | ~/Input           |
| processing  | ~/Processing          |
| output      | ~/Output          |
| dark_frames | ~/dark_frames         |
| flat_fields | ~/flat_fields         |
| ImageJ      | ~/Fiji.app/ImageJ-linux64 |

### exclusion_channels.csv
Channels to exclude from the pipeline analysis.

| value       |
|-------------|
| IL-1    |
| Brightfield |
| WideField   |

### images.csv
| image | cohort | segment_with | ligand | ligand_density | trackmate_max_link_distance | trackmate_threshold | trackmate_frame_gap | T Cy5 protein_name | T GFP protein_name | T RFP protein_name | WideField protein_name |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 20211218 0p8nM 069-1R_TRAF6_MyD88   Grid_1um_11mol 001.nd2 | MyD88 TRAF6 1um_grid | MyD88 | 0.8 nM IL-1 | 11 | 5 | 1.5 | 5 | IL-1 | MyD88 | TRAF6 | Brightfield |
| 20211218 GFP calibration_10pct_60ms   005.nd2 | Calibrations | GFP |  |  | 2.5 | 1.5 | 5 | IL-1 | GFP | mScarlet | Brightfield |
| 20211218 mScarlet calibration_10pct_60ms   001.nd2 | Calibrations | mScarlet |  |  | 2.5 | 1.5 | 5 | IL-1 | GFP | mScarlet | Brightfield |

## Start the pipeline using SLURM

You need to be connected to the cluster computer (Raven etc.)
Modify the parameters of `submit_node.sh` accordingly
Paste `sbatch submit_node.sh` to submit to SLURM

## Output
### Essentials.csv.gz
**Identification**
* RELATIVE_PATH: Relative path to cell folder. Simplifies address to source images and parameters
* COHORT: Cell line name (proteins tagged) plus any perturbations (for example, grids, inhibitors)
* IMAGE: Name of image. Our format is:
** Date (YYYYMMDD)
** Ligand concentration + density
** Cell line name
** Plate + well number 
* PROTEIN: Protein name
* UNIVERSAL_TRACK_ID: Unique cluster identifier, computed as:
** IMAGE + '...'
** CELL + '...'
** PROTEIN + '...' 
** TRACK_ID
* UNIVERSAL_SPOT_ID: Unique spot identifier, computed as:
** UNIVERSAL_TRACK_ID + '...'
** FRAME
* ANALYSIS_TIME_STAMP: Date and time of analysis completion

**Temporal measurements**
* TIME: Time in seconds from when image acquisition started
* FRAME: Image frame number
* TIME_SINCE_LANDING: Time in seconds since the first spot in the cell appeared
* FRAMES_SINCE_LANDING: Frames since the first spot in the cell appeared
* TIME ADJUSTED: Cluster time in seconds 
* FRAMES_ADJUSTED: Cluster time in frames
* LIFETIME: Cluster time in seconds. May need to be recalculated after passing fi

We recommend calculating the fluorophore bleaching rate. Filter data (FRAMES_SINCE_LANDING, FRAMES_ADJUSTED) based on the results of this parameter.

**Spatial measurements**
* ABSOLUTE_POSITION_X: X-coordinate of cluster centroid in microns
* ABSOLUTE_POSITION_Y: Y-coordinate of cluster centroid in microns
* CELL_AREA: Area of the cell in microns
* NEAREST_SPOT: Distance to nearest cluster in pixels
* SPOTS_WITHIN_RADIUS: Number of spots within puncta radius

**Amount of substance data**
* NORMALIZED_INTENSITY: Estimate number of molecules of the reference protein
* STARTING_NORMALIZED_INTENSITY: Starting amount of the reference protein
* MAX_NORMALIZED_INTENSITY: Max amount (brightness) of the relative protein 
* START_TO_MAX_INTENSITY: Growth, measured as max – start amount
* COMPLEMENTARY_PROTEIN_#: Protein in other channel(s)
* COMPLEMENTARY_TOTAL_INTENSITY_#: Brigness of other channel in arbitrary units
* COMPLEMENTARY_NORMALIZED_INTENSITY_#: Estimate number of molecules of the query protein
* COMPLEMENTARY_UNIVERSAL_SPOT_ID_#: UNIVERSAL_TRACK_ID of the query protein spot

### Parameters.csv.gz

**Other information**
* RELATIVE_PATH: Identifies cell + protein in question
* LIGAND: Ligand that stimulates 
* SEGMENT_WITH: Protein name of the channel that was used for segmenting the cells from the image

**Fluorophore data**
* CALIBRATION_IMAGE: Image used for fluorophore normalization
* CALIBRATION_TOTAL_INTENSITY: Median brightness of the fluorophore in arbitrary units
* CALIBRATION_STANDARD_DEVIATION: Variance of the brightness of the fluorophore in arbitrary units

**Microscope information**
* CHANNEL: Microscope channel
* POWER: Laser power
* EXCITATION: Peak wavelength of laser excitation
* EMMISION: Peak wavelength of emmision filter
* ANGLE: TIRF critical angle in degrees
* DIRECTION: Refraction direction in degrees (angle)
* FOCUS: Objective z-axis distance (not the stage z-axis)
* OBJECTIVE: Objective magnifying power
* TIME_START: Timestamp of when imaging acquisition started
* FRAME_RATE: Number of frames per second (Hz)

**Spatial information**
* WIDTH: Image width in microns
* HEIGHT: Image height in microns
* CALIBRATION_UM: Pixel size in microns
* CELL_DIAMETER: Estimate cell diameter, as entered in pipeline. Used in the cell median-filter step, whose resulting image is PROTEIN + '_intensity_ref.tif'
* PUNCTA_DIAMETER: Estimate puncta diameter, as entered in pipeline. Used in the puncta median-filter step, whose resulting image is PROTEIN + '_tracking_ref.tif'
* SPOT_RADIUS_LIMIT: Radius of spot
* CELL_POSITION_X: X-coordinate of the cell in the image
* CELL_POSITION_Y: Y-coordinate of the cell in the image

**TrackMate information**
* TRACKMATE_THRESHOLD: TrackMate's threshold
* TRACKMATE_FRAME_GAP: TrackMate's maximum frame gap between spots appearing at a location (missed detection)
* TRACKMATE_GAP_LINK_DISTANCE: TrackMate's maximum frame gap distance in pixels between spots appearing at a location (missed detection)
* TRACKMATE_MAX_LINK_DISTANCE: Maximum distance in pixels before the spot gets classified as a new distinct track (cluster)
