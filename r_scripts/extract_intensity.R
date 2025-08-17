#!/usr/bin/env Rscript
args = commandArgs(trailingOnly=TRUE)
parameters_path = args[1]
unlink(".RData")

##############
# User Input #
##############

# parameters_path = "/raven/u/deliz/new_pipeline/20220425/Input/parameter_tables"
new_image_ending = "_intensity_ref.tif"
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
# Ease library loading
if("pacman" %in% rownames(installed.packages()) == FALSE)
{install.packages("pacman")}
# Actually load libraries
pacman::p_load(dplyr, parallel, tidyr, data.table, ff, ijtiff, XML, dtplyr, compiler)

# Compile functions before running
setDTthreads(detectCores(logical = F))
enableJIT(3)

# Parameters----
# Get directories
directories_list = file.path(parameters_path, "directories.csv")
directories_list = fread(directories_list)
processing_path = directories_list$path[directories_list$contains == "processing"]
tracking_path = file.path(processing_path, "04_Track")
extraction_path = file.path(processing_path, "05_IntensityExtraction")
constants_path = file.path(parameters_path, "constants.csv") 
input_path = directories_list$path[directories_list$contains == "input"]
summary_path = file.path(input_path, "summary.csv")

# Get puncta diameter
puncta_diameter = fread(constants_path)
puncta_diameter = puncta_diameter$value[puncta_diameter$parameter == "puncta_diameter"]
puncta_radius = puncta_diameter * 0.5
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

# XML to coordinates CSV----

# Arrange by order
xml_list <- file_list$xml
xml_list <- xml_list[order(file.size(xml_list))]

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
      arrange(
        FRAME
      ) %>% 
      mutate(
        PREVIOUS_POSITION_X = POSITION_X,
        NEXT_POSITION_X = POSITION_X,
        PREVIOUS_POSITION_Y = POSITION_Y,
        NEXT_POSITION_Y = POSITION_Y
      ) %>% 
      fill(
        PREVIOUS_POSITION_X,
        PREVIOUS_POSITION_Y,
        .direction = "down"
      ) %>% 
      fill(
        NEXT_POSITION_X,
        NEXT_POSITION_Y,
        .direction = "up"
      ) %>% 
      filter(
        MISSING == TRUE
      ) %>% 
      group_by(
        PREVIOUS_POSITION_X,
        PREVIOUS_POSITION_Y,
        NEXT_POSITION_X,
        NEXT_POSITION_Y
      ) %>% 
      mutate(
        POSITION = 1:n() / (n() + 1),
        POSITION_X = (NEXT_POSITION_X - PREVIOUS_POSITION_X)*POSITION + PREVIOUS_POSITION_X,
        POSITION_Y = (NEXT_POSITION_Y - PREVIOUS_POSITION_Y)*POSITION + PREVIOUS_POSITION_Y
      ) %>% 
      ungroup() %>% 
      select(
        TRACK_ID,
        FRAME,
        POSITION_X,
        POSITION_Y
      )
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
      filter(
        xml == xml_list[FileX]
      ) %>% 
      as.data.table()
    
    # Get cell data
    xml_path = temp_file_list$xml[1]
    save_path = temp_file_list$coordinates_output[1]
    
    # Rename columns
    names(temp_file_list) <- toupper(names(temp_file_list))
    
    temp_file_list <-
      temp_file_list%>% 
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
    SpotsTable <- lapply(1:NROW(Spots), SpotsFx, Spots)#, mc.cores = detectCores(logical = F))
    SpotsTable <- SpotsTable[(which(sapply(SpotsTable,is.list), arr.ind=TRUE))]
    SpotsTable <- data.table::rbindlist(SpotsTable)
    
    # Get tracks data
    Tracks <- xml_data$Model$AllTracks
    TracksTable <- lapply(1:NROW(Tracks), TracksFx, Tracks)#, mc.cores = detectCores(logical = F))
    TracksTable <- TracksTable[(which(sapply(TracksTable,is.list), arr.ind=TRUE))]
    TracksTable <- data.table::rbindlist(TracksTable)
    
    SPOTS1 <-
      TracksTable %>%
      mutate(
        ID = SPOT_SOURCE_ID
      ) %>%
      select(
        ID,
        TRACK_ID
      ) %>% 
      as.data.table()
    
    SPOTS2 <-
      TracksTable %>%
      mutate(
        ID = SPOT_TARGET_ID
      ) %>%
      select(
        ID,
        TRACK_ID
      ) %>% 
      as.data.table()
    
    SPOTS <- bind_rows(SPOTS1, SPOTS2) %>% distinct() %>% as.data.table()
    
    SpotsTable <- as.data.frame(SpotsTable)
    SPOTS <- as.data.frame(SPOTS)
    SpotsTable <- merge(SpotsTable, SPOTS, by = "ID")
    remove(SPOTS, SPOTS1, SPOTS2)
    # Add one to account for running average
    SpotsTable$FRAME <- as.numeric(SpotsTable$FRAME) + 1
    SpotsTable$POSITION_X <- as.numeric(SpotsTable$POSITION_X)
    SpotsTable$POSITION_Y <- as.numeric(SpotsTable$POSITION_Y)
    # Generate table to find missing spots
    MissingSpotsTables <-
      SpotsTable %>% 
      group_by(
        TRACK_ID
      ) %>% 
      mutate(
        RANGE = max(FRAME) - min(FRAME),
        N = n() - 1
      ) %>% 
      filter(
        RANGE != N
      ) %>% 
      ungroup() %>% 
      select(
        TRACK_ID,
        FRAME,
        POSITION_X,
        POSITION_Y
      ) %>% 
      arrange(
        TRACK_ID,
        FRAME
      ) %>% 
      as_tibble() %>% 
      group_split(
        TRACK_ID
      )
    
    # Add missing puncta only if it's not a calibration
    # Dark-phases are normal in fluorophores
    if(NROW(MissingSpotsTables)>0 |temp_file_list$COHORT[1] != "Calibrations"){
      MissingSpotsTables <- lapply(MissingSpotsTables, MissingSpotsFx)#, mc.cores = detectCores(logical = F))
      MissingSpotsTables <- rbindlist(MissingSpotsTables)
      # Add missing coordinates
      SpotsTable <- bind_rows(SpotsTable, MissingSpotsTables)
    }
    # Combine cell parameters with spot data
    select_cell_parameters <-
      temp_file_list %>% 
      select(
        IMAGE, CELL, PROTEIN
      ) %>% 
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
    
    ShortFullTable <- lapply(1:NROW(N_PROTEINS), BindProteinData, SpotsTable, select_cell_parameters)#, mc.cores = detectCores(logical = F))
    ShortFullTable <- rbindlist(ShortFullTable)
    ShortFullTable <- ShortFullTable %>% arrange(FRAME, TRACK_ID) %>% as.data.table()
    
    temp_file_list <- temp_file_list %>% select(-c(IMAGE, CELL, PROTEIN_PATH)) %>% as.data.table()
    
    FullTable <- merge(ShortFullTable, temp_file_list, by = "PROTEIN")
    
    # Remove if it exists
    suppressWarnings({
      file.remove(save_path, showWarnings = FALSE)
    })
    data.table::fwrite(FullTable, save_path, row.names = F, na = "")
    
    
    Progress = NROW(file_list)/10
    Progress = round(Progress)
    if(Progress==0){
      Progress = 1
    }
    
    if(FileX %% Progress == 0){
      Progress = FileX/NROW(file_list)
      Progress = Progress*100
      Progress = round(Progress)
      Progress = paste0("     ", Progress, "% complete")
      print(Progress)
    }
    Sys.sleep(1)
    
    return(save_path)
  }, error = function(e){print(paste("ERROR with XMLtoTableFx FileX =", FileX))})
}
ResultsPath <- mclapply(1:NROW(xml_list), XMLtoTableFx, mc.cores = detectCores(logical = F))

# Make vector of paths
ResultsPath <- as.vector(ResultsPath)
ResultsPath <- unlist(ResultsPath)
# Remove error rows
ResultsPath <- ResultsPath[!grepl("ERROR with XMLtoTableFx FileX =", ResultsPath)]

# Make list of tables and images
file_list <- file_list[file.exists(file_list$coordinates_output)]
file_list <- file_list[order(file.size(file_list$image))]
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
  
  m[rs, ][, cs]
  
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
ExtractFx <- function(FileX){
  tryCatch({
    print(paste("ExtractFx FileX =", FileX))
    
    # Get file list
    temp_file_list <-
      file_list %>% 
      filter(
        image == image_list[FileX]
      ) %>% 
      as.data.table()
    # Get img metadata to exclude tracks that touch border
    img_meta <- read_tags(temp_file_list$image)
    
    # Get constants
    k2_r <- 1/k^2
    r <- puncta_radius
    d <- r*2
    new_scale = k*d
    lim_r <- (d*k)-1
    lim_x_max = img_meta$frame1$width
    lim_y_max = img_meta$frame1$length
    
    # Get cell data
    TempTable <- fread(temp_file_list$coordinates_output[1])
    TempTable <-
      TempTable %>%
      filter(PROTEIN == temp_file_list$protein_name[1]) %>% 
      group_by(
        UNIVERSAL_SPOT_ID
      ) %>% 
      mutate(
        x = POSITION_X + 1,
        y = POSITION_Y + 1
      ) %>% 
      mutate(
        x_min = floor(x - r),
        x_max = ceiling(x + r),
        y_min = floor(y - r),
        y_max = ceiling(y + r)
      ) %>% 
      mutate(
        test = (y_max < lim_y_max) & (x_max < lim_x_max) & (x_min > 0 & y_min > 0)
      ) %>% 
      group_by(
        UNIVERSAL_TRACK_ID
      ) %>% 
      filter(
        sum(!test) == 0
      ) %>% 
      arrange(
        FRAME
      ) %>% 
      group_by(
        FRAME
      ) %>% 
      mutate(
        t = cur_group_id()
      ) %>% 
      as.data.table()
    
    # Read image
    N_FRAMES = unique(TempTable$FRAME) + 1
    img <- read_tif(temp_file_list$image, frames = N_FRAMES, msg = FALSE)
    # Split image
    img_frames <- lapply(1:NROW(N_FRAMES), split_img, img)
    
    # Make mask
    circle_mask = (rep(1:new_scale, new_scale) - (r*k+.5))^2 + (rep(1:new_scale, each=new_scale) - (r*k+.5))^2 <= (r*k)^2
    circle_mask = matrix(circle_mask, nrow = new_scale)
    circle_mask_list <- list()
    circle_mask_list[[1]] <- circle_mask
    
    # Expand table
    TempTable <-
      TempTable %>% 
      group_by(
        UNIVERSAL_TRACK_ID
      ) %>% 
      mutate(
        expand_x_min = (x-r) - x_min + 1,
        expand_y_min = (y-r) - y_min + 1
      ) %>% 
      mutate(
        expand_x_min = round(expand_x_min*k),
        expand_y_min = round(expand_y_min*k),
        expand_x_max = expand_x_min + lim_r,
        expand_y_max = expand_y_min + lim_r
      ) %>% 
      mutate(
        rows = y_max - y_min + 1,
        cols = x_max - x_min + 1
      ) %>% 
      as.data.table()
    
    # Get only select variables (for faster loops)
    SplitTempTable <-
      TempTable %>% 
      select(
        t,
        x_min, x_max, y_min, y_max,
        expand_x_min, expand_x_max, expand_y_min, expand_y_max,
        rows, cols
      ) %>% 
      arrange(
        t
      ) %>% 
      mutate(
        SpotID = 1:n()
      ) %>% 
      as_tibble() %>% 
      group_split(
        t
      )
    # Make it a table
    SplitTempTable <- lapply(SplitTempTable, as.data.table)
    
    # Pull intensities from circle
    Intensities <- mapply(IntensityFx, SplitTempTable, img_frames, circle_mask_list, k, k2_r)#, mc.cores = detectCores(logical = F))
    # Merge spots
    Intensities <- lapply(1:NCOL(Intensities), MatrixToTable, Intensities)
    Intensities <- rbindlist(Intensities)
    
    # Remove unnecessary columns
    TempTable <-
      TempTable %>% 
      select(-c(
        x, y, t,
        x_min, x_max, y_min, y_max, test,
        expand_x_min, expand_x_max, expand_y_min, expand_y_max,
        rows, cols
      )) %>% 
      as.data.frame()
    # Add intensities
    TempTable$TOTAL_INTENSITY = Intensities$Intensity
    # Get puncta coordinates
    TempTable <-
      TempTable %>% 
      group_by(
        UNIVERSAL_SPOT_ID
      ) %>% 
      mutate(
        POSITION_X = as.numeric(POSITION_X),
        POSITION_Y = as.numeric(POSITION_Y)
      ) %>% 
      mutate(
        ABSOLUTE_POSITION_X = CELL_POSITION_X + POSITION_X,
        ABSOLUTE_POSITION_Y = CELL_POSITION_Y + POSITION_Y
      ) %>% 
      mutate(
        ABSOLUTE_POSITION_X = ABSOLUTE_POSITION_X*CALIBRATION_UM,
        ABSOLUTE_POSITION_Y = ABSOLUTE_POSITION_Y*CALIBRATION_UM
      ) %>% 
      as.data.frame()
    
    # Save
    save_path <- paste0(temp_file_list$protein_path, "_intensity.csv.gz")
    suppressWarnings({
      file.remove(save_path, showWarnings = FALSE)
    })
    data.table::fwrite(TempTable, save_path, row.names = F, na = "")
    
    # Show progress
    Progress = NROW(image_list)/10
    Progress = round(Progress)
    if(Progress==0){
      Progress = 1
    }
    
    if(FileX %% Progress == 0){
      Progress = FileX/NROW(image_list)
      Progress = Progress*100
      Progress = round(Progress)
      Progress = paste0("     ", Progress, "% complete")
      print(Progress)
    }
    
    return(save_path)
  }, error = function(e){print(paste("ERROR with ExtractFx FileX =", FileX))})
}
ResultsPath <- mclapply(1:NROW(image_list), ExtractFx, mc.cores = detectCores(logical = F))
ResultsPath <- unlist(ResultsPath)

# Get images path
ImagePath <- dirname(dirname(ResultsPath))
ImagePath <- unique(ImagePath)
# Get cohort names
Cohorts <- basename(dirname(ImagePath))
Cohorts <- file.path(extraction_path, Cohorts)
Cohorts <- unique(Cohorts)
# Create re-extraction path if it doesn't exist
if(!file.exists(extraction_path)){
  dir.create(extraction_path)
}
# Create cohort path if it doesn't exist
for(Cohort in Cohorts){
  if(!file.exists(Cohort)){
    dir.create(Cohort)
  }
}

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
  if(NROW(list.files(Cohort)) == 0){
    unlink(Cohort, recursive = TRUE)
  }
}

# Delete processing folder if empty
ProcessingFolder = dirname(OldCohorts[1])
if(NROW(list.files(ProcessingFolder)) == 0){
  unlink(ProcessingFolder, recursive = TRUE)
}

print('extract_intensity.R is now complete')

Sys.sleep(5)
