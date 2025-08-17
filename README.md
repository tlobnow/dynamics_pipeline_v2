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
    module load jdk/8.265 gcc/10 impi/2021.2 fftw-mpi R/4.0.2

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

    wget https://downloads.imagej.net/fiji/latest/fiji-linux64.zip
    unzip fiji-linux64.zip
    
### Conda installation

Download the latest conda version

    wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
    chmod +x Miniconda3-latest-Linux-x86_64.sh
    ./Miniconda3-latest-Linux-x86_64.sh
    export PATH=~/miniconda/bin:$PATH
    source ~/miniconda3/bin/activate
    export PATH="/miniconda3/bin":$PATH

    # Follow Terminal instructions to install conda
    
    # Create conda environment
    conda create -n dynamics_pipeline python=3.8 anaconda

Then paste,

    # Create conda environment
    conda activate dynamics_pipeline
    
    # Install conda packages
    conda install -c conda-forge setuptools
    conda install -c conda-forge javabridge
    conda install -c conda-forge libxml2
    pip install glib


### Obtain the python environment

We have a static environment that you can access in two ways:
1. Download the environment file from data-tay `/Volumes/TAYLOR-LAB/Finn_v2/env_dynamics_pipeline.tar.gz` and transfer it to the cluster (you could use Filezilla, scp or rsync).
2. I can give you access to the file, so you can copy it directly on the cluster.

Store and unzip the file in your `~/miniconda/envs`

    tar -xvzf FOLDER.tar.gz

You should be able to activate the static environment with:

    conda activate dynamics_pipeline

Add missing pip packages

    pip install numpy tifffile pims>=0.3.0 pims_nd2 nd2reader opencv-python matplotlib

### Git installation

Paste the following and rename the last element to yours:

    git config --global user.name "<USERNAME>"
    git config --global user.email <email>@mpcdf.mpg.de
    ssh-keygen -t rsa -b 4096 -C "<USERNAME>@raven.mpcdf.mpg.de"
    
Press [Enter] to skip some steps and get the ssh key. Then, copy the entire block of string from start to finish, including the _ssh-rsa_ and the ending name . Use `cat /u/$USER/.ssh/id_rsa.pub` and change **user_path** accordingly

Sign-in to GitHub, https://github.com/login

Paste the key into GitHub, https://github.com/settings/keys

* New SSH key
* Type in the cluster name as **Title** and paste the key under **Key**

### Clone the dynamics_pipeline repo

    git clone https://github.com/tlobnow/dynamics_pipeline_v2.git

If you are not successful (couldn't set up Github connection etc.) you can upload the zipped repository from data-tay `/Volumes/TAYLOR-LAB/Finn_v2/dynamics_pipeline_v2.zip`
Unzip it using `unzip dynamics_pipeline_v2.zip`

---

# Image Analysis Pipeline
## Input
The input data goes into ~/new_pipeline/pending_processing/batch_date/Input/parameter_tables. There are five files, including:
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
