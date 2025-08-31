#!/usr/bin/env bash

Rscript -e "
if (!requireNamespace('remotes', quietly = TRUE)) {
    install.packages('remotes', repos='https://cloud.r-project.org')
}
remotes::install_version('purrr', version = '0.3.4', repos='https://cloud.r-project.org')
remotes::install_version('tidyr', version = '1.1.3', repos='https://cloud.r-project.org')
remotes::install_version('ijtiff', version = '2.3.1', repos='https://cloud.r-project.org')

if (!requireNamespace('pacman', quietly = TRUE)) {
    install.packages('pacman', repos='https://cloud.r-project.org')
}

pacman::p_load(
    XML, dplyr, parallel, tidyr, data.table, ff,
    changepoint, compiler, stringr, dtplyr, RANN
)
"
