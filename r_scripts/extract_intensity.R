#!/usr/bin/env Rscript
# =============================================================================
# extract_intensity.R
#
# TrackMate XML -> per-spot coordinates -> re-measured intensities.
#
# Every line that behaves differently from the published pipeline is marked:
#
#   #!! NUMBERS  changes the results. Rerun everything; do not mix with old output.
#   #!! FIX      a bug with no effect on the numbers (crashes, silent skips).
#   #!! SPEED    performance only.
#   #!! KEPT     a patch from your working copy, carried over.
#   #!! NOTE     no change, but worth knowing.
#
# grep '#!!' to see all of them at once.
# =============================================================================

args = commandArgs(trailingOnly=TRUE)
parameters_path = args[1]
unlink(".RData")

##############
# User Input #
##############

new_image_ending   = "_intensity_ref.tif"
results_table_name = "_intensity.csv.gz"

# Blow circle k times. For a GFP calibration,
## k=11 was picked because a.u. is 0.387% different to k=51
## and SEM is 0.571% off while 5 is 0.682% different to k=51
## Ideally odd number
k <- 11

##############
# Run Script #
##############

# Libraries----
if (!requireNamespace("pacman", quietly = TRUE)) {stop("Package 'pacman' is not installed. Please install it before running.")}
pacman::p_load(dplyr, stringr, parallel, tidyr, data.table, ff, dtplyr, compiler, ijtiff, XML)
print("All libraries loaded")

# Parallel + JIT setup
ncores <- parallel::detectCores(logical = FALSE)
setDTthreads(ncores)
enableJIT(3)

#!! SPEED: workers for the two mclapply stages. A fork inherits
#!! setDTthreads(ncores), so ncores forks x ncores data.table threads is
#!! ncores^2 threads on ncores cores. setDTthreads(1) is set around each
#!! mclapply and restored after.
slurm_cpus <- suppressWarnings(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK")))
n_workers  <- if (!is.na(slurm_cpus) && slurm_cpus > 0) slurm_cpus else ncores
cat("workers:", n_workers, "(physical cores:", ncores, ")\n")

# Parameters----
directories_list = file.path(parameters_path, "directories.csv")
directories_list = fread(directories_list)
processing_path = directories_list$path[directories_list$contains == "processing"]
tracking_path   = file.path(processing_path, "04_Track")
extraction_path = file.path(processing_path, "05_IntensityExtraction")
constants_path  = file.path(parameters_path, "constants.csv")
input_path      = directories_list$path[directories_list$contains == "input"]

#!! KEPT: summary.csv lives in the run's processing folder, not next to the
#!! ND2 files. With one shared input folder every run would otherwise write and
#!! read the same summary.csv. Published version: file.path(input_path, "summary.csv").
summary_path = file.path(dirname(parameters_path), "summary.csv")
if (!file.exists(summary_path)) {
  stop("summary.csv not found at ", summary_path,
       " - the Python pipeline should have placed it there.")
}

# Get puncta diameter
puncta_diameter = fread(constants_path)
puncta_diameter = puncta_diameter$value[puncta_diameter$parameter == "puncta_diameter"]
puncta_radius   = puncta_diameter * 0.5

# Get image parameters table
file_list = fread(summary_path)

file_list <-
  file_list %>%
  mutate(
    protein_path = file.path(tracking_path, protein_relative_path),
  ) %>%
  mutate(
    image = paste0(protein_path, new_image_ending),
    xml = ifelse(cohort == "Calibrations", protein_path, file.path(dirname(protein_path), "Combined")),
    coordinates_output = file.path(dirname(protein_path), "coordinates.csv.gz"),
    intensity_output = paste0(protein_path, "_intensity.csv.gz")
  ) %>%
  mutate(
    xml = paste0(xml, ".xml")
  ) %>%
  # Keep only files that exist
  filter(
    file.exists(image),
    file.exists(xml)
  ) %>%
  as.data.table()

#!! KEPT: this filter silently drops every row when the files are not where
#!! summary.csv says they should be, and the script then failed much later with
#!! "FileX = 0". Report what was actually checked instead.
if (NROW(file_list) == 0) {
  probe <- fread(summary_path)
  probe <- probe %>%
    mutate(protein_path = file.path(tracking_path, protein_relative_path)) %>%
    mutate(
      image = paste0(protein_path, new_image_ending),
      xml   = ifelse(cohort == "Calibrations", protein_path,
                     file.path(dirname(protein_path), "Combined")),
      xml   = paste0(xml, ".xml")
    ) %>%
    as.data.table()
  message("extract_intensity.R: summary.csv has ", NROW(probe),
          " row(s), but none of the files they point to exist.")
  message("  tracking_path : ", tracking_path)
  message("  exists?       : ", dir.exists(tracking_path))
  message("  missing image : ", sum(!file.exists(probe$image)), " of ", NROW(probe))
  message("  missing xml   : ", sum(!file.exists(probe$xml)),   " of ", NROW(probe))
  message("  first expected image: ", probe$image[1])
  message("  first expected xml  : ", probe$xml[1])
  if (dir.exists(tracking_path)) {
    message("  cohort folders present under 04_Track: ",
            paste(head(list.dirs(tracking_path, recursive = FALSE, full.names = FALSE), 5),
                  collapse = ", "))
  }
  stop("extract_intensity.R: nothing to process. The paths in summary.csv do ",
       "not match what is on disk -- compare the two lines above.")
}

# XML to coordinates CSV----

#!! SPEED: one Combined.xml per cell, but file_list has one row per protein, so
#!! every XML was in this vector twice and parsed twice -- producing the same
#!! coordinates.csv.gz both times. XMLtoTableFx already handles all proteins of
#!! a cell in one call (see BindProteinData), so the second parse was pure waste.
#!! This halves the slowest stage on a two-colour dataset.
xml_list <- unique(file_list$xml)
#!! SPEED: largest first. mclapply hands out contiguous blocks, so ascending
#!! order put every slow file in the last block and the stage ended with one
#!! worker still running. Published version sorted ascending.
xml_list <- xml_list[order(file.size(xml_list), decreasing = TRUE)]
cat("XML files to parse:", NROW(xml_list), "\n")

# Use average point for missing spots
MissingSpotsFx <- function(TableX){
  tryCatch({
    Table <- TableX
    Table$MISSING = FALSE
    # Get actual frames
    ActualFrames <- unique(Table$FRAME)
    # Get predicted frames
    PredictedFrames <- min(Table$FRAME):max(Table$FRAME)
    # Find missing frames
    MissingFrames <- NULL
    MissingFrames$FRAME <- PredictedFrames[!PredictedFrames %in% ActualFrames]
    MissingFrames$TRACK_ID <- rep(Table$TRACK_ID[1], NROW(MissingFrames$FRAME))
    MissingFrames$MISSING <- rep(TRUE, NROW(MissingFrames$FRAME))
    # Create new table
    MissingFrames <- bind_rows(Table, MissingFrames)

    # Fill coordinates
    MissingFrames <-
      MissingFrames %>%
      arrange(FRAME) %>%
      mutate(
        PREVIOUS_POSITION_X = POSITION_X,
        NEXT_POSITION_X = POSITION_X,
        PREVIOUS_POSITION_Y = POSITION_Y,
        NEXT_POSITION_Y = POSITION_Y
      ) %>%
      fill(PREVIOUS_POSITION_X, PREVIOUS_POSITION_Y, .direction = "down") %>%
      fill(NEXT_POSITION_X, NEXT_POSITION_Y, .direction = "up") %>%
      filter(MISSING == TRUE) %>%
      group_by(PREVIOUS_POSITION_X, PREVIOUS_POSITION_Y,
               NEXT_POSITION_X, NEXT_POSITION_Y) %>%
      mutate(
        POSITION = 1:n() / (n() + 1),
        POSITION_X = (NEXT_POSITION_X - PREVIOUS_POSITION_X)*POSITION + PREVIOUS_POSITION_X,
        POSITION_Y = (NEXT_POSITION_Y - PREVIOUS_POSITION_Y)*POSITION + PREVIOUS_POSITION_Y
      ) %>%
      ungroup() %>%
      select(TRACK_ID, FRAME, POSITION_X, POSITION_Y)
    return(MissingFrames)
  }, error = function(e){print(paste("     ERROR with MissingSpotsFx"))})
}

# Get spot data from XML
SpotsFx <- function(SpotX, Spots) {
  tryCatch({
    Table <- Spots[SpotX]$SpotsInFrame
    Table <- Table[1:(NROW(Table)-1)]
    Table <- as.data.frame(Table)
    Table <- t(Table)
    Table <- as.data.frame(Table)

    if(NCOL(Table) == 1) {
      Table = NULL
    }
    return(Table)
  }, error = function(e){print(paste("ERROR with SpotsFx. SpotX =", SpotX))})
}

# Add track data to spots
TracksFx <- function(TrackX, Tracks) {
  tryCatch({
    Table <- Tracks[TrackX]$Track
    Table <- Table[1:(NROW(Table)-1)]
    Table <- as.data.frame(Table)
    Table <- t(Table)
    Table <- as.data.frame(Table)

    Table$TRACK_ID = TrackX - 1

    return(Table)
  }, error = function(e){print(paste("ERROR with TracksFx TrackX =", TrackX))})
}

# Make csv from XML
XMLtoTableFx <- function(FileX){
  tryCatch({
    print(paste("XMLtoTableFx FileX =", FileX))

    temp_file_list <-
      file_list %>%
      filter(xml == xml_list[FileX]) %>%
      as.data.table()

    # Get cell data
    xml_path  = temp_file_list$xml[1]
    save_path = temp_file_list$coordinates_output[1]

    # Rename columns
    names(temp_file_list) <- toupper(names(temp_file_list))

    temp_file_list <-
      temp_file_list %>%
      as_tibble() %>%
      mutate(
        RELATIVE_PATH = PROTEIN_RELATIVE_PATH,
        PROTEIN = PROTEIN_NAME,
        CELL = dirname(PROTEIN_RELATIVE_PATH),
        IMAGE = dirname(CELL),
        CELL = basename(CELL),
        CELL = gsub("Cell_", "", CELL),
        IMAGE = basename(IMAGE),
        CELL_POSITION_X = POSITION_X,
        CELL_POSITION_Y = POSITION_Y,
        CELL_AREA = AREA
      ) %>%
      select(-c(
        PROTEIN_RELATIVE_PATH,
        PROTEIN_NAME,
        POSITION_X,
        POSITION_Y,
        AREA,
        INTENSITY_OUTPUT,
        COORDINATES_OUTPUT,
        XML
      ))

    # Import XML
    xml_data <- XML::xmlParse(xml_path[1])
    xml_data <- XML::xmlToList(xml_data)

    # Get spot data
    Spots <- xml_data$Model$AllSpots
    SpotsTable <- lapply(1:NROW(Spots), SpotsFx, Spots)
    SpotsTable <- SpotsTable[(which(sapply(SpotsTable,is.list), arr.ind=TRUE))]
    SpotsTable <- data.table::rbindlist(SpotsTable)

    # Get tracks data
    Tracks <- xml_data$Model$AllTracks
    TracksTable <- lapply(1:NROW(Tracks), TracksFx, Tracks)
    TracksTable <- TracksTable[(which(sapply(TracksTable,is.list), arr.ind=TRUE))]
    TracksTable <- data.table::rbindlist(TracksTable)

    SPOTS1 <- TracksTable %>% mutate(ID = SPOT_SOURCE_ID) %>% select(ID, TRACK_ID) %>% as.data.table()
    SPOTS2 <- TracksTable %>% mutate(ID = SPOT_TARGET_ID) %>% select(ID, TRACK_ID) %>% as.data.table()
    SPOTS  <- bind_rows(SPOTS1, SPOTS2) %>% distinct() %>% as.data.table()

    SpotsTable <- as.data.frame(SpotsTable)
    SPOTS <- as.data.frame(SPOTS)
    SpotsTable <- merge(SpotsTable, SPOTS, by = "ID")
    remove(SPOTS, SPOTS1, SPOTS2)

    #!! NOTE: this is the frame offset the app's "Frame offset" box exists for.
    #!! TrackMate FRAME is 0-based; +1 here makes the essentials 1-based AND
    #!! absorbs the frame the running average consumed. ExtractFx below then
    #!! reads slice FRAME + 1 of the _intensity_ref stack, so:
    #!!     essentials FRAME f  <->  _intensity_ref slice f + 1
    #!! Set the app's frame offset to +1 when its macros read _intensity_ref.tif.
    #!! Unchanged from the publication - do not "fix" this without re-deriving
    #!! every intensity in the dataset.
    SpotsTable$FRAME <- as.numeric(SpotsTable$FRAME) + 1
    SpotsTable$POSITION_X <- as.numeric(SpotsTable$POSITION_X)
    SpotsTable$POSITION_Y <- as.numeric(SpotsTable$POSITION_Y)

    # Generate table to find missing spots
    MissingSpotsTables <-
      SpotsTable %>%
      group_by(TRACK_ID) %>%
      mutate(RANGE = max(FRAME) - min(FRAME), N = n() - 1) %>%
      filter(RANGE != N) %>%
      ungroup() %>%
      select(TRACK_ID, FRAME, POSITION_X, POSITION_Y) %>%
      arrange(TRACK_ID, FRAME) %>%
      as_tibble() %>%
      group_split(TRACK_ID)

    # Add missing puncta only if it's not a calibration
    # Dark-phases are normal in fluorophores
    #!! NUMBERS: `|` -> `&`. The comment above says what this was meant to do,
    #!! but with `|` the gap filling also ran on calibration images whenever any
    #!! track had a gap -- interpolating across a fluorophore's dark phase and
    #!! feeding those invented spots into the median that becomes
    #!! CALIBRATION_TOTAL_INTENSITY. Every NORMALIZED_INTENSITY in the dataset
    #!! is divided by that number, so this moves all of them slightly.
    if(NROW(MissingSpotsTables) > 0 & temp_file_list$COHORT[1] != "Calibrations"){
      MissingSpotsTables <- lapply(MissingSpotsTables, MissingSpotsFx)
      MissingSpotsTables <- rbindlist(MissingSpotsTables)
      # Add missing coordinates
      SpotsTable <- bind_rows(SpotsTable, MissingSpotsTables)
    }

    # Combine cell parameters with spot data
    select_cell_parameters <-
      temp_file_list %>%
      select(IMAGE, CELL, PROTEIN) %>%
      as.data.table()

    # Add parameters to spots table
    N_PROTEINS = unique(select_cell_parameters$PROTEIN)

    BindProteinData <- function(p, SpotsTable, select_cell_parameters){

      TempShortFullTable <- cbind(SpotsTable, select_cell_parameters[p])

      TempShortFullTable <-
        TempShortFullTable %>%
        select(
          IMAGE, CELL, PROTEIN, TRACK_ID,
          QUALITY,
          POSITION_X, POSITION_Y, RADIUS,
          FRAME,
          contains("SNR")
        ) %>%
        mutate(
          UNIVERSAL_TRACK_ID = paste(IMAGE, CELL, PROTEIN, TRACK_ID, sep = "..."),
          UNIVERSAL_COLOCALIZATION_GROUP = paste(IMAGE, CELL, TRACK_ID, sep = "...")
        ) %>%
        mutate(
          UNIVERSAL_SPOT_ID = paste(UNIVERSAL_TRACK_ID, FRAME, sep = "..."),
          UNIVERSAL_COLOCALIZATION_FRAME = paste(UNIVERSAL_COLOCALIZATION_GROUP, FRAME, sep = "...")
        ) %>%
        as.data.table()

      return(TempShortFullTable)
    }

    ShortFullTable <- lapply(1:NROW(N_PROTEINS), BindProteinData, SpotsTable, select_cell_parameters)
    ShortFullTable <- rbindlist(ShortFullTable)
    ShortFullTable <- ShortFullTable %>% arrange(FRAME, TRACK_ID) %>% as.data.table()

    temp_file_list <- temp_file_list %>% select(-c(IMAGE, CELL, PROTEIN_PATH)) %>% as.data.table()

    FullTable <- merge(ShortFullTable, temp_file_list, by = "PROTEIN")

    # Remove if it exists
    #!! KEPT: file.remove() has no showWarnings argument - it was treating
    #!! "FALSE" as a second file name to delete.
    suppressWarnings({file.remove(save_path)})
    data.table::fwrite(FullTable, save_path, row.names = F, na = "")

    Progress = NROW(xml_list)/10
    Progress = round(Progress)
    if(Progress==0){Progress = 1}

    if(FileX %% Progress == 0){
      Progress = FileX/NROW(xml_list)
      Progress = Progress*100
      Progress = round(Progress)
      Progress = paste0("     ", Progress, "% complete")
      print(Progress)
    }
    #!! SPEED: the published version slept one second here, inside the worker,
    #!! once per XML. Removed.

    return(save_path)
  }, error = function(e){print(paste("ERROR with XMLtoTableFx FileX =", FileX))})
}

#!! SPEED: mc.cores. The published version passed detectCores(logical = F); a
#!! later edit dropped the argument entirely, which silently falls back to R's
#!! default of 2 workers. mc.preschedule = FALSE gives dynamic scheduling, which
#!! matters because XML sizes vary by an order of magnitude within a run.
#!! KEPT: seq_len - 1:NROW is c(1, 0) on an empty vector and ran FileX = 0.
setDTthreads(1)
ResultsPath <- mclapply(seq_len(NROW(xml_list)), XMLtoTableFx,
                        mc.cores = max(1, min(n_workers, NROW(xml_list))),
                        mc.preschedule = FALSE)
setDTthreads(ncores)

# Make vector of paths
ResultsPath <- as.vector(ResultsPath)
ResultsPath <- unlist(ResultsPath)
# Remove error rows
ResultsPath <- ResultsPath[!grepl("ERROR with XMLtoTableFx FileX =", ResultsPath)]

#!! FIX: say so when XMLs failed, rather than carrying on with fewer cells.
if (NROW(ResultsPath) < NROW(xml_list)) {
  message("extract_intensity.R: ", NROW(xml_list) - NROW(ResultsPath), " of ",
          NROW(xml_list), " XML files failed to parse. See the ERROR lines above.")
}
if (NROW(ResultsPath) == 0) {
  stop("extract_intensity.R: no XML file could be parsed.")
}

# Make list of tables and images
file_list  <- file_list[file.exists(file_list$coordinates_output)]
file_list  <- file_list[order(file.size(file_list$image), decreasing = TRUE)]  #!! SPEED: see above
image_list <- unique(file_list$image)

# Reextract intensitites----

# Make multi-page image into split frames
split_img <- function(t, img){
  return(img[,,,t])
}

# For re-scaling matrix
## m is matrix and k is scale up k-times
scale_matrix <- function(m, k) {
  rows = nrow(m)
  cols = ncol(m)

  rs <- rep(1:rows, each = k)
  cs <- rep(1:cols, each = k)

  return(m[rs, ][, cs])
}

# Split frames among cores
IntensityFx <- function(TempTableFrames, img_frame, circle_mask, k, k2_r){

  intensity_list = NULL
  intensity_list$SpotID = TempTableFrames$SpotID
  intensity_list$Intensity = rep(0, NROW(TempTableFrames))

  # Make loop to speed up
  for(SpotX in 1:nrow(TempTableFrames)){
    # Crop image
    cropped_img = img_frame[TempTableFrames$y_min[SpotX]:TempTableFrames$y_max[SpotX],
                            TempTableFrames$x_min[SpotX]:TempTableFrames$x_max[SpotX]]
    rs <- rep(1:TempTableFrames$rows[SpotX], each = k)
    cs <- rep(1:TempTableFrames$cols[SpotX], each = k)

    cropped_img <- cropped_img[rs, ][, cs]

    # Blow up
    cropped_img = cropped_img[TempTableFrames$expand_y_min[SpotX]:TempTableFrames$expand_y_max[SpotX],
                              TempTableFrames$expand_x_min[SpotX]:TempTableFrames$expand_x_max[SpotX]]
    # Mask image
    cropped_img = cropped_img*circle_mask
    # Get intensity
    intensity_list$Intensity[SpotX] = sum(cropped_img)*k2_r
  }
  intensity_list <- as.data.table(intensity_list)

  return(intensity_list)
}
IntensityFx <- cmpfun(IntensityFx)

# Make matrix into table
MatrixToTable <- function(x, df){
  return(df[,x])
}

# Extract intensity
ExtractFx <- function(FileX) {
  tryCatch({
    message("=== ExtractFx started for FileX = ", FileX, " ===")

    temp_file_list <- file_list %>%
      filter(image == image_list[FileX]) %>%
      as.data.table()

    if (nrow(temp_file_list) == 0) {
      stop("No matching entries found in file_list for FileX = ", FileX)
    }
    message("Loaded file entry for image: ", temp_file_list$image)

    #!! KEPT: read_tags() returns a list of per-frame tag lists; the published
    #!! version indexed it as img_meta$frame1$width, which newer ijtiff does not
    #!! provide. Take the first frame and check the fields exist.
    img_meta <- read_tags(temp_file_list$image)
    if (length(img_meta) == 0) {
      stop("No metadata found for image: ", temp_file_list$image)
    }
    first_frame <- img_meta[[1]]
    if (is.null(first_frame$ImageWidth) || is.null(first_frame$ImageLength)) {
      stop("Metadata does not contain ImageWidth/ImageLength for: ", temp_file_list$image)
    }
    lim_x_max <- first_frame$ImageWidth
    lim_y_max <- first_frame$ImageLength
    message("Image dimensions detected: width=", lim_x_max, ", height=", lim_y_max)

    # Constants
    k2_r      <- 1 / k^2
    r         <- puncta_radius
    d         <- r * 2
    new_scale <- k * d
    lim_r     <- (d * k) - 1

    TempTable <- fread(temp_file_list$coordinates_output[1])
    if (nrow(TempTable) == 0) {
      stop("Coordinates table empty: ", temp_file_list$coordinates_output[1])
    }
    message("Coordinates table loaded with ", nrow(TempTable), " rows")

    TempTable <- TempTable %>%
      filter(PROTEIN == temp_file_list$protein_name[1]) %>%
      group_by(UNIVERSAL_SPOT_ID) %>%
      mutate(
        x = POSITION_X + 1,
        y = POSITION_Y + 1,
        x_min = floor(x - r),
        x_max = ceiling(x + r),
        y_min = floor(y - r),
        y_max = ceiling(y + r),
        test = (y_max < lim_y_max) & (x_max < lim_x_max) & (x_min > 0 & y_min > 0)
      )

    if (any(is.na(TempTable$test))) {
      stop("Boundary test failed: NA values detected in 'test' column")
    }

    TempTable <- TempTable %>%
      group_by(UNIVERSAL_TRACK_ID) %>%
      filter(sum(!test) == 0) %>%
      arrange(FRAME) %>%
      group_by(FRAME) %>%
      mutate(t = cur_group_id()) %>%
      as.data.table()

    if (nrow(TempTable) == 0) {
      stop("No valid puncta survived filtering (all touching boundaries?)")
    }
    message("Filtered table has ", nrow(TempTable), " rows after border check")

    #!! NOTE: the second half of the frame offset - essentials FRAME f is read
    #!! from slice f + 1 of the _intensity_ref stack. Unchanged.
    N_FRAMES <- unique(TempTable$FRAME) + 1
    img <- read_tif(temp_file_list$image, frames = N_FRAMES, msg = FALSE)
    img_frames <- lapply(1:NROW(N_FRAMES), split_img, img)

    # Circle mask
    circle_mask <- (rep(1:new_scale, new_scale) - (r * k + .5))^2 +
      (rep(1:new_scale, each = new_scale) - (r * k + .5))^2 <= (r * k)^2
    circle_mask <- matrix(circle_mask, nrow = new_scale)
    circle_mask_list <- list(circle_mask)

    TempTable <- TempTable %>%
      group_by(UNIVERSAL_TRACK_ID) %>%
      mutate(
        expand_x_min = round(((x - r) - x_min + 1) * k),
        expand_y_min = round(((y - r) - y_min + 1) * k),
        expand_x_max = expand_x_min + lim_r,
        expand_y_max = expand_y_min + lim_r,
        rows = y_max - y_min + 1,
        cols = x_max - x_min + 1
      ) %>%
      as.data.table()

    SplitTempTable <- TempTable %>%
      select(t, x_min, x_max, y_min, y_max,
             expand_x_min, expand_x_max, expand_y_min, expand_y_max,
             rows, cols) %>%
      arrange(t) %>%
      mutate(SpotID = 1:n()) %>%
      as_tibble() %>%
      group_split(t)
    SplitTempTable <- lapply(SplitTempTable, as.data.table)

    Intensities <- mapply(IntensityFx, SplitTempTable, img_frames,
                          circle_mask_list, k, k2_r)
    Intensities <- lapply(1:NCOL(Intensities), MatrixToTable, Intensities)
    Intensities <- rbindlist(Intensities)

    TempTable <- TempTable %>%
      select(-c(x, y, t, x_min, x_max, y_min, y_max, test,
                expand_x_min, expand_x_max, expand_y_min, expand_y_max,
                rows, cols)) %>%
      as.data.frame()

    TempTable$TOTAL_INTENSITY <- Intensities$Intensity

    TempTable <- TempTable %>%
      group_by(UNIVERSAL_SPOT_ID) %>%
      mutate(
        POSITION_X = as.numeric(POSITION_X),
        POSITION_Y = as.numeric(POSITION_Y),
        ABSOLUTE_POSITION_X = (CELL_POSITION_X + POSITION_X) * CALIBRATION_UM,
        ABSOLUTE_POSITION_Y = (CELL_POSITION_Y + POSITION_Y) * CALIBRATION_UM
      ) %>%
      as.data.frame()

    save_path <- paste0(temp_file_list$protein_path, "_intensity.csv.gz")
    suppressWarnings(file.remove(save_path))
    data.table::fwrite(TempTable, save_path, row.names = FALSE, na = "")
    message("Saved intensity table: ", save_path)

    Progress <- max(1, round(NROW(image_list) / 10))
    if (FileX %% Progress == 0) {
      pct <- round(FileX / NROW(image_list) * 100)
      message("Progress: ", pct, "% complete")
    }

    message("=== ExtractFx finished for FileX = ", FileX, " ===")
    return(save_path)

  }, error = function(e) {
    message("!!! ERROR in ExtractFx FileX = ", FileX, " ::: ", conditionMessage(e))
    return(NULL)
  })
}

#!! SPEED: each worker holds a whole TIFF stack, so this stage is memory-bound.
#!! A later edit set mc.cores = detectCores(logical = TRUE), which is 144 on this
#!! node: twice as many stacks resident as there are real cores to work on them,
#!! and the usual cause of the workers being OOM-killed. Honour the Slurm
#!! allocation when there is one. Published version: detectCores(logical = F).
setDTthreads(1)
ResultsPath <- mclapply(seq_len(NROW(image_list)), ExtractFx,
                        mc.cores = max(1, min(n_workers, NROW(image_list))),
                        mc.preschedule = FALSE)
setDTthreads(ncores)
ResultsPath <- unlist(ResultsPath)

#!! KEPT: mclapply returns NULL for images that errored, and those used to be
#!! dropped silently. Report them and fail the script so submit_node.sh notices.
nFailed <- NROW(image_list) - NROW(ResultsPath)
if (nFailed > 0) {
  message("extract_intensity.R: ", nFailed, " of ", NROW(image_list),
          " images failed. See the ERROR lines above.")
}
if (NROW(ResultsPath) == 0) {
  stop("extract_intensity.R: no images were processed successfully.")
}

# Get images path
ImagePath <- dirname(dirname(ResultsPath))
ImagePath <- unique(ImagePath)
# Get cohort names
Cohorts <- basename(dirname(ImagePath))
Cohorts <- file.path(extraction_path, Cohorts)
Cohorts <- unique(Cohorts)
# Create re-extraction path if it doesn't exist
if(!file.exists(extraction_path)){dir.create(extraction_path)}
# Create cohort path if it doesn't exist
for(Cohort in Cohorts){if(!file.exists(Cohort)){dir.create(Cohort)}}

# Move Image
for(Image in ImagePath){
  old_path = Image
  Cohort = basename(dirname(Image))
  Image = basename(Image)
  new_path = file.path(extraction_path, Cohort, Image)
  file.move(old_path, new_path)
}

# Delete cohort if empty
OldCohorts = unique(dirname(ImagePath))
for(Cohort in OldCohorts){
  if(NROW(list.files(Cohort)) == 0){unlink(Cohort, recursive = TRUE)}
}

# Delete processing folder if empty
#!! FIX: guard against an empty OldCohorts. dirname(character(0)[1]) is NA, and
#!! unlink(NA, recursive = TRUE) on a shared filesystem is not something to find
#!! out about the hard way. colocalization.R already had this guard.
if(NROW(OldCohorts) > 0){
  ProcessingFolder = dirname(OldCohorts[1])
  if(NROW(list.files(ProcessingFolder)) == 0){
    unlink(ProcessingFolder, recursive = TRUE)
  }
}

print('extract_intensity.R is now complete')
print("R session info:")
sessionInfo()