#!/usr/bin/env Rscript
args = commandArgs(trailingOnly=TRUE)
parameters_path = args[1]
unlink(".RData")


##############
# User Input #
##############

# parameters_path = "/Users/u_deliz/Desktop/20211214/Input/parameter_tables"
results_table_name = "_intensity.csv.gz"

##############
# Run Script #
##############

# Libraries----
# Ease library loading
if("pacman" %in% rownames(installed.packages()) == FALSE)
{install.packages("pacman")}
# Actually load libraries
pacman::p_load(dplyr, parallel, tidyr, data.table, ff, changepoint, compiler)

# Compile functions before running
setDTthreads(detectCores(logical = F))
enableJIT(3)

# Parameters----
# Get directories
directories_list = file.path(parameters_path, "directories.csv")
directories_list = fread(directories_list)
processing_path = directories_list$path[directories_list$contains == "processing"]
extraction_path = file.path(processing_path, "05_IntensityExtraction")
colocalized_path = file.path(processing_path, "06_Colocalization")
input_path = directories_list$path[directories_list$contains == "input"]
summary_path = file.path(input_path, "summary.csv")
# Get image list
file_list = fread(summary_path)
# Get images table
image_list = NULL
image_list$table = paste0(file_list$protein_relative_path, results_table_name)
image_list$table = file.path(extraction_path, image_list$table)
# Get list of files that need colocalization
colocalization_list <- as_tibble(image_list)
# Get colocalization list
colocalization_list <-
  colocalization_list %>% 
  mutate(
    cell = dirname(table),
    image = dirname(cell),
    cohort = dirname(image),
    # protein = basename(table)
  ) %>% 
  mutate(
    cohort = basename(cohort),
    # protein = gsub(results_table_name, "", protein)
  ) %>% 
  mutate(
    cohort = file.path(colocalized_path, cohort)
  ) %>% 
  filter(
    file.exists(table)
  ) %>% 
  group_by(
    cell
  ) %>% 
  mutate(
    n = n()
  ) %>% 
  as.data.table()

# Create colocalized path if it doesn't exist
if(!file.exists(colocalized_path)){
  dir.create(colocalized_path)
}

# Get list of files that need colocalization
ColocalizationNeeded <-
  colocalization_list %>% 
  filter(
    n > 1
  ) %>% 
  as.data.table()

# Extract complementary info
ProteinFx <- function(Protein, TempTable){
  
  RefProteinTable <-
    TempTable %>% 
    filter(
      PROTEIN == Protein
    ) %>% 
    select(
      UNIVERSAL_SPOT_ID,
      UNIVERSAL_COLOCALIZATION_FRAME
    ) %>% 
    as.data.table()
  
  QryProteinTable <-
    TempTable %>% 
    filter(
      PROTEIN != Protein
    ) %>% 
    arrange(
      PROTEIN
    ) %>% 
    group_by(
      PROTEIN
    ) %>% 
    mutate(
      PROTEIN_ID = as.character(cur_group_id())
    ) %>% 
    select(
      UNIVERSAL_COLOCALIZATION_FRAME,
      UNIVERSAL_SPOT_ID,
      PROTEIN,
      PROTEIN_ID,
      TOTAL_INTENSITY
    ) %>% 
    as.data.table()
  
  names(QryProteinTable) <- c(
    "UNIVERSAL_COLOCALIZATION_FRAME",
    "COMPLEMENTARY_UNIVERSAL_SPOT_ID",
    "COMPLEMENTARY_PROTEIN",
    "PROTEIN_ID",
    "COMPLEMENTARY_TOTAL_INTENSITY"
  )
  
  ProteinTable <- merge(RefProteinTable, QryProteinTable, by = "UNIVERSAL_COLOCALIZATION_FRAME")
  return(ProteinTable)
}

# Run for cell
Cells <- unique(ColocalizationNeeded$cell)
ColocalizeImage <- function(CellX){
  print(paste("ColocalizeImage - CellX =", CellX))
  
  TableList <-
    ColocalizationNeeded %>% 
    filter(
      cell == Cells[CellX]
    ) %>% 
    as.data.table()
  
  TempTable <- lapply(TableList$table, fread)
  TempTable <- rbindlist(TempTable)
  
  Proteins <- unique(TempTable$PROTEIN)

  ProteinsTable <- lapply(Proteins, ProteinFx, TempTable)
  ProteinsTable <- rbindlist(ProteinsTable)
  
  # Save
  save_path = "colocalization.csv.gz"
  save_path = file.path(TableList$cell[1], save_path)
  # Remove old if it exists
  suppressWarnings({
    file.remove(save_path, showWarnings = FALSE)
  })
  data.table::fwrite(ProteinsTable, save_path, row.names = F, na = "")
  
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
  
  return(save_path)
}
ResultsPath <- mclapply(1:NROW(Cells), ColocalizeImage, mc.cores = detectCores(logical = F))
ResultsPath <- unlist(ResultsPath)

# Get list of files that need colocalization
ColocalizationNotNeeded <-
  colocalization_list %>% 
  filter(
    n == 1
  ) %>% 
  as.data.table()

# Get images path
ImagePath <- dirname(dirname(ResultsPath))
ImagePath <- unique(ImagePath)
ImagePath <- c(ImagePath, ColocalizationNotNeeded$image)
# Get cohort names
Cohorts <- basename(dirname(ImagePath))
Cohorts <- file.path(colocalized_path, Cohorts)
Cohorts <- unique(Cohorts)
# Create re-extraction path if it doesn't exist
if(!file.exists(colocalized_path)){
  dir.create(colocalized_path)
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
  new_path = file.path(colocalized_path, Cohort, Image)
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

print('colocalization.R is now complete')

Sys.sleep(5)
