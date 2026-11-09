#!/usr/bin/env Rscript
# =============================================================================
# colocalization.R
#
# Per cell, join the spot table to itself on UNIVERSAL_COLOCALIZATION_FRAME
# (image ... cell ... TrackMate track id ... frame) so that every spot carries
# the other channel's measurement of the same punctum.
#
# Markers: #!! NUMBERS / FIX / SPEED / KEPT / NOTE   (grep '#!!')
# =============================================================================

args = commandArgs(trailingOnly=TRUE)
parameters_path = args[1]
unlink(".RData")

##############
# User Input #
##############

results_table_name = "_intensity.csv.gz"

##############
# Run Script #
##############

# Libraries----
if (!requireNamespace("pacman", quietly = TRUE)) {stop("Package 'pacman' is not installed. Please install it before running.")}
pacman::p_load(dplyr, parallel, tidyr, data.table, ff, changepoint, compiler)
print('All libraries loaded')

# Parallel + JIT setup
ncores <- parallel::detectCores(logical = FALSE)
setDTthreads(ncores)
enableJIT(3)

slurm_cpus <- suppressWarnings(as.integer(Sys.getenv("SLURM_CPUS_PER_TASK")))
n_workers  <- if (!is.na(slurm_cpus) && slurm_cpus > 0) slurm_cpus else ncores

# Parameters----
directories_list = file.path(parameters_path, "directories.csv")
directories_list = fread(directories_list)
processing_path  = directories_list$path[directories_list$contains == "processing"]
extraction_path  = file.path(processing_path, "05_IntensityExtraction")
colocalized_path = file.path(processing_path, "06_Colocalization")
input_path       = directories_list$path[directories_list$contains == "input"]
#!! KEPT: summary.csv is per-run, in the processing folder.
#!! Published version: file.path(input_path, "summary.csv").
summary_path     = file.path(dirname(parameters_path), "summary.csv")

# Get image list
file_list = fread(summary_path)

# Get images table
image_list = NULL
image_list$table = paste0(file_list$protein_relative_path, results_table_name)
image_list$table = file.path(extraction_path, image_list$table)

# Get list of files that need colocalization
colocalization_list <- as_tibble(image_list)

colocalization_list <- colocalization_list %>%
  mutate(cell   = dirname(table),
         image  = dirname(cell),
         cohort = dirname(image)) %>%
  mutate(cohort = basename(cohort)) %>%
  mutate(cohort = file.path(colocalized_path, cohort)) %>%
  filter(file.exists(table)) %>%
  group_by(cell) %>%
  mutate(n = n()) %>%
  as.data.table()

# Create colocalized path if it doesn't exist
if(!file.exists(colocalized_path)) {dir.create(colocalized_path)}

# Get list of files that need colocalization
ColocalizationNeeded <- colocalization_list %>%
  filter(n > 1) %>%
  as.data.table()

#!! FIX: a cell whose second channel failed earlier silently drops to n == 1 and
#!! is carried through with no complement at all -- its tracks then look like
#!! they never colocalised, which is indistinguishable from a real negative.
#!! Say how many cells that is, so it can be checked rather than believed.
n_expected <- colocalization_list %>%
  mutate(cell_dir = cell) %>%
  distinct(cell_dir, n)
n_single <- sum(n_expected$n == 1)
if (n_single > 0) {
  message("colocalization.R: ", n_single, " cell(s) have only one channel's ",
          "intensity table and get no complement. If that is not expected, ",
          "check extract_intensity.R's ERROR lines for those cells:")
  for (p in head(n_expected$cell_dir[n_expected$n == 1], 10)) message("  ", p)
}

# Extract complementary info
#!! NOTE: PROTEIN_ID is assigned with cur_group_id() *inside each reference
#!! protein's query table*, so COMPLEMENTARY_*_1 means "the alphabetically first
#!! OTHER protein", which is a different protein depending on which one you look
#!! from. Unambiguous for two channels; ambiguous for three. Unchanged.
ProteinFx <- function(Protein, TempTable){

  RefProteinTable <- TempTable %>%
    filter(PROTEIN == Protein) %>%
    select(UNIVERSAL_SPOT_ID, UNIVERSAL_COLOCALIZATION_FRAME) %>%
    as.data.table()

  QryProteinTable <- TempTable %>%
    filter(PROTEIN != Protein) %>%
    arrange(PROTEIN) %>%
    group_by(PROTEIN) %>%
    mutate(PROTEIN_ID = as.character(cur_group_id())) %>%
    select(UNIVERSAL_COLOCALIZATION_FRAME,
           UNIVERSAL_SPOT_ID,
           PROTEIN,
           PROTEIN_ID,
           TOTAL_INTENSITY) %>%
    as.data.table()

  names(QryProteinTable) <- c("UNIVERSAL_COLOCALIZATION_FRAME",
                              "COMPLEMENTARY_UNIVERSAL_SPOT_ID",
                              "COMPLEMENTARY_PROTEIN",
                              "PROTEIN_ID",
                              "COMPLEMENTARY_TOTAL_INTENSITY")

  ProteinTable <- merge(RefProteinTable, QryProteinTable, by = "UNIVERSAL_COLOCALIZATION_FRAME")
  return(ProteinTable)
}

# Run for cell
Cells <- unique(ColocalizationNeeded$cell)
ColocalizeImage <- function(CellX){

  TableList <- ColocalizationNeeded %>% filter(cell == Cells[CellX]) %>% as.data.table()

  TempTable <- lapply(TableList$table, fread)
  TempTable <- rbindlist(TempTable)

  Proteins  <- unique(TempTable$PROTEIN)

  ProteinsTable <- lapply(Proteins, ProteinFx, TempTable)
  ProteinsTable <- rbindlist(ProteinsTable)

  # Save
  save_path = "colocalization.csv.gz"
  save_path = file.path(TableList$cell[1], save_path)

  #!! KEPT: file.remove() has no showWarnings argument - it was treating
  #!! "FALSE" as a second file name to delete.
  suppressWarnings({file.remove(save_path)})
  data.table::fwrite(ProteinsTable, save_path, row.names = F, na = "")

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

  return(save_path)
}

#!! KEPT: seq_len - when no cell needs colocalization, 1:NROW(Cells) is c(1, 0)
#!! and ColocalizeImage was called with CellX = 0 and CellX = 1 on an empty table.
#!! SPEED: setDTthreads(1) around the fork, dynamic scheduling.
setDTthreads(1)
ResultsPath <- mclapply(seq_len(NROW(Cells)), ColocalizeImage,
                        mc.cores = max(1, min(n_workers, NROW(Cells))),
                        mc.preschedule = FALSE)
setDTthreads(ncores)
ResultsPath <- unlist(ResultsPath)

# Get list of files that need colocalization
ColocalizationNotNeeded <- colocalization_list %>% filter(n == 1) %>% as.data.table()

# Get images path
ImagePath <- dirname(dirname(ResultsPath))
ImagePath <- unique(ImagePath)
ImagePath <- c(ImagePath, ColocalizationNotNeeded$image)

# Get cohort names
Cohorts <- basename(dirname(ImagePath))
Cohorts <- file.path(colocalized_path, Cohorts)
Cohorts <- unique(Cohorts)

# Create re-extraction path if it doesn't exist
if(!file.exists(colocalized_path)){dir.create(colocalized_path)}

# Create cohort path if it doesn't exist
for(Cohort in Cohorts){if(!file.exists(Cohort)){dir.create(Cohort)}}

# Move Image
for(Image in ImagePath){
  old_path = Image
  Cohort   = basename(dirname(Image))
  Image    = basename(Image)
  new_path = file.path(colocalized_path, Cohort, Image)
  file.move(old_path, new_path)
}

# Delete cohort if empty
OldCohorts = unique(dirname(ImagePath))
for(Cohort in OldCohorts){if(NROW(list.files(Cohort)) == 0){unlink(Cohort, recursive = TRUE)}}

# Delete processing folder if empty
#!! KEPT: guard against an empty OldCohorts (nothing to move).
if(NROW(OldCohorts) > 0){
  ProcessingFolder = dirname(OldCohorts[1])
  if(NROW(list.files(ProcessingFolder)) == 0){unlink(ProcessingFolder, recursive = TRUE)}
}

print('colocalization.R is now complete')
print("R session info:")
sessionInfo()