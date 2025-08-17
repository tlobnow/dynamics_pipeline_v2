#!/usr/bin/env Rscript
args = commandArgs(trailingOnly=TRUE)

parameters_path = args[1]

library(ggplot2)
library(dplyr)
library(ggdark)
library(parallel)
library(XML)
library(fitdistrplus)
library(data.table)
library(scales)
library(ff)
library(stringr)

select <- dplyr::select

# parameters_path = '/Users/u_deliz/Desktop/NewPipeline/Input/parameter_tables'
# Get paths
ligand_path = file.path(parameters_path, "directories.csv")
ligand_path = fread(ligand_path)
output_path =  ligand_path$path[which(ligand_path$contains=="output")]
ligand_path = ligand_path$path[which(ligand_path$contains=="processing")]
ligand_path = file.path(ligand_path, "00_Ligand")

# Output
output_path <- file.path(output_path, "Ligand")
if(!file.exists(output_path)){
  dir.create(output_path)
}

# Import table
LigandList <- file.path(parameters_path, "ligand.csv")
LigandList <- fread(LigandList)

GetDensityFx <- function(ImageX){
  tryCatch({
    # Get paths
    FolderName <- tools::file_path_sans_ext(LigandList$image[ImageX])
    DataPath <- file.path(ligand_path, FolderName)
    MetadataTable <- file.path(DataPath, "metadata.csv")
    XMLTable <- paste0(LigandList$protein_name[ImageX], ".xml")
    XMLTable <- file.path(DataPath, XMLTable)
    
    # Get variables
    DILUTION_FACTOR = LigandList$dilution[ImageX]
    
    MetadataTable <- fread(MetadataTable)
    
    PIXEL_SIZE = which(MetadataTable$parameter=="calibration_um")
    PIXEL_SIZE = MetadataTable$value[PIXEL_SIZE]
    PIXEL_SIZE = as.numeric(PIXEL_SIZE)
    
    X_SIZE = which(MetadataTable$parameter=="width")
    X_SIZE = MetadataTable$value[X_SIZE]
    X_SIZE = as.numeric(X_SIZE)
    X_SIZE = X_SIZE*PIXEL_SIZE
    
    Y_SIZE = which(MetadataTable$parameter=="height")
    Y_SIZE = MetadataTable$value[Y_SIZE]
    Y_SIZE = as.numeric(Y_SIZE)
    Y_SIZE = Y_SIZE*PIXEL_SIZE
    
    # Get XML
    xml_data <- xmlParse(XMLTable)
    xml_data <- xmlToList(xml_data)
    
    # Get spot data
    Spots <- xml_data$Model$AllSpots
    SpotsFx <- function(SpotX) {
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
    SpotsTable <- mclapply(1:NROW(Spots), SpotsFx, mc.cores = detectCores(logical = F))
    SpotsTable <- SpotsTable[(which(sapply(SpotsTable,is.list), arr.ind=TRUE))]
    SpotsTable <- data.table::rbindlist(SpotsTable)
    
    # Get number of spots per frame
    LigandTable <-
      SpotsTable %>% 
      group_by(
        FRAME
      ) %>% 
      summarize(
        N = n()
      ) %>% 
      mutate(
        FRAME = as.numeric(FRAME),
        FRAME = FRAME + 1
      )
    
    # Get upper boundary
    UpperLimitFx <- function(FrameX){
      
      LigandTable <-
        LigandTable %>%
        filter(
          FRAME <= FrameX
        )
      
      R2 = cor(LigandTable$N, LigandTable$FRAME)
      R2 = as_tibble(R2)
      return(R2)
    }
    MAX_FRAME = max(LigandTable$FRAME)
    Results <- mclapply(25:MAX_FRAME, UpperLimitFx)
    Results <- rbindlist(Results)
    # Get min R
    R2 = min(Results)
    ROW = which(Results$value == R2)
    UPPER_FRAME_LIMIT = ROW + 25
    # 
    # LowerLimitFx <- function(FrameX){
    #   
    #   LigandTable <-
    #     LigandTable %>%
    #     filter(
    #       FRAME <= UPPER_FRAME_LIMIT,
    #       FRAME >= FrameX
    #     )
    #   
    #   R2 = cor(LigandTable$N, LigandTable$FRAME)
    #   R2 = as_tibble(R2)
    #   return(R2)
    # }
    # Results <- mclapply(1:(UPPER_FRAME_LIMIT-1), LowerLimitFx)
    # Results <- rbindlist(Results)
    # # Get min R
    # R2 = min(Results)
    # LOWER_FRAME_LIMIT = which(Results$value == R2)
    
    # Redefine ligand density
    LigandTable <-
      LigandTable %>% 
      filter(
        # FRAME >= LOWER_FRAME_LIMIT,
        FRAME <= UPPER_FRAME_LIMIT
      )
    
    # Get density
    fit <- lm(log(N) ~ FRAME, data = LigandTable)
    INTERCEPT <- fit$coefficients[1]
    INTERCEPT <- exp(INTERCEPT)
    LIGAND_DENSITY =  as.numeric(INTERCEPT)*DILUTION_FACTOR/X_SIZE/Y_SIZE
    
    # Draw fit line
    FRAMES <- LigandTable$FRAME
    N <- exp(predict(fit,list(FRAME=FRAMES)))
    FittedLigandTable <- as.data.frame(N)
    FittedLigandTable$FRAME <- FRAMES
    
    # Plot
    ggplot() +
      geom_path(
        data = FittedLigandTable,
        aes(
          x = FRAME,
          y = N
        ),
        color ="red"
      ) +
      geom_point(
        data = LigandTable,
        aes(
          x = FRAME,
          y = N
        )
      ) +
      scale_y_continuous(
        # Log transform axis. The secondary axis reinforces that it's in log as it'll say 2^x
        trans = "log2",
        sec.axis = sec_axis(
          trans = ~.,
          breaks = trans_breaks("log2", function(x) 2^x),
          labels = trans_format("log2", math_format(2^.x))
        )
      ) +
      dark_theme_classic() +
      labs(
        x = "Frame",
        y = "Spots",
        title = paste(round(INTERCEPT),"molecules, R =", round(R2, 2), "\nLigand Density =", round(LIGAND_DENSITY, 2), "mol µm^-2")
      )
    
      ggsave(
        file.path(DataPath, "Fit.pdf"),
        height = 3,
        width = 4
      )
    
    # Revert ggdark
    ggdark::invert_geom_defaults()
    
    # Create output table
    OutputTable <- NULL
    OutputTable$DATE = substr(FolderName, 0, 8)
    OutputTable$IMAGE = FolderName
    OutputTable$LIGAND_DENSITY = LIGAND_DENSITY
    
    OutputTable$LIGAND = LigandList$ligand[ImageX]
    OutputTable$DILUTION = LigandList$dilution[ImageX]
    OutputTable$PROTEIN_NAME = LigandList$protein_name[ImageX]
    
    OutputTable$MOLECULES = as.numeric(INTERCEPT)
    OutputTable$R2 = R2
    OutputTable$UPPER_FRAME_LIMIT = UPPER_FRAME_LIMIT
    # OutputTable$LOWER_FRAME_LIMIT = LOWER_FRAME_LIMIT
    
    
    # Save it to csv
    OutputTable <- as_tibble(OutputTable)
    OutputTable <- OutputTable[NROW(OutputTable),]
    write.csv(OutputTable, file.path(DataPath, "ligand_density.csv"), row.names = F)
    return(OutputTable)
    
  }, error = function(e){print(paste("ERROR with GetDensityFx ImageX =", ImageX))})
}
Results <- mclapply(1:NROW(LigandList), GetDensityFx)
Results <- Results[(which(sapply(Results,is.list), arr.ind=TRUE))]
Results <- rbindlist(Results, fill = TRUE)

# Conversion table for getting concentration
# Lookup table
Conversion <- NULL
Conversion$Factor <- c(
  10^(3*(-6:-1)),
  10^2,
  10^-1,
  10^0,
  10^1,
  10^2,
  10^(3*(1:6))
)
Conversion$PrefixSymbol <- c(
  "a", "f", "p", "n", "u","m","c", "d","",
  "da", "h", "k", "M", "G", "T", "P", "E"
)
Conversion$PrefixSymbol <- paste0(Conversion$PrefixSymbol, "M")
Conversion <- as_tibble(Conversion)
# Conversion function
ConvertFx <- function(ValueAndUnit){
  ConvertOneFx <- function(i){
    if(!is.na(i)){
      Value <- word(i, 1)
      Value <- as.numeric(Value)
      Unit <- word(i, 2)
      Factor <- Conversion$Factor[which(Unit == Conversion$PrefixSymbol)]
      Value <- Value*Factor
    } else{
      Value = 0
    }
    return(Value)
  }
  ConversionResults <- lapply(ValueAndUnit, ConvertOneFx)
  ConversionResults <- unlist(ConversionResults)
  return(ConversionResults)
}
LigandNamesFx <- function(LigandNames){
  LigandNameFx <- function(LigandName){
    WordCount <- sapply(strsplit(LigandName, " "), length)
    if(WordCount > 2){
      Words <- word(LigandName, 3:WordCount)
      Words <- paste(Words, collapse = " ")
    } else{
      Words = ""
    }
    return(Words)
  }
  WordResults <- lapply(LigandNames, LigandNameFx)
  WordResults <- unlist(WordResults)
  return(WordResults)
}

# Summarize
Summary <-
  Results %>% 
  mutate(
    PROTEIN = PROTEIN_NAME,
    CONCENTRATION_nM = ConvertFx(LIGAND)/10^-9,
    LIGAND_NAME = LigandNamesFx(LIGAND),
    DATE =  as.Date(DATE, format = '%Y%m%d')
  ) %>% 
  group_by(
    DATE,
    LIGAND,
    PROTEIN,
    CONCENTRATION_nM,
    LIGAND_NAME
  ) %>%
  summarize(
    LIGAND_DENSITY_SD = sd(LIGAND_DENSITY, na.rm = TRUE),
    LIGAND_DENSITY = mean(LIGAND_DENSITY, na.rm = TRUE),
    LIGAND_DENSITY_RELATIVE_SD = LIGAND_DENSITY_SD/LIGAND_DENSITY*100,
    N = n()
  )

# Get image data
ImagesList <- readr::read_csv(file.path(parameters_path, "images.csv"))
readr::write_csv(ImagesList, file.path(output_path, "old_images.csv"))

TempImagesList <- ImagesList
names(TempImagesList) <- toupper(names(TempImagesList))

TempImagesList <- 
  TempImagesList %>%
  mutate(
    CONCENTRATION_nM = ConvertFx(LIGAND)/10^-9,
    LIGAND_NAME = LigandNamesFx(LIGAND),
    DATE = substr(IMAGE, 0, 8),
    DATE =  as.Date(DATE, format = '%Y%m%d')
  )

# Pair image with ligand density
PairLigandsFx <- function(ImageX){
  if(!is.na(TempImagesList$LIGAND[ImageX])){
    # Calculate density parameters
    LigandPairingTable <-
      Summary %>% 
      ungroup() %>% 
      filter(
        LIGAND_NAME == TempImagesList$LIGAND_NAME[ImageX]
      ) %>% 
      mutate(
        DELTA_CONCENTRATION_nM = abs(CONCENTRATION_nM - TempImagesList$CONCENTRATION_nM[ImageX])
      ) %>% 
      filter(
        DELTA_CONCENTRATION_nM == min(DELTA_CONCENTRATION_nM)
      ) %>% 
      mutate(
        DELTA_DATE = abs(DATE - TempImagesList$DATE[ImageX])
      ) %>% 
      filter(
        DATE == min(DATE)
      )
    # Spit out ligand density
    return(LigandPairingTable$LIGAND_DENSITY)
  } else{
    return(NA)
  }
}
Pairings <- lapply(1:NROW(TempImagesList), PairLigandsFx)
Pairings <- unlist(Pairings)
# Add ligand density data
ImagesList <- 
  ImagesList %>%
  ungroup() %>% 
  mutate(
    ligand_density = ifelse(is.na(ligand_density), Pairings[1:n()], ligand_density),
    ligand_density = ifelse(is.na(ligand_density), 0, ligand_density)
  )

# Write tables
write.csv(Summary, file.path(output_path, paste("ligand_summary", date(),".csv")), row.names = FALSE)
write.csv(Results, file.path(output_path, paste("ligand_images", date(),".csv")), row.names = FALSE)
readr::write_csv(ImagesList, file.path(parameters_path, "images.csv"))

# Move files
for(ImageX in 1:NROW(Results)){
  old_path = file.path(ligand_path, Results[ImageX])
  new_path = file.path(output_path, Results[ImageX])
  file.move(old_path, new_path)
}
