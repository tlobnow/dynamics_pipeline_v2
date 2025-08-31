#!/usr/bin/env bash

Rscript -e "

pkgs <- c('XML','dplyr','parallel','tidyr','data.table','ff',
          'changepoint','compiler','stringr','dtplyr','RANN')

repos <- 'https://cloud.r-project.org'

missing <- pkgs[!sapply(pkgs, requireNamespace, quietly = TRUE)]
if (length(missing)) install.packages(missing, repos = repos)

failed <- pkgs[!sapply(pkgs, require, character.only = TRUE, quietly = TRUE)]

if (length(failed)) {
  message('Failed: ', paste(failed, collapse = ', '))
  quit(status = 1)
} else {
  message('R package setup completed successfully!')
}
"
