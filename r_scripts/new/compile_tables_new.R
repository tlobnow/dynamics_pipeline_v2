#!/usr/bin/env Rscript
# =============================================================================
# compile_tables.R
#
# Calibration matching, normalisation to molecules, nearest neighbours, border
# filtering, per-track values, and the three per-cell outputs
# (Parameters / Analysis / Essential.csv.gz).
#
# SELF-CONTAINED. compile_tables_fx.R is no longer sourced and can be deleted:
# it held two copies of every function (`X` and `X_new`) that differed only in
# logging, except for one real difference, and the live call sites used the
# older copy. Everything below is a single copy with the fixes applied.
#
# Markers: #!! NUMBERS / FIX / SPEED / KEPT / NOTE   (grep '#!!')
# =============================================================================

args = commandArgs(trailingOnly=TRUE)
parameters_path = args[1]
unlink(".RData")

##############
# Run Script #
##############

# Libraries----
if (!requireNamespace("pacman", quietly = TRUE)) {stop("Package 'pacman' is not installed. Please install it before running.")}
pacman::p_load(dplyr, stringr, parallel, tidyr, data.table, ff, dtplyr, compiler, RANN)

# Parallel + JIT setup
ncores <- parallel::detectCores(logical = FALSE)
setDTthreads(ncores)
enableJIT(3)

slurm_cpus <- suppressWarnings(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK")))
n_workers  <- if (!is.na(slurm_cpus) && slurm_cpus > 0) slurm_cpus else ncores
cat("workers:", n_workers, "(physical cores:", ncores, ")\n")

# Get directories
intensity_ending              = "_intensity.csv.gz"
colocalization_intensity_file = "colocalization.csv.gz"
directories_list              = file.path(parameters_path, "directories.csv")
directories_list              = fread(directories_list)

input_path          = directories_list$path[directories_list$contains == "input"]
processing_path     = directories_list$path[directories_list$contains == "processing"]
colocalization_path = file.path(processing_path, "06_Colocalization")
output_path         = directories_list$path[directories_list$contains == "output"]
#!! KEPT: summary.csv is per-run. Published version: file.path(input_path, "summary.csv").
summary_path        = file.path(dirname(parameters_path), "summary.csv") ; print(summary_path)

#!! KEPT: the batch-level Parameters/Analysis/Essential.csv.gz are just
#!! rbindlist() of the per-image files, which are written either way and end up
#!! in the output folder. MAKE_GRAND_TABLE=FALSE skips the peak-memory step and
#!! loses no information. Published version always built them.
make_grand_table = !identical(toupper(Sys.getenv("MAKE_GRAND_TABLE", "TRUE")), "FALSE")

# =============================================================================
# FUNCTIONS
# =============================================================================

# Convert exposure units
#!! SPEED: vectorised. The published version looped over the vector in R.
ConvertUnits <- function(x) {
  ifelse(x == "ms", 10^-3, 1)
}

QuantifyCalibration <- function(FileX){
  temp_calibration_list = calibration_list[FileX]
  Table <- file.path(colocalization_path, paste0(temp_calibration_list$protein_relative_path, intensity_ending))
  Table <- fread(Table)

  Table <- Table %>%
    summarize(
      SD  = mad(TOTAL_INTENSITY),
      SEM = mad(TOTAL_INTENSITY)/sqrt(n()),
      TOTAL_INTENSITY = median(TOTAL_INTENSITY),
      N = n()
    ) %>%
    as.data.table()

  temp_calibration_list <- bind_cols(temp_calibration_list, Table)

  save_path = paste0(temp_calibration_list$protein_name, "_calibration.csv.gz")
  save_path = file.path(colocalization_path, dirname(dirname(temp_calibration_list$protein_relative_path)), save_path)
  #!! KEPT: file.remove() has no showWarnings argument.
  suppressWarnings({file.remove(save_path)})
  data.table::fwrite(temp_calibration_list, save_path, row.names = F, na = "")

  return(temp_calibration_list)
}

# Pair each image with the calibration it should be normalised against
GetCalibrationImages <- function(ImageX){
  tryCatch({

    cat(paste("\nGetCalibrationImages - ImageX =", ImageX, "\n"))

    temp_image_list           <- image_list[ImageX]
    temp_image_list$cell_path <- dirname(temp_image_list$protein_relative_path)

    temp_calibration_list <- calibration_list %>%
      filter(channel == temp_image_list$channel) %>%
      as.data.table()

    if(NROW(temp_calibration_list) > 0){
      temp_calibration_list <- temp_calibration_list %>%
        mutate(power_test      = abs(power - temp_image_list$power)) %>%
        filter(power_test     == min(power_test)) %>%
        mutate(exposure_test   = abs(exposure - temp_image_list$exposure)) %>%
        filter(exposure_test  == min(exposure_test)) %>%
        mutate(direction_test  = abs(direction - temp_image_list$direction)) %>%
        filter(direction_test == min(direction_test)) %>%
        mutate(angle_test      = abs(angle - temp_image_list$angle)) %>%
        #!! NUMBERS: filter on angle_test, not direction_test. The published
        #!! version computed angle_test and then filtered on direction_test a
        #!! second time, so the angle never narrowed the choice. Where two
        #!! calibrations of the same channel differ only in angle, the one that
        #!! won was whichever came first -- and its median intensity is the
        #!! divisor for every NORMALIZED_INTENSITY of that image.
        filter(angle_test     == min(angle_test)) %>%
        mutate(date_test       = abs(as.numeric(difftime(date, temp_image_list$date, units = "secs")))) %>%
        #!! NOTE: abs() matters. A working copy of this function used a signed
        #!! difftime with min(), which picks the EARLIEST calibration rather
        #!! than the nearest in time. That copy was never called; this one
        #!! matches the published behaviour.
        filter(date_test      == min(date_test)) %>%
        filter(SEM            == min(SEM)) %>%
        as.data.table()

      CalibrationImage     = temp_calibration_list$image[1]
      CalibrationProtein   = temp_calibration_list$protein_name[1]
      CalibrationIntensity = temp_calibration_list$TOTAL_INTENSITY[1]
      CalibrationError     = temp_calibration_list$SD[1]
      cat(paste0("\tCalibrationImage: \t",     CalibrationImage, "\n"))
      cat(paste0("\tCalibrationProtein: \t",   CalibrationProtein, "\n"))
      cat(paste0("\tCalibrationIntensity: \t", CalibrationIntensity, "\n"))
      cat(paste0("\tCalibrationError: \t",     CalibrationError, "\n"))
    } else{
      CalibrationImage     = NA
      CalibrationProtein   = temp_image_list$channel
      CalibrationIntensity = 1
      CalibrationError     = NA
      #!! FIX: say so. Falling back to a divisor of 1 means that image's
      #!! "molecules" are raw camera counts, which is not comparable with
      #!! anything else in the batch and used to pass unremarked.
      message("GetCalibrationImages: no calibration for channel '",
              temp_image_list$channel, "' (", temp_image_list$protein_relative_path,
              "). NORMALIZED_INTENSITY for this image will be raw intensity.")
    }

    ExportTable        <- temp_image_list
    names(ExportTable) <- toupper(names(ExportTable))

    ExportTable$CALIBRATION_IMAGE              = CalibrationImage
    ExportTable$FLUOROPHORE                    = CalibrationProtein
    ExportTable$CALIBRATION_TOTAL_INTENSITY    = CalibrationIntensity
    ExportTable$CALIBRATION_STANDARD_DEVIATION = CalibrationError

    save_path = file.path(colocalization_path,
                          dirname(dirname(temp_image_list$protein_relative_path)),
                          paste0(CalibrationProtein, "_calibration.csv.gz"))
    suppressWarnings({file.remove(save_path)})
    data.table::fwrite(temp_calibration_list, save_path, row.names = F, na = "")

    return(ExportTable)
  }, error = function(e){
    #!! FIX: print the actual condition. "ERROR with MoveNoColocalizationNeededFx"
    #!! was both the wrong function name and no information.
    message("ERROR in GetCalibrationImages ImageX = ", ImageX, " ::: ", conditionMessage(e))
    return(NULL)
  })
}

NearestNeighborSearch <- function(ProteinFrameX, RADIUS){
  CoordiantesTable <- ProteinFrameX %>% select(POSITION_X, POSITION_Y)
  DistanceTable    <- RANN::nn2(CoordiantesTable, k = 2)
  DistanceTable    <- DistanceTable$nn.dists[,2]

  ClusterTable     <- RANN::nn2(CoordiantesTable, searchtype = c("radius"),
                                radius = RADIUS, k = NROW(ProteinFrameX))
  ClusterTable     <- ClusterTable$nn.dists
  ClusterTable     <- ClusterTable > 0 & ClusterTable < 1e+153
  ClusterTable     <- rowSums(ClusterTable)

  DistanceResults <- ProteinFrameX %>% select(UNIVERSAL_SPOT_ID)
  DistanceResults$NEAREST_SPOT        = DistanceTable
  DistanceResults$SPOTS_WITHIN_RADIUS = ClusterTable
  DistanceResults$SPOT_RADIUS_LIMIT   = RADIUS
  return(DistanceResults)
}

CombineCellTables <- function(CellX){
  tryCatch({

    print(paste("CombineCellTables - CellX =", CellX))

    CellPairedCalibrations <- PairedList %>%
      filter(CELL_PATH == Cells[CellX]) %>%
      mutate(PROTEIN = PROTEIN_NAME) %>%
      select(PROTEIN, CALIBRATION_IMAGE, CALIBRATION_TOTAL_INTENSITY, CALIBRATION_STANDARD_DEVIATION) %>%
      as.data.table()

    CellPath <- file.path(colocalization_path, Cells[CellX])

    IntensityTables <- paste0(CellPairedCalibrations$PROTEIN, intensity_ending)
    IntensityTables <- file.path(CellPath, IntensityTables)
    IntensityTables <- IntensityTables[file.exists(IntensityTables)]
    IntensityTables <- lapply(IntensityTables, fread)
    IntensityTables <- rbindlist(IntensityTables, fill = T, use.names = T)

    # Add calibration data
    IntensityTables <- merge(IntensityTables, CellPairedCalibrations, by = "PROTEIN", all = TRUE)

    # Normalize: one unit = one fluorophore
    IntensityTables$NORMALIZED_INTENSITY = IntensityTables$TOTAL_INTENSITY/IntensityTables$CALIBRATION_TOTAL_INTENSITY

    # Get colocalization data
    ColocalizationTablePath <- file.path(CellPath, colocalization_intensity_file)

    if(file.exists(ColocalizationTablePath)){

      ColocalizationTable   <- fread(ColocalizationTablePath)
      SelectIntensityTables <- IntensityTables %>%
        mutate(COMPLEMENTARY_UNIVERSAL_SPOT_ID  = UNIVERSAL_SPOT_ID,
               COMPLEMENTARY_NORMALIZED_INTENSITY = NORMALIZED_INTENSITY) %>%
        select(COMPLEMENTARY_UNIVERSAL_SPOT_ID, COMPLEMENTARY_NORMALIZED_INTENSITY) %>%
        as.data.table()

      ColocalizationTable <- merge(ColocalizationTable, SelectIntensityTables, by = "COMPLEMENTARY_UNIVERSAL_SPOT_ID")
      ColocalizationTable <- ColocalizationTable %>%
        pivot_wider(names_from  = PROTEIN_ID,
                    id_cols     = UNIVERSAL_SPOT_ID,
                    values_from = c(COMPLEMENTARY_PROTEIN, COMPLEMENTARY_TOTAL_INTENSITY,
                                    COMPLEMENTARY_NORMALIZED_INTENSITY, COMPLEMENTARY_UNIVERSAL_SPOT_ID)) %>%
        as.data.table()

      IntensityTables <- merge(IntensityTables, ColocalizationTable, by = "UNIVERSAL_SPOT_ID")
    }

    # Determine nearest neighbor to spot of the same protein
    NearestNeighborTable <- IntensityTables %>%
      filter(!is.na(POSITION_X)) %>%
      group_by(PROTEIN, FRAME) %>%
      mutate(N = n()) %>%
      filter(N > 1) %>%
      select(PROTEIN, FRAME, PUNCTA_DIAMETER, UNIVERSAL_SPOT_ID, POSITION_X, POSITION_Y) %>%
      ungroup() %>%
      as_tibble() %>%
      group_split(PROTEIN, FRAME)

    RADIUS <- max(IntensityTables$PUNCTA_DIAMETER, na.rm = T) * 3
    NeighborResults <- lapply(NearestNeighborTable, NearestNeighborSearch, RADIUS)

    if(NROW(NeighborResults) != 0){
      NeighborResults <- NeighborResults[(which(sapply(NeighborResults,is.list), arr.ind=TRUE))]
      NeighborResults <- rbindlist(NeighborResults, fill = TRUE, use.names = TRUE)
      IntensityTables <- as.data.frame(IntensityTables)
      NeighborResults <- as.data.frame(NeighborResults)
      IntensityTables <- merge(IntensityTables, NeighborResults, by = "UNIVERSAL_SPOT_ID", all = TRUE)

      MissingIndex <- which(is.na(IntensityTables$NEAREST_SPOT))
      IntensityTables$NEAREST_SPOT[MissingIndex]        <- Inf
      MissingIndex <- which(is.na(IntensityTables$SPOTS_WITHIN_RADIUS))
      IntensityTables$SPOTS_WITHIN_RADIUS[MissingIndex] <- 0
      MissingIndex <- which(is.na(IntensityTables$SPOT_RADIUS_LIMIT))
      IntensityTables$SPOT_RADIUS_LIMIT[MissingIndex]   <- RADIUS
    }

    # Get landing frame
    LANDING_FRAME = min(IntensityTables$FRAME)

    # Add actual time
    TimeTable <- file.path(dirname(CellPath), "timesteps.csv")
    if(file.exists(TimeTable)){
      TimeTable <- fread(TimeTable, header = FALSE)
      names(TimeTable) <- "TIME"
      TimeTable <- TimeTable %>% mutate(FRAME = 1:n(), TIME = TIME/1000)
      IntensityTables <- as.data.frame(IntensityTables)
      TimeTable <- as.data.frame(TimeTable)
      IntensityTables <- merge(IntensityTables, TimeTable, by = "FRAME")
    } else{
      #!! NUMBERS: FRAME / FRAME_RATE, not FRAME * FRAME_RATE.
      #!! FRAME_RATE in summary.csv is frames per second: 0.2500604 for an
      #!! acquisition of one frame every 4 s. Multiplying gave an elapsed time
      #!! 16x too small on that run, and TIME feeds LIFETIME, TIME_ADJUSTED and
      #!! TIME_SINCE_LANDING. This branch only runs when timesteps.csv is
      #!! absent, so cells whose ND2 carried per-frame timestamps were never
      #!! affected -- check whether yours have one before assuming the old
      #!! numbers were wrong.
      IntensityTables <- IntensityTables %>%
        mutate(TIME = FRAME/FRAME_RATE)
    }

    IntensityTables$TIME = IntensityTables$TIME - min(IntensityTables$TIME)
    LANDING_TIME = min(IntensityTables$TIME)

    # Calculate basic parameters and save
    IntensityTables <- as.data.table(IntensityTables)

    #!! NUMBERS: ABSOLUTE_POSITION_* on all four border tests.
    #!! POSITION_X is pixels inside the cell crop; ABSOLUTE_POSITION_X is
    #!! microns in the field. Only the second is meaningful divided by
    #!! CALIBRATION_UM (um / (um/px) = px) and compared against WIDTH/HEIGHT.
    #!! The published MIN_X/MIN_Y used POSITION_*, which inflated the value
    #!! ~6.9x at 0.144 um/px so `> PUNCTA_DIAMETER*2` passed for essentially
    #!! everything: only the right and bottom borders were ever filtered.
    #!! Expect track counts to fall slightly and anything averaged over them to
    #!! move. That is the point -- a punctum half outside the field has a
    #!! meaningless integrated intensity -- but it is not cosmetic.
    IntensityTables[, MIN_X := min(ABSOLUTE_POSITION_X/CALIBRATION_UM), by = UNIVERSAL_TRACK_ID]
    IntensityTables[, MIN_X := MIN_X > PUNCTA_DIAMETER*2]
    IntensityTables <- IntensityTables[IntensityTables$MIN_X]
    IntensityTables$MIN_X <- NULL

    IntensityTables[, MAX_X := max(ABSOLUTE_POSITION_X/CALIBRATION_UM), by = UNIVERSAL_TRACK_ID]
    IntensityTables[, MAX_X := MAX_X < WIDTH - PUNCTA_DIAMETER*2]
    IntensityTables <- IntensityTables[IntensityTables$MAX_X]
    IntensityTables$MAX_X <- NULL

    IntensityTables[, MIN_Y := min(ABSOLUTE_POSITION_Y/CALIBRATION_UM), by = UNIVERSAL_TRACK_ID]
    IntensityTables[, MIN_Y := MIN_Y > PUNCTA_DIAMETER*2]
    IntensityTables <- IntensityTables[IntensityTables$MIN_Y]
    IntensityTables$MIN_Y <- NULL

    IntensityTables[, MAX_Y := max(ABSOLUTE_POSITION_Y/CALIBRATION_UM), by = UNIVERSAL_TRACK_ID]
    IntensityTables[, MAX_Y := MAX_Y < HEIGHT - PUNCTA_DIAMETER*2]
    IntensityTables <- IntensityTables[IntensityTables$MAX_Y]
    IntensityTables$MAX_Y <- NULL

    #!! FIX: every track can be filtered out here (a tiny cell at the field
    #!! edge). Returning early is clearer than failing inside the group_by.
    if (NROW(IntensityTables) == 0) {
      message("CombineCellTables: every track of ", Cells[CellX],
              " touches a field border; no tables written for this cell.")
      return(NULL)
    }

    # If infinite distance, put NA
    IntensityTables$NEAREST_SPOT[is.infinite(IntensityTables$NEAREST_SPOT)] = NA

    IntensityTables <- IntensityTables %>%
      group_by(UNIVERSAL_TRACK_ID) %>%
      # Ligand density every 0.5 steps using log base 10
      # Rounds to nearest half log
      # Classifies ligands based on log using base 3.162 (10^.5)
      mutate(LIGAND_DENSITY_CAT = round(log(LIGAND_DENSITY, base = (10^.5)), digits = 0) * 0.5) %>%
      mutate(LIGAND_DENSITY_CAT = signif(10^LIGAND_DENSITY_CAT, 2),
             FRAMES_ADJUSTED = FRAME - min(FRAME),
             TIME_ADJUSTED = TIME - min(TIME),
             LIFETIME = max(TIME) - min(TIME),
             TIME_SINCE_LANDING = TIME - LANDING_TIME,
             FRAMES_SINCE_LANDING = FRAME - LANDING_FRAME,
             MAX_NORMALIZED_INTENSITY = max(NORMALIZED_INTENSITY, na.rm = TRUE),
             STARTING_NORMALIZED_INTENSITY = NORMALIZED_INTENSITY[1]) %>%
      mutate(START_TO_MAX_INTENSITY = MAX_NORMALIZED_INTENSITY - STARTING_NORMALIZED_INTENSITY) %>%
      as.data.table()

    PARAMETER_COLS <- c(
      "LIGAND", "LIGAND_DENSITY",
      "CHANNEL", "POWER", "EXCITATION", "EMMISION", "EXPOSURE", "ANGLE",
      "DIRECTION", "FOCUS", "OBJECTIVE",
      "WIDTH", "HEIGHT", "CALIBRATION_UM",
      "CELL_DIAMETER", "PUNCTA_DIAMETER", "SEGMENT_WITH",
      "TRACKMATE_THRESHOLD", "TRACKMATE_FRAME_GAP",
      "TRACKMATE_GAP_LINK_DISTANCE", "TRACKMATE_MAX_LINK_DISTANCE",
      "SPOT_RADIUS_LIMIT", "CELL_POSITION_X", "CELL_POSITION_Y",
      "TIME_START", "FRAME_RATE",
      "CALIBRATION_IMAGE", "CALIBRATION_TOTAL_INTENSITY", "CALIBRATION_STANDARD_DEVIATION")

    CellData <- IntensityTables %>%
      select(one_of(c("RELATIVE_PATH", PARAMETER_COLS))) %>%
      distinct() %>%
      as.data.table()

    DestinationPath <- file.path(CellPath, "Parameters.csv.gz")
    suppressWarnings({file.remove(DestinationPath)})
    fwrite(CellData, DestinationPath, row.names = F, na = "")
    remove(CellData)

    Parameterless <- IntensityTables %>%
      select(!one_of(PARAMETER_COLS)) %>%
      as.data.table()

    DestinationPath <- file.path(CellPath, "Analysis.csv.gz")
    suppressWarnings({file.remove(DestinationPath)})
    fwrite(Parameterless, DestinationPath, row.names = F, na = "")
    remove(Parameterless)

    # Get names of colocalization
    if(NROW(unique(IntensityTables$PROTEIN)) < 2){
      ColocalizationNames = "ColocalizationNames"
    } else{
      ColocalizationNames <- names(IntensityTables)
      ColocalizationNames <- ColocalizationNames[grep("COMPLEMENTARY", ColocalizationNames)]
    }

    Essential <- IntensityTables %>%
      select(one_of(c("RELATIVE_PATH", "PROTEIN", "COHORT", "LIGAND_DENSITY_CAT",
                      "IMAGE", "CELL", "UNIVERSAL_TRACK_ID", "UNIVERSAL_SPOT_ID",
                      "FRAME", "TIME", "FRAMES_ADJUSTED", "TIME_ADJUSTED",
                      "TIME_SINCE_LANDING", "FRAMES_SINCE_LANDING", "LIFETIME",
                      "NORMALIZED_INTENSITY", "STARTING_NORMALIZED_INTENSITY",
                      "MAX_NORMALIZED_INTENSITY", "START_TO_MAX_INTENSITY",
                      "CELL_AREA", "ABSOLUTE_POSITION_X", "ABSOLUTE_POSITION_Y",
                      "NEAREST_SPOT", "SPOTS_WITHIN_RADIUS",
                      ColocalizationNames))) %>%
      mutate(ANALYSIS_TIME_STAMP = ANALYSIS_TIME_STAMP) %>%
      as.data.table()

    DestinationPath <- file.path(CellPath, "Essential.csv.gz")
    suppressWarnings({file.remove(DestinationPath)})
    fwrite(Essential, DestinationPath, row.names = F, na = "")

    Progress = NROW(Cells)/10
    Progress = round(Progress)
    if(Progress==0){Progress = 1}

    if(CellX %% Progress == 0){
      Progress = CellX/NROW(Cells)
      Progress = Progress*100
      Progress = round(Progress)
      Progress = paste0("     ", Progress, "% complete")
      print(Progress)
    }

    return(CellPath)
  }, error = function(e){
    #!! FIX: report the condition, not just the loop index.
    message("ERROR in CombineCellTables CellX = ", CellX, " (", Cells[CellX], ") ::: ",
            conditionMessage(e))
    return(NULL)
  })
}

CombineImageTables <- function(ImageX){
  tryCatch({
    print(paste("ImageX =", ImageX, "of", nImages))
    CellsList <- CellAnalysis[dirname(CellAnalysis) == Images[ImageX]]

    TableByOutput <- function(OutputX){
      Path <- file.path(CellsList, OutputX)
      Path <- Path[file.exists(Path)]
      Table <- lapply(Path, fread)
      Table <- rbindlist(Table, fill = TRUE, use.names = TRUE)
      DestinationPath <- file.path(Images[ImageX], OutputX)
      suppressWarnings({file.remove(DestinationPath)})
      fwrite(Table, DestinationPath, row.names = F, na = "")
      if(OutputX == "Essential.csv.gz"){
        return(DestinationPath)
      }
    }
    CellsList <- lapply(Outputs, TableByOutput)

    return(Images[ImageX])
  }, error = function(e){
    message("ERROR in CombineImageTables ImageX = ", ImageX, " ::: ", conditionMessage(e))
    return(NULL)
  })
}

GrandTable <- function(OutputX){
  print(paste("Working on", OutputX))
  Paths <- file.path(ProcessedImages, OutputX)
  Paths <- Paths[file.exists(Paths)]
  Tables <- lapply(Paths, fread)
  Tables <- rbindlist(Tables, fill = TRUE, use.names = TRUE)
  save_name <- file.path(output_path, OutputX)
  fwrite(Tables, save_name)
  return(save_name)
}

# =============================================================================
# RUN
# =============================================================================

# Get image list
file_list = fread(summary_path)

# Prep up
file_list <- file_list %>%
  #!! KEPT: force power numeric. The ND2 metadata for the WideField channel puts
  #!! the whole illuminator configuration block into `power`, so fread types the
  #!! WHOLE column as character -- for every channel -- and then
  #!! abs(power - temp_image_list$power) fails for every row. WideField becomes
  #!! NA here, which is harmless: it has no calibration, so it never reaches the
  #!! power comparison.
  mutate(power = suppressWarnings(as.numeric(power))) %>%
  mutate(image = dirname(dirname(protein_relative_path)),
         exposure_units = word(exposure, -1),
         exposure_measurement = as.numeric(word(exposure, 1)),
         direction = direction*pi/180,
         angle = angle*pi/180) %>%
  mutate(exposure = exposure_measurement*ConvertUnits(exposure_units),
         image = basename(image),
         date = substr(image, 0, 8)) %>%
  mutate(date = as.Date(date, format = '%Y%m%d')) %>%
  select(-c(exposure_units, exposure_measurement)) %>%
  as.data.table()

# Separate calibrations and the rest
#!! KEPT: give the tryCatch an error handler. Without one, a failure here left
#!! calibration_list holding the un-analysed table (or nothing at all), and the
#!! script only fell over much later, at the move step.
calibration_list = data.table()
tryCatch({
  calibration_list = file_list[file_list$cohort=="Calibrations",]
  Path <- calibration_list$protein_relative_path
  Path <- dirname(Path)
  Path <- file.path(colocalization_path, Path)
  Path <- file.exists(Path)
  calibration_list <- calibration_list[Path]
  calibration_list <- lapply(seq_len(NROW(calibration_list)), QuantifyCalibration)
  calibration_list <- rbindlist(calibration_list)
}, error = function(e){
  message("compile_tables.R: calibration analysis failed: ", conditionMessage(e))
  calibration_list <<- data.table()
})

#!! FIX: without calibrations every image normalises against 1 and the batch is
#!! not quantitative. That is worth stopping for, not warning about.
if (NROW(calibration_list) == 0) {
  stop("compile_tables.R: no calibration images were quantified. Every ",
       "NORMALIZED_INTENSITY would be raw camera counts. Check that the ",
       "Calibrations cohort reached 06_Colocalization.")
}

image_list <- file_list[file_list$cohort!="Calibrations",]
Path       <- image_list$protein_relative_path
Path       <- dirname(Path)
Path       <- file.path(colocalization_path, Path)
Path       <- file.exists(Path)
image_list <- image_list[Path]

# Pairing
#!! SPEED: setDTthreads(1) around the fork; dynamic scheduling.
#!! KEPT: seq_len.
setDTthreads(1)
PairedList <- mclapply(seq_len(NROW(image_list)), GetCalibrationImages,
                       mc.cores = max(1, min(n_workers, NROW(image_list))),
                       mc.preschedule = FALSE)
setDTthreads(ncores)
PairedList <- rbindlist(PairedList, fill = TRUE, use.names = TRUE)
PairedList <- PairedList %>% distinct() %>% as.data.table()

#!! KEPT: stop here rather than carrying an empty PairedList into the rest of
#!! the script. Every row failing in GetCalibrationImages used to surface much
#!! later as something unrelated.
if (NROW(PairedList) == 0) {
  stop("compile_tables.R: GetCalibrationImages produced nothing for any of ",
       NROW(image_list), " rows. Check summary.csv: a non-numeric power, ",
       "exposure, angle or direction breaks the calibration matching.")
}

ANALYSIS_TIME_STAMP = Sys.time()
ANALYSIS_TIME_STAMP = as.POSIXlt(ANALYSIS_TIME_STAMP, tz = "UTC")
ANALYSIS_TIME_STAMP = as.character(ANALYSIS_TIME_STAMP)

Cells <- unique(PairedList$CELL_PATH)

setDTthreads(1)
CellAnalysis <- mclapply(seq_len(NROW(Cells)), CombineCellTables,
                         mc.cores = max(1, min(n_workers, NROW(Cells))),
                         mc.preschedule = FALSE)
setDTthreads(ncores)
CellAnalysis <- unlist(CellAnalysis)
CellAnalysis <- CellAnalysis[file.exists(CellAnalysis)]

if (NROW(CellAnalysis) == 0) {
  stop("compile_tables.R: no cell produced tables. See the ERROR lines above.")
}

# Combine all cell tables
Images <- dirname(CellAnalysis)
Images <- unique(Images)

# Tables to merge
Outputs <- c("Parameters.csv.gz", "Analysis.csv.gz", "Essential.csv.gz")

nImages <- NROW(Images) ; nImages

#!! SPEED: this was the one serial lapply left in the stage. It is three
#!! rbindlist-and-write calls per image, which parallelise cleanly.
setDTthreads(1)
ProcessedImages <- mclapply(seq_len(nImages), CombineImageTables,
                            mc.cores = max(1, min(n_workers, nImages)),
                            mc.preschedule = FALSE)
setDTthreads(ncores)
ProcessedImages <- unlist(ProcessedImages)

if (make_grand_table) {
  lapply(Outputs, GrandTable)
} else {
  print("MAKE_GRAND_TABLE=FALSE, skipping the batch-level tables")
}

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
#!! FIX: guard against an empty OldCohorts.
if(NROW(OldCohorts) > 0){
  ProcessingFolder = dirname(OldCohorts[1])
  if(NROW(list.files(ProcessingFolder)) == 0){unlink(ProcessingFolder, recursive = TRUE)}
}

print('compile_tables.R is now complete')
print("R session info:")
sessionInfo()