#!/usr/bin/env bash

# Load necessary modules (R, gcc, etc.)
cd
module purge
module load jdk/8.265 gcc/10 impi/2021.2 fftw-mpi R/4.0.2

# Install libtiff if not already installed
LIBTIFF_DIR="$HOME/libtiff"

if [ ! -d "$LIBTIFF_DIR/install" ]; then
	echo "Installing libtiff..."
	mkdir -p "$LIBTIFF_DIR"
	cd "$LIBTIFF_DIR" || exit
	wget -q https://download.osgeo.org/libtiff/tiff-4.3.0.tar.gz
	wget -q https://cran.r-project.org/src/contrib/Archive/XML/XML_3.99-0.14.tar.gz
	tar -xzf tiff-4.3.0.tar.gz
	cd tiff-4.3.0 || exit
	mkdir -p compile
	cd compile || exit
	../configure --prefix="$LIBTIFF_DIR/install"
	make -j"$(nproc)"
	make install
fi

# Export paths (must be sourced to persist)
export PKG_CONFIG_PATH="$LIBTIFF_DIR/install/lib/pkgconfig:$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$LIBTIFF_DIR/install/lib:$LD_LIBRARY_PATH"

echo "libtiff installation and environment ready."
