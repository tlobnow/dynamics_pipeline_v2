#!/usr/bin/env Rscript
# Why does extract_intensity.R find nothing?
#
#   Rscript --vanilla check_paths.R /ptmp/flobnow/new_pipe/3_processing/20260814/parameter_tables
#
# Rebuilds exactly the two existence tests extract_intensity.R applies to
# summary.csv and reports which one fails, without running the pipeline.

suppressMessages({
  library(data.table)
  library(dplyr)
})

args = commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage: check_paths.R <parameter_tables folder>")
parameters_path = args[1]

directories_list = fread(file.path(parameters_path, "directories.csv"))
processing_path  = directories_list$path[directories_list$contains == "processing"]
tracking_path    = file.path(processing_path, "04_Track")
summary_path     = file.path(dirname(parameters_path), "summary.csv")

constants = fread(file.path(parameters_path, "constants.csv"))
cat("parameter tables :", parameters_path, "\n")
cat("processing       :", processing_path, "\n")
cat("04_Track         :", tracking_path, " exists:", dir.exists(tracking_path), "\n")
cat("summary.csv      :", summary_path, " exists:", file.exists(summary_path), "\n\n")

if (!file.exists(summary_path)) stop("no summary.csv at ", summary_path)

# extract_intensity.R uses new_image_ending; both variants are checked here so
# this script does not have to guess which one your copy is set to.
endings = c("_puncta_median_removed.tif", "_intensity_ref.tif",
            "_tracking_ref.tif", ".tif")

file_list = fread(summary_path)
cat("rows in summary.csv:", NROW(file_list), "\n")
cat("cohorts            :", paste(unique(file_list$cohort), collapse = ", "), "\n")
cat("channels           :", paste(unique(file_list$channel), collapse = ", "), "\n\n")

file_list <- file_list %>%
  mutate(protein_path = file.path(tracking_path, protein_relative_path)) %>%
  mutate(
    xml = ifelse(cohort == "Calibrations", protein_path,
                 file.path(dirname(protein_path), "Combined")),
    xml = paste0(xml, ".xml")
  ) %>%
  as.data.table()

cat("--- image files (protein_path + ending) ---\n")
for (ending in endings) {
  hits = sum(file.exists(paste0(file_list$protein_path, ending)))
  cat(sprintf("  %-30s %d of %d exist\n", ending, hits, NROW(file_list)))
}

cat("\n--- xml files ---\n")
cat(sprintf("  %d of %d exist\n", sum(file.exists(file_list$xml)), NROW(file_list)))

cat("\n--- first row ---\n")
cat("  protein_relative_path:", file_list$protein_relative_path[1], "\n")
cat("  expected folder      :", dirname(file_list$protein_path[1]), "\n")
cat("  folder exists        :", dir.exists(dirname(file_list$protein_path[1])), "\n")
cat("  expected xml         :", file_list$xml[1], "\n")
cat("  xml exists           :", file.exists(file_list$xml[1]), "\n")

if (dir.exists(dirname(file_list$protein_path[1]))) {
  cat("  what IS in that folder:\n")
  for (f in head(list.files(dirname(file_list$protein_path[1])), 15)) {
    cat("    ", f, "\n")
  }
}

if (dir.exists(tracking_path)) {
  cat("\n--- cohort folders under 04_Track ---\n")
  for (d in list.dirs(tracking_path, recursive = FALSE, full.names = FALSE)) {
    n = length(list.dirs(file.path(tracking_path, d), recursive = FALSE))
    cat(sprintf("  %-40s %d image folder(s)\n", d, n))
  }
  cat("\n--- xml files actually present (first 10) ---\n")
  found = list.files(tracking_path, pattern = "\\.xml$", recursive = TRUE)
  cat("  total:", length(found), "\n")
  for (f in head(found, 10)) cat("    ", f, "\n")
}