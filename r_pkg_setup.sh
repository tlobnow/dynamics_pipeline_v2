#!/usr/bin/env bash

Rscript -e "
if (!requireNamespace('pacman', quietly = TRUE)) {
  install.packages('pacman', repos='https://cloud.r-project.org')
}

if (!requireNamespace('remotes', quietly = TRUE)) {
  install.packages('remotes', repos='https://cloud.r-project.org')
}

check_and_install <- function(pkg, ver) {
  if (!requireNamespace(pkg, quietly = TRUE) ||
      packageVersion(pkg) != ver) {
    remotes::install_version(pkg, version = ver,
                             repos='https://cloud.r-project.org')
  }
}

check_and_install('purrr', '0.3.4')
check_and_install('tidyr', '1.1.3')
check_and_install('ijtiff', '2.3.1')

pacman::p_load(
  XML, dplyr, parallel, tidyr, data.table, ff,
  changepoint, compiler, stringr, dtplyr, RANN
)

message('R package setup completed successfully!')
"
