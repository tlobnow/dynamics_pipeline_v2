#!/usr/bin/env Rscript
args = commandArgs(trailingOnly=TRUE)
parameters_path = args[1]
unlink(".RData")

##############
# User Input #
##############

# ADD when it was last analyzed

# Ending of files
# parameters_path = "/raven/u/deliz/new_pipeline/pending_processing/20200502/Input/parameter_tables"
intensity_ending = "_intensity.csv.gz"
colocalization_intensity_file = "colocalization.csv.gz"

if("pacman" %in% rownames(installed.packages()) == FALSE)
{install.packages("pacman")}

pacman::p_load(dplyr, stringr, parallel, tidyr, data.table, ff, dtplyr, compiler, RANN)
setDTthreads(parallel::detectCores(logical = F))
enableJIT(3)

# Get directories
directories_list = file.path(parameters_path, "directories.csv")
directories_list = fread(directories_list)
input_path = directories_list$path[directories_list$contains == "input"]
processing_path = directories_list$path[directories_list$contains == "processing"]
colocalization_path = file.path(processing_path, "06_Colocalization")
output_path = directories_list$path[directories_list$contains == "output"]
summary_path = file.path(input_path, "summary.csv")
# Get image list
file_list = fread(summary_path)

# Convert exposure units
ConvertUnits <- function(x){
  # Create array
  y = rep(NA, NROW(x))
  # Loop over x
  for(i in 1:NROW(x)){
    if(x[i] == "ms"){
      y[i] = 10^-3
    } else if(x[i] == "s"){
      y[i] = 1
    } else{
      y[i] = 1
    }
  }
  return(y)
}
# Prep up
file_list <-
  file_list %>% 
  mutate(
    image = dirname(dirname(protein_relative_path)),
    exposure_units = word(exposure, -1),
    exposure_measurement = as.numeric(word(exposure, 1)),
    direction = direction*pi/180,
    angle = angle*pi/180
  ) %>% 
  mutate(
    exposure = exposure_measurement*ConvertUnits(exposure_units),
    image = basename(image),
    date = substr(image, 0, 8)
  ) %>% 
  mutate(
    date =  as.Date(date, format = '%Y%m%d'),
  ) %>% 
  select(-c(
    exposure_units, exposure_measurement
  )) %>% 
  as.data.table()

# Separate calibrations and the rest
calibration_list = file_list[file_list$cohort=="Calibrations",]
Path <- calibration_list$protein_relative_path
Path <- dirname(Path)
Path <- file.path(colocalization_path, Path)
Path <- file.exists(Path)
calibration_list <- calibration_list[Path]

# Analyze calibrations
QuantifyCalibration <- function(FileX){
  # Get calibration image metadata
  temp_calibration_list = calibration_list[FileX]
  # Pull table
  Table <- file.path(colocalization_path, paste0(temp_calibration_list$protein_relative_path, intensity_ending))
  Table <- fread(Table)
  
  Table <-
    Table %>% 
    summarize(
      SD = mad(TOTAL_INTENSITY),
      SEM = mad(TOTAL_INTENSITY)/sqrt(n()),
      TOTAL_INTENSITY = median(TOTAL_INTENSITY),
      N = n()
    ) %>% 
    as.data.table()
  
  temp_calibration_list <- bind_cols(temp_calibration_list, Table)
  
  save_path = paste0(temp_calibration_list$protein_name, "_calibration.csv.gz")
  save_path = file.path(colocalization_path, dirname(dirname(temp_calibration_list$protein_relative_path)), save_path)
  # Remove old if it exists
  suppressWarnings({
    file.remove(save_path, showWarnings = FALSE)
  })
  data.table::fwrite(temp_calibration_list, save_path, row.names = F, na = "")
  
  return(temp_calibration_list)
}
calibration_list <- mclapply(1:NROW(calibration_list), QuantifyCalibration, mc.cores = detectCores(logical = F))
calibration_list <- rbindlist(calibration_list)

image_list = file_list[file_list$cohort!="Calibrations",]
Path <- image_list$protein_relative_path
Path <- dirname(Path)
Path <- file.path(colocalization_path, Path)
Path <- file.exists(Path)
image_list <- image_list[Path]

# Pairing
GetCalibrationImages <- function(ImageX){
  tryCatch({
    
    # Get image data
    temp_image_list = image_list[ImageX]
    temp_image_list$cell_path = dirname(temp_image_list$protein_relative_path)
    
    temp_calibration_list <-
      calibration_list %>% 
      # Get the correct channel
      filter(
        channel == temp_image_list$channel
      ) %>% 
      as.data.table()
    
    if(NROW(temp_calibration_list)>0){
      
      temp_calibration_list <-
        temp_calibration_list %>% 
        # Get the nearest power
        mutate(
          power_test = abs(power - temp_image_list$power)
        ) %>% 
        filter(
          power_test == min(power_test)
        ) %>% 
        # Get the nearest exposure
        mutate(
          exposure_test = abs(exposure - temp_image_list$exposure)
        ) %>% 
        filter(
          exposure_test == min(exposure_test)
        ) %>% 
        # Get the nearest direction
        mutate(
          direction_test = abs(direction - temp_image_list$direction)
        ) %>% 
        filter(
          direction_test == min(direction_test)
        ) %>% 
        # Get the nearest angle
        mutate(
          angle_test = abs(angle - temp_image_list$angle)
        ) %>% 
        filter(
          direction_test == min(direction_test)
        ) %>% 
        # Get the nearest date
        mutate(
          date_test = abs(date - temp_image_list$date)
        ) %>% 
        filter(
          date_test == min(date_test)
        ) %>% 
        # Lowest SEM
        filter(
          SEM == min(SEM)
        ) %>% 
        as.data.table()
      
      CalibrationImage = temp_calibration_list$image[1]
      CalibrationProtein = temp_calibration_list$protein_name[1]
      CalibrationIntensity = temp_calibration_list$TOTAL_INTENSITY[1]
      CalibrationError = temp_calibration_list$SD[1]
    } else{
      CalibrationImage = NA
      CalibrationProtein = temp_image_list$channel
      CalibrationIntensity = 1
      CalibrationError = NA
    }
    # Create export table
    ExportTable <- temp_image_list
    names(ExportTable) <- toupper(names(ExportTable))
    ExportTable$CALIBRATION_IMAGE = CalibrationImage
    ExportTable$FLUOROPHORE = CalibrationProtein
    ExportTable$CALIBRATION_TOTAL_INTENSITY = CalibrationIntensity
    ExportTable$CALIBRATION_STANDARD_DEVIATION = CalibrationError
    
    save_path = paste0(CalibrationProtein, "_calibration.csv.gz")
    save_path = file.path(colocalization_path, dirname(dirname(temp_image_list$protein_relative_path)), save_path)
    # Remove old if it exists
    suppressWarnings({
      file.remove(save_path, showWarnings = FALSE)
    })
    data.table::fwrite(temp_calibration_list, save_path, row.names = F, na = "")
    
    return(ExportTable)
  }, error = function(e){print(paste("ERROR with MoveNoColocalizationNeededFx ImageX =", ImageX))})
}
PairedList <- mclapply(1:NROW(image_list), GetCalibrationImages, mc.cores = detectCores(logical = F))
PairedList <- rbindlist(PairedList, fill = TRUE, use.names = TRUE)
PairedList <- PairedList %>% distinct() %>% as.data.table()

ANALYSIS_TIME_STAMP = Sys.time()
ANALYSIS_TIME_STAMP = as.POSIXlt(ANALYSIS_TIME_STAMP, tz = "UTC")
ANALYSIS_TIME_STAMP = as.character(ANALYSIS_TIME_STAMP)

Cells <- unique(PairedList$CELL_PATH)
CombineCellTables <- function(CellX){
  tryCatch({
    
    print(paste("CombineCellTables - CellX =", CellX))
    
    # Get tables
    CellPairedCalibrations <-
      PairedList %>%
      filter(
        CELL_PATH == Cells[CellX]
      ) %>% 
      mutate(
        PROTEIN = PROTEIN_NAME 
      ) %>% 
      select(
        PROTEIN,
        CALIBRATION_IMAGE,
        CALIBRATION_TOTAL_INTENSITY,
        CALIBRATION_STANDARD_DEVIATION
      ) %>% 
      as.data.table()
    
    # Get cell path
    CellPath <- file.path(colocalization_path, Cells[CellX])
    
    # Read tables
    IntensityTables <- paste0(CellPairedCalibrations$PROTEIN, intensity_ending)
    IntensityTables <- file.path(CellPath, IntensityTables)
    IntensityTables <- IntensityTables[file.exists(IntensityTables)]
    IntensityTables <- lapply(IntensityTables, fread)
    IntensityTables <- rbindlist(IntensityTables, fill = TRUE, use.names = TRUE)
    # Add calibration data
    IntensityTables <- merge(IntensityTables, CellPairedCalibrations, by = "PROTEIN", all = TRUE)
    
    # Normalize
    IntensityTables$NORMALIZED_INTENSITY = IntensityTables$TOTAL_INTENSITY/IntensityTables$CALIBRATION_TOTAL_INTENSITY
    
    # Get colocalization data
    ColocalizationTablePath <- file.path(CellPath, colocalization_intensity_file)
    # Run if it exists
    if(file.exists(ColocalizationTablePath)){
      # Read table
      ColocalizationTable <- fread(ColocalizationTablePath)
      # Normalize signal
      ## Get normalized intensities
      SelectIntensityTables <-
        IntensityTables %>% 
        mutate(
          COMPLEMENTARY_UNIVERSAL_SPOT_ID = UNIVERSAL_SPOT_ID,
          COMPLEMENTARY_NORMALIZED_INTENSITY = NORMALIZED_INTENSITY
        ) %>% 
        select(
          COMPLEMENTARY_UNIVERSAL_SPOT_ID,
          COMPLEMENTARY_NORMALIZED_INTENSITY
        ) %>% 
        as.data.table()
      ## Add to table
      ColocalizationTable <-
        merge(ColocalizationTable, SelectIntensityTables, by = "COMPLEMENTARY_UNIVERSAL_SPOT_ID")
      
      ColocalizationTable <-
        ColocalizationTable %>% 
        pivot_wider(
          names_from = PROTEIN_ID,
          id_cols = c(UNIVERSAL_SPOT_ID),
          values_from = c(COMPLEMENTARY_PROTEIN, COMPLEMENTARY_TOTAL_INTENSITY, COMPLEMENTARY_NORMALIZED_INTENSITY, COMPLEMENTARY_UNIVERSAL_SPOT_ID)
        ) %>%
        as.data.table()
      
      IntensityTables <- merge(IntensityTables, ColocalizationTable, by = "UNIVERSAL_SPOT_ID")
    }
    
    # Determine nearest neighbor to spot of the same protein
    NearestNeighborTable <-
      IntensityTables %>% 
      filter(
        !is.na(POSITION_X)
      ) %>% 
      group_by(
        PROTEIN,
        FRAME
      ) %>% 
      mutate(
        N = n()
      ) %>% 
      filter(
        N > 1
      ) %>% 
      select(
        PROTEIN,
        FRAME,
        PUNCTA_DIAMETER,
        UNIVERSAL_SPOT_ID,
        POSITION_X,
        POSITION_Y
      ) %>% 
      ungroup() %>% 
      as_tibble() %>% 
      group_split(
        PROTEIN,
        FRAME
      )
    # Nearest neighbor971
    RADIUS <- max(IntensityTables$PUNCTA_DIAMETER, na.rm = T) * 3
    NearestNeighborSearch <- function(ProteinFrameX){
      # Get nearest spot
      CoordiantesTable <- ProteinFrameX %>% select(POSITION_X, POSITION_Y)
      DistanceTable <- RANN::nn2(CoordiantesTable, k = 2)
      DistanceTable <- DistanceTable$nn.dists[,2]
      # Get number of spots nearby
      ClusterTable <- RANN::nn2(CoordiantesTable, searchtype = c("radius"), radius = RADIUS, k = NROW(ProteinFrameX))
      ClusterTable <- ClusterTable$nn.dists
      ClusterTable <- ClusterTable > 0 & ClusterTable <  1e+153 
      ClusterTable <- rowSums(ClusterTable)
      # Put results together
      DistanceResults <- ProteinFrameX %>% select(UNIVERSAL_SPOT_ID)
      DistanceResults$NEAREST_SPOT <- DistanceTable
      DistanceResults$SPOTS_WITHIN_RADIUS = ClusterTable
      DistanceResults$SPOT_RADIUS_LIMIT = RADIUS
      return(DistanceResults)
    }
    NeighborResults <- lapply(NearestNeighborTable, NearestNeighborSearch)
    if(NROW(NeighborResults) != 0){
      NeighborResults <- NeighborResults[(which(sapply(NeighborResults,is.list), arr.ind=TRUE))]
      NeighborResults <- rbindlist(NeighborResults, fill = TRUE, use.names = TRUE)
      IntensityTables <- as.data.frame(IntensityTables)
      NeighborResults <- as.data.frame(NeighborResults)
      IntensityTables <- merge(IntensityTables, NeighborResults, by = "UNIVERSAL_SPOT_ID", all = TRUE)
      
      # Add missing values
      MissingIndex <- which(is.na(IntensityTables$NEAREST_SPOT))
      IntensityTables$NEAREST_SPOT[MissingIndex] <- Inf
      MissingIndex <- which(is.na(IntensityTables$SPOTS_WITHIN_RADIUS))
      IntensityTables$SPOTS_WITHIN_RADIUS[MissingIndex] <- 0
      MissingIndex <- which(is.na(IntensityTables$SPOT_RADIUS_LIMIT))
      IntensityTables$SPOT_RADIUS_LIMIT[MissingIndex] <- RADIUS
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
      IntensityTables <-
        IntensityTables %>% 
        mutate(
          TIME = FRAME*FRAME_RATE
        )
    }
    IntensityTables$TIME = IntensityTables$TIME - min(IntensityTables$TIME)
    LANDING_TIME = min(IntensityTables$TIME)
    # Calculate basic parameters and save
    IntensityTables <- as.data.table(IntensityTables)
    IntensityTables[, MIN_X := min(POSITION_X/CALIBRATION_UM), by = UNIVERSAL_TRACK_ID]
    IntensityTables[, MIN_X := MIN_X > PUNCTA_DIAMETER*2]
    IntensityTables <- IntensityTables[IntensityTables$MIN_X]
    IntensityTables$MIN_X <- NULL
    
    IntensityTables[, MAX_X := max(ABSOLUTE_POSITION_X/CALIBRATION_UM), by = UNIVERSAL_TRACK_ID]
    IntensityTables[, MAX_X := MAX_X < WIDTH - PUNCTA_DIAMETER*2]
    IntensityTables <- IntensityTables[IntensityTables$MAX_X]
    IntensityTables$MAX_X <- NULL
    
    IntensityTables[, MIN_Y := min(POSITION_Y/CALIBRATION_UM), by = UNIVERSAL_TRACK_ID]
    IntensityTables[, MIN_Y := MIN_Y > PUNCTA_DIAMETER*2]
    IntensityTables <- IntensityTables[IntensityTables$MIN_Y]
    IntensityTables$MIN_Y <- NULL
    
    IntensityTables[, MAX_Y := max(ABSOLUTE_POSITION_Y/CALIBRATION_UM), by = UNIVERSAL_TRACK_ID]
    IntensityTables[, MAX_Y := MAX_Y < HEIGHT - PUNCTA_DIAMETER*2]
    IntensityTables <- IntensityTables[IntensityTables$MAX_Y]
    IntensityTables$MAX_Y <- NULL
    
    # If infinite distance, put NA
    IntensityTables$NEAREST_SPOT[is.infinite(IntensityTables$NEAREST_SPOT)] = NA
    
    IntensityTables <-
      IntensityTables %>% 
      group_by(
        UNIVERSAL_TRACK_ID
      ) %>% 
      mutate(
        # Ligand density every 0.5 steps using log base 10
        LIGAND_DENSITY_CAT =
          # Round to nearest half log
          round(
            # Classifies ligands based on log using base 3.162 (10^.5)
            log(
              LIGAND_DENSITY,
              base = (10^.5)),
            digits = 0
          ) * 0.5
      ) %>% 
      mutate(
        # Convert back to linear
        LIGAND_DENSITY_CAT = signif(10^LIGAND_DENSITY_CAT, 2),
        # Get frame number
        FRAMES_ADJUSTED = FRAME - min(FRAME),
        # Time adjusted
        TIME_ADJUSTED = TIME - min(TIME),
        # Get puncta lifetime
        LIFETIME = max(TIME) - min(TIME),
        # Time since first spot
        TIME_SINCE_LANDING = TIME - LANDING_TIME,
        FRAMES_SINCE_LANDING = FRAME - LANDING_FRAME,
        # Max total intensity of track
        MAX_NORMALIZED_INTENSITY = max(NORMALIZED_INTENSITY, na.rm = TRUE),
        # To be used later for overall delta and for categorizing de-novo and disassembling
        STARTING_NORMALIZED_INTENSITY = NORMALIZED_INTENSITY[1],
      ) %>% 
      mutate(
        # Overall change in intensity from start to max
        START_TO_MAX_INTENSITY = MAX_NORMALIZED_INTENSITY - STARTING_NORMALIZED_INTENSITY,
      ) %>% 
      as.data.table()
      
      CellData <-
        IntensityTables %>% 
        select(
          one_of(
            "RELATIVE_PATH",
            
            "LIGAND",
            "LIGAND_DENSITY",
            
            "CHANNEL",
            "POWER",
            "EXCITATION",
            "EMMISION",
            "EXPOSURE",
            "ANGLE",
            "DIRECTION",
            "FOCUS",
            "OBJECTIVE",
            
            "WIDTH",
            "HEIGHT",
            "CALIBRATION_UM",
            
            "CELL_DIAMETER",
            "PUNCTA_DIAMETER",
            
            "SEGMENT_WITH",
            
            "TRACKMATE_THRESHOLD",
            "TRACKMATE_FRAME_GAP",
            "TRACKMATE_GAP_LINK_DISTANCE",
            "TRACKMATE_MAX_LINK_DISTANCE",
            
            "SPOT_RADIUS_LIMIT",

            "CELL_POSITION_X",
            "CELL_POSITION_Y",
            
            "TIME_START",
            "FRAME_RATE",
            
            "CALIBRATION_IMAGE",
            "CALIBRATION_TOTAL_INTENSITY",
            "CALIBRATION_STANDARD_DEVIATION"
          )
        ) %>% 
        distinct() %>% 
        as.data.table()
      
      # Write file
      DestinationPath <- file.path(CellPath, "Parameters.csv.gz")
      file.remove(DestinationPath, showWarnings = F)
      fwrite(CellData, DestinationPath, row.names = F, na = "")
      remove(CellData)
      
      Parameterless <-
        IntensityTables %>% 
        select(
          !one_of(
            "LIGAND",
            "LIGAND_DENSITY",
            
            "CHANNEL",
            "POWER",
            "EXCITATION",
            "EMMISION",
            "EXPOSURE",
            "ANGLE",
            "DIRECTION",
            "FOCUS",
            "OBJECTIVE",
            
            "WIDTH",
            "HEIGHT",
            "CALIBRATION_UM",
            
            "CELL_DIAMETER",
            "PUNCTA_DIAMETER",
            
            "SEGMENT_WITH",
            
            "TRACKMATE_THRESHOLD",
            "TRACKMATE_FRAME_GAP",
            "TRACKMATE_GAP_LINK_DISTANCE",
            "TRACKMATE_MAX_LINK_DISTANCE",
            
            "SPOT_RADIUS_LIMIT",
            
            "CELL_POSITION_X",
            "CELL_POSITION_Y",
            
            "TIME_START",
            "FRAME_RATE",
            
            "CALIBRATION_IMAGE",
            "CALIBRATION_TOTAL_INTENSITY",
            "CALIBRATION_STANDARD_DEVIATION"
          )
        ) %>% 
        as.data.table()
      
      # Write file
      DestinationPath <- file.path(CellPath, "Analysis.csv.gz")
      file.remove(DestinationPath, showWarnings = F)
      fwrite(Parameterless, DestinationPath, row.names = F, na = "")
      remove(Parameterless)
      
      # Get names of colocalization
      if(NROW(unique(IntensityTables$PROTEIN)) < 2){
        ColocalizationNames = "ColocalizationNames"
      } else{
        ColocalizationNames <- names(IntensityTables)
        ColocalizationNames <- ColocalizationNames[grep("COMPLEMENTARY", ColocalizationNames)]
      }

      Essential <-
        IntensityTables %>% 
        select(
          one_of(
            c(
              "RELATIVE_PATH",
              "PROTEIN",
              "COHORT",
              "LIGAND_DENSITY_CAT",
              "IMAGE",
              "CELL",
              "UNIVERSAL_TRACK_ID",
              "UNIVERSAL_SPOT_ID",
              
              "FRAME",
              "TIME",
              "FRAMES_ADJUSTED",
              "TIME_ADJUSTED",
              "TIME_SINCE_LANDING",
              "FRAMES_SINCE_LANDING",
              "LIFETIME",
              
              "NORMALIZED_INTENSITY",
              "STARTING_NORMALIZED_INTENSITY",
              "MAX_NORMALIZED_INTENSITY",
              "START_TO_MAX_INTENSITY",

              "CELL_AREA",
              "ABSOLUTE_POSITION_X",
              "ABSOLUTE_POSITION_Y",
              
              "NEAREST_SPOT",
              "SPOTS_WITHIN_RADIUS",

              ColocalizationNames
            )
          )
        ) %>% 
        mutate(
          ANALYSIS_TIME_STAMP = ANALYSIS_TIME_STAMP
        ) %>% 
        as.data.table()
      
      # Write file
      DestinationPath <- file.path(CellPath, "Essential.csv.gz")
      file.remove(DestinationPath, showWarnings = F)
      fwrite(Essential, DestinationPath, row.names = F, na = "")
      
      Progress = NROW(Cells)/10
      Progress = round(Progress)
      if(Progress==0){
        Progress = 1
      }
      
      if(CellX %% Progress == 0){
        Progress = CellX/NROW(Cells)
        Progress = Progress*100
        Progress = round(Progress)
        Progress = paste0("     ", Progress, "% complete")
        print(Progress)
      }
      
      return(CellPath)
  }, error = function(e){print(paste("ERROR with CombineCellTables CellX =", CellX))})
}
CellAnalysis <- mclapply(1:NROW(Cells), CombineCellTables, mc.cores = detectCores(logical = F))
CellAnalysis <- unlist(CellAnalysis)
CellAnalysis <- CellAnalysis[file.exists(CellAnalysis)]

# Combine all cell tables
Images <- dirname(CellAnalysis)
Images <- unique(Images)

# Tables to merge
Outputs <- c("Parameters.csv.gz", "Analysis.csv.gz", "Essential.csv.gz")

nImages <- NROW(Images)
CombineImageTables <- function(ImageX){
  tryCatch({
    print(paste("ImageX =", ImageX, "of", nImages))
    # Get cell table paths
    CellsList <- CellAnalysis[dirname(CellAnalysis) == Images[ImageX]]
    # Function to combine tables
    TableByOutput <- function(OutputX){
      print(paste("Combining", basename(Images[ImageX]), "-", OutputX))
      # Get path
      Path <- file.path(CellsList, OutputX)
      Path <- Path[file.exists(Path)]
      # Pull tables
      Table <- lapply(Path, fread)
      Table <- rbindlist(Table, fill = TRUE, use.names = TRUE)
      # Save
      DestinationPath <- file.path(Images[ImageX], OutputX)
      file.remove(DestinationPath, showWarnings = F)
      fwrite(Table, DestinationPath, row.names = F, na = "")
      if(OutputX =="Essential.csv.gz"){
        return(DestinationPath)
      }
    }
    CellsList <- lapply(Outputs, TableByOutput)
    
    Progress = NROW(Images)/10
    Progress = round(Progress)
    if(Progress==0){
      Progress = 1
    }
      
    if(ImageX %% Progress == 0){
      Progress = ImageX/NROW(Images)
      Progress = Progress*100
      Progress = round(Progress)
      Progress = paste0("     ", Progress, "% complete")
      print(Progress)
    }
    
    return(Images[ImageX])
  }, error = function(e){print(paste("ERROR with CombineImageTables ImageX =", ImageX))})
}
ProcessedImages <- lapply(1:nImages, CombineImageTables)
ProcessedImages <- unlist(ProcessedImages)

# special_fread <- function(x){
#   print(x)
#   file.remove(file.path(dirname(x), "Essential.csv.tmp"))
#   file.remove(file.path(dirname(x), "Essential.csv"))
#   gunzip(x, remove = FALSE)
#   Table <- fread(file.path(dirname(x), "Essential.csv"), fill=TRUE)
#   file.remove(file.path(dirname(x), "Essential.csv"))
#   return(Table)
# }

GrandTable <- function(OutputX){
  # Status output
  print(paste("Working on", OutputX))
  # Get table paths
  Paths <- file.path(ProcessedImages, OutputX)
  
  # Read tables
  Tables <- lapply(Paths, fread)
  # Merge tables
  Tables <- rbindlist(Tables, fill = TRUE, use.names = TRUE)
  # Save tables
  save_name <- file.path(output_path, OutputX)
  fwrite(Tables, save_name)
  
  return(save_name)
}
lapply(Outputs, GrandTable)

# Add calibration images to move
CalibrationImages <- file.path(colocalization_path, dirname(dirname(calibration_list$protein_relative_path)))
AllProcessedImages <- c(ProcessedImages, CalibrationImages)

# Move processed images
for(Image in AllProcessedImages){
  old_path = Image
  Cohort = basename(dirname(Image))
  dir.create(file.path(output_path, Cohort))
  Image = basename(Image)
  new_path = file.path(output_path, Cohort, Image)
  file.move(old_path, new_path)
}

# Delete cohort if empty
OldCohorts = unique(dirname(AllProcessedImages))
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

print('combine_tables.R is now complete')

Sys.sleep(5)
