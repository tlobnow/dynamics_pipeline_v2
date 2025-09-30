#!/usr/bin/env Rscript
args = commandArgs(trailingOnly=TRUE)
parameters_path = args[1]
unlink(".RData")

##############
# Run Script #
##############

# Libraries----
if (!requireNamespace("pacman", quietly = TRUE)) {stop("Package 'pacman' is not installed. Please install it before running.")}
pacman::p_load(dplyr, stringr, parallel, tidyr, data.table, ff, dtplyr, compiler)

# Parallel + JIT setup
ncores <- parallel::detectCores(logical = FALSE)                                # Set the number of threads to use
setDTthreads(ncores)
enableJIT(3) # aggressive JIT                                                   # Enable Just-In-Time compilation. This means that the code will be compiled before execution, which can speed up the code. The number 3 is the level of optimization.

source("/u/<USERNAME>/dynamics_pipeline_v2/r_scripts/compile_tables_fx.R")

# Get directories
intensity_ending              = "_intensity.csv.gz"
colocalization_intensity_file = "colocalization.csv.gz"
directories_list              = file.path(parameters_path, "directories.csv")
directories_list              = fread(directories_list)

input_path          = directories_list$path[directories_list$contains == "input"]
processing_path     = directories_list$path[directories_list$contains == "processing"]
colocalization_path = file.path(processing_path, "06_Colocalization")
output_path         = directories_list$path[directories_list$contains == "output"]
summary_path        = file.path(dirname(parameters_path), "summary.csv") ; print(summary_path)
# summary_path      = "/Users/u_lobnow/Desktop/20230623_batch/Processing/06_Colocalization/BDLD_67H-MyD88-TIR-TRAF6-BD-GFP TRAF6/20230623 3nM_cl327-BDLD67H_TRAF6_MyD88 002/summmary.csv"

# Get image list
file_list = fread(summary_path)

# Prep up
file_list <- file_list %>% 
  mutate(image = dirname(dirname(protein_relative_path)),
         exposure_units = word(exposure, -1),
         exposure_measurement = as.numeric(word(exposure, 1)),
         direction = direction*pi/180,
         angle = angle*pi/180) %>% 
  mutate(exposure = exposure_measurement*ConvertUnits(exposure_units),
         image = basename(image),
         date = substr(image, 0, 8)) %>% 
  mutate(date =  as.Date(date, format = '%Y%m%d')) %>% 
  select(-c(exposure_units, exposure_measurement)) %>% 
  as.data.table()

# Separate calibrations and the rest
tryCatch({
  calibration_list = file_list[file_list$cohort=="Calibrations",]               ; calibration_list
  Path <- calibration_list$protein_relative_path                                ; Path
  Path <- dirname(Path)                                                         ; Path
  Path <- file.path(colocalization_path, Path)                                  ; Path
  Path <- file.exists(Path)
  calibration_list <- calibration_list[Path]
  # Analyze calibrations
  calibration_list <- lapply(1:NROW(calibration_list), QuantifyCalibration)
  calibration_list <- rbindlist(calibration_list)
})


image_list <- file_list[file_list$cohort!="Calibrations",]
Path       <- image_list$protein_relative_path
Path       <- dirname(Path)
Path       <- file.path(colocalization_path, Path)
Path       <- file.exists(Path)
image_list <- image_list[Path]

# Pairing
PairedList <- mclapply(1:NROW(image_list), GetCalibrationImages, mc.cores = detectCores(logical = F))
PairedList <- rbindlist(PairedList, fill = TRUE, use.names = TRUE)
PairedList <- PairedList %>% distinct() %>% as.data.table()

ANALYSIS_TIME_STAMP = Sys.time()
ANALYSIS_TIME_STAMP = as.POSIXlt(ANALYSIS_TIME_STAMP, tz = "UTC")
ANALYSIS_TIME_STAMP = as.character(ANALYSIS_TIME_STAMP)

Cells <- unique(PairedList$CELL_PATH)

CellAnalysis <- mclapply(1:NROW(Cells), CombineCellTables, mc.cores = detectCores(logical = F))
CellAnalysis <- unlist(CellAnalysis)
CellAnalysis <- CellAnalysis[file.exists(CellAnalysis)]

# Combine all cell tables
Images <- dirname(CellAnalysis)
Images <- unique(Images)

# Tables to merge
Outputs <- c("Parameters.csv.gz", "Analysis.csv.gz", "Essential.csv.gz")

nImages <- NROW(Images)                                                         ; nImages

ProcessedImages <- lapply(1:nImages, CombineImageTables)
ProcessedImages <- unlist(ProcessedImages)

lapply(Outputs, GrandTable)

# Add calibration images to move
CalibrationImages <- file.path(colocalization_path, dirname(dirname(calibration_list$protein_relative_path)))
AllProcessedImages <- c(ProcessedImages, CalibrationImages)

# Move processed images
for(Image in AllProcessedImages){
  old_path = Image
  Cohort   = basename(dirname(Image))
  dir.create(file.path(output_path, Cohort), showWarnings = F)
  Image    = basename(Image)
  new_path = file.path(output_path, Cohort, Image)
  file.move(old_path, new_path)
}

# Delete cohort if empty
OldCohorts = unique(dirname(AllProcessedImages))
for(Cohort in OldCohorts){if(NROW(list.files(Cohort)) == 0){unlink(Cohort, recursive = TRUE)}}

# Delete processing folder if empty
ProcessingFolder = dirname(OldCohorts[1])
if(NROW(list.files(ProcessingFolder)) == 0){unlink(ProcessingFolder, recursive = TRUE)}

print('combine_tables.R is now complete')

Sys.sleep(3)
