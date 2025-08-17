#!/usr/bin/env Rscript
args = commandArgs(trailingOnly=TRUE)
parameters_path = args[1]

##############
# User Input #
##############

# ADD when it was last analyzed

# Ending of files
# parameters_path = "/Users/u_deliz/Desktop/NewPipeline/Input/parameter_tables/"

if("pacman" %in% rownames(installed.packages()) == FALSE)
{install.packages("pacman")}

pacman::p_load(data.table, R.utils)
setDTthreads(parallel::detectCores(logical = F))

# Get directories
directories_list = file.path(parameters_path, "directories.csv")
directories_list = fread(directories_list)
input_path = directories_list$path[directories_list$contains == "input"]
output_path = directories_list$path[directories_list$contains == "output"]
summary_path = file.path(input_path, "summary.csv")

# Get image list
file_list = fread(summary_path)
to_compress <- file.path(output_path, file_list$protein_relative_path)

# ND2 file list
nd2_list <- dirname(dirname(to_compress))
nd2_list <- unique(nd2_list)
nd2_list <- file.path(nd2_list, paste0(basename(nd2_list), ".nd2"))
nd2_list <- nd2_list[file.exists(nd2_list)]
# Compress
mapply(gzip, nd2_list, paste0(nd2_list, ".gz"))

# Get cells to compress
cell_list <- dirname(to_compress)
cell_list <- unique(cell_list)
cell_list <- cell_list[file.exists(cell_list)]

# Compress image----
CompressCell <- function(CellX){
  
  print(paste("CompressCell - CellX =", CellX))
  # Get file list
  Path <- cell_list[CellX]
  Files <- list.files(Path)
  Files <- file.path(basename(Path), Files)
  
  # Make into tar
  setwd(dirname(Path))
  tar(paste0(basename(Path), ".tar.gz"), files = Files, compression = "gzip", tar = "tar")#, compression_level = 9)
  # Delete uncompressed folder
  if(file.exists(paste0(basename(Path), ".tar.gz"))){
    unlink(Path, recursive = TRUE)
  }
  
  return(paste0(Path, "tar.gz"))
}
lapply(1:NROW(cell_list), CompressCell)

folder_list <- dirname(dirname(to_compress))
folder_list <- unique(folder_list)

protein_list <- basename(to_compress)
protein_list <- unique(protein_list)
protein_list <- expand.grid(folder_list, protein_list)
protein_list <- file.path(protein_list$Var1, protein_list$Var2)
protein_list <- protein_list[file.exists(paste0(protein_list, ".tif"))]

tiff_list <- c("", "_darkframe_removed", "_intensity_ref", "_puncta_median_removed", "_tracking_ref")
tiff_list <- paste0(tiff_list, ".tif")

CompressSimilarImages <- function(ImageX){
  tryCatch({
    
    print(paste("CompressSimilarImages - ImageX =", ImageX))
    
    Path <- protein_list[ImageX]
    
    temp_tiff_list <- expand.grid(Path, tiff_list)
    temp_tiff_list <- paste0(temp_tiff_list$Var1, temp_tiff_list$Var2)
    temp_tiff_list <- basename(temp_tiff_list)
    # Make into tar
    setwd(dirname(Path))
    tar(paste0(basename(Path), ".tar.gz"), files = temp_tiff_list, compression = "gzip", tar = "tar")
    
    # Delete uncompressed folder
    if(file.exists(paste0(basename(Path), ".tar.gz"))){
      unlink(temp_tiff_list, recursive = TRUE)
    }
    
    # Show progress
    Progress = NROW(protein_list)/10
    Progress = round(Progress)
    if(Progress==0){
      Progress = 1
    }
    
    if(ImageX %% Progress == 0){
      Progress = ImageX/NROW(protein_list)
      Progress = Progress*100
      Progress = round(Progress)
      Progress = paste0("     ", Progress, "% complete")
      print(Progress)
    }
    
    return(Path)
    
    }, error = function(e){print(paste("ERROR with CompressSimilarImages ImageX =", ImageX))})
}
lapply(1:NROW(protein_list), CompressSimilarImages)

# Compress images----
images_list <- dirname(dirname(to_compress))
images_list <- unique(images_list)

CompressImagePackage <- function(ImageX){
  # Get path
  img = images_list[ImageX]
  # Change directory to folder
  setwd(img)
  # Get list of files
  file_list = list.files(img, recursive = T)
  # Remove package if it exists
  if(file.exists("files.tar.gz")){
    file.remove("files.tar.gz")
  }
  # Exclude some tables
  file_list = file_list[!file_list %in% c("Essential.csv.gz", "Analysis.csv.gz", "files.tar.gz")]
  # Compress files
  tar("files.tar.gz", files = file_list, compression = "gzip", tar = "tar")
  
  # Delete uncompressed folder
  if(file.exists("files.tar.gz")){
    unlink(file_list, recursive = TRUE)
  }
  
  # Show progress
  Progress = NROW(images_list)/10
  Progress = round(Progress)
  if(Progress==0){
    Progress = 1
  }
  
  if(ImageX %% Progress == 0){
    Progress = ImageX/NROW(images_list)
    Progress = Progress*100
    Progress = round(Progress)
    Progress = paste0("     ", Progress, "% complete")
    print(Progress)
  }
}
lapply(1:NROW(images_list), CompressImagePackage)

print('compress_everything.R is now complete')

Sys.sleep(5)
