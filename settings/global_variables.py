import os, csv, datetime
import pandas as pd
# To prevent truncating paths
pd.options.display.max_colwidth = 10000


# Temporary files path
def processing_paths(directories_table):
    try:
        # Path
        directory_list = pd.read_csv(directories_table)

        # Input path
        input_path = directory_list.loc[directory_list['contains'] == 'input']['path']
        input_path = input_path.to_string(index=False).strip()
        # Create if it doesn't exist
        if not os.path.exists(input_path):
            os.makedirs(input_path)

        # Processing path
        processing_path = directory_list.loc[directory_list['contains'] == 'processing']['path']
        processing_path = processing_path.to_string(index=False).strip()
        # Create if it doesn't exist
        if not os.path.exists(processing_path):
            os.makedirs(processing_path)

        # Ligand path
        ligand_path = os.path.join(processing_path, "00_Ligand")
        # Create if it doesn't exist
        if not os.path.exists(ligand_path):
            os.makedirs(ligand_path)

        # From proprietary file to TIFF output path
        to_tiff_path = os.path.join(processing_path, "01_Convert_to_TIFF")
        # Create if it doesn't exist
        if not os.path.exists(to_tiff_path):
            os.makedirs(to_tiff_path)

        # Background remove output path
        background_remove_path = os.path.join(processing_path, "02_Remove_Backgrounds")
        # Create if it doesn't exist
        if not os.path.exists(background_remove_path):
            os.makedirs(background_remove_path)

        # Segmentation output path
        segmentation_path = os.path.join(processing_path, "03_Segment")
        # Create if it doesn't exist
        if not os.path.exists(segmentation_path):
            os.makedirs(segmentation_path)

        # Tracking output path
        tracking_path = os.path.join(processing_path, "04_Track")
        # Create if it doesn't exist
        if not os.path.exists(tracking_path):
            os.makedirs(tracking_path)

        # Final output path
        output_path = directory_list.loc[directory_list['contains'] == 'output']['path']
        output_path = output_path.to_string(index=False).strip()
        # Create if it doesn't exist
        if not os.path.exists(output_path):
            os.makedirs(output_path)

        # Dark frames path
        dark_frames_path = directory_list.loc[directory_list['contains'] == 'dark_frames']['path']
        dark_frames_path = dark_frames_path.to_string(index=False).strip()

        # ImageJ/FIJI path
        imagej = directory_list.loc[directory_list['contains'] == 'ImageJ']['path']
        imagej = imagej.to_string(index=False).strip()

        return input_path, ligand_path, to_tiff_path, background_remove_path, segmentation_path, tracking_path, \
               output_path, dark_frames_path, imagej
    except:
        # Get file path
        sample_path = os.path.dirname(directories_table)
        sample_table = 'sample ' + os.path.basename(directories_table)
        sample_directories_table = os.path.join(sample_path, sample_table)
        print('Input not accepted. Sample will be at ' + sample_directories_table)
        # Create table
        with open(sample_directories_table, 'w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(['contains', 'path'])
            writer.writerow(['input', 'path'])
            writer.writerow(['processing', 'path'])
            writer.writerow(['output', 'path'])
            writer.writerow(['dark_frames', 'path'])
            writer.writerow(['ImageJ', 'path'])

# Import dark frame parameters
def dark_frame_parameters(dark_frames_table, dark_frames_path):
    try:
        # Import dark frames table
        dark_frames_list = pd.read_csv(dark_frames_table)
        # Combine directory with image name
        dark_frames_list = dark_frames_list.assign(
            path=lambda dataframe: dataframe['image'].map(lambda image: os.path.join(dark_frames_path, image)),
            exposure=lambda dataframe: dataframe['exposure'].map(
                lambda exposure: exposure.split(' ')[0] if exposure.split(' ')[1] == 'ms' else exposure),
            date=lambda dataframe: dataframe['image'].map(lambda image: image[:8])
        )
        # Date to python format
        dark_frames_list = dark_frames_list.assign(
            date=lambda dataframe: dataframe['date'].map(lambda date: datetime.datetime.strptime(date, '%Y%m%d'))
        )
        return dark_frames_list
    except:
        # Get file path
        sample_path = os.path.dirname(dark_frames_table)
        sample_table = 'sample ' + os.path.basename(dark_frames_table)
        sample_dark_frames_table = os.path.join(sample_path, sample_table)
        print('Input not accepted. Sample will be at ' + sample_dark_frames_table)
        # Create table
        with open(sample_dark_frames_table, 'w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(['image', 'exposure'])
            writer.writerow(['yyyymmdd img_name', 'ms'])

# For pairing images by dates
def nearest_date(array, value):
    return min(array, key=lambda x: abs(x - value))

# Import images list
def image_parameters(images_table):
    try:
        # Path
        images_list = pd.read_csv(images_table)
        # Make paths from dark-frame images
        n_images = range(0, len(images_list))
        n_images = list(n_images)

        images_list.image.replace(".nd2", "")

        # Combine directory with image name
        images_list = images_list.assign(
            image=lambda dataframe: dataframe['image'].map(lambda image: image.replace(".nd2", "")),
            date=lambda dataframe: dataframe['image'].map(lambda image: image[:8])
        )
        images_list = images_list.assign(
            image=lambda dataframe: dataframe['image'].map(lambda image: image.replace(".tif", "")),
        )
        # Relative path
        images_list = images_list.assign(
            relative_path=images_list.apply(lambda dataframe: os.path.join(dataframe['cohort'], dataframe['image']), axis=1),
        )
        try:
            # Standardize date
            images_list = images_list.assign(
                date=lambda dataframe: dataframe['date'].map(lambda date: datetime.datetime.strptime(date, '%Y%m%d'))
            )
        except:
            print('Incorrect date')

        return images_list, n_images
    except:
        # Get file path
        sample_path = os.path.dirname(images_table)
        sample_table = 'sample ' + os.path.basename(images_table)
        sample_images_table = os.path.join(sample_path, sample_table)
        print('Input not accepted. Sample will be at ' + sample_images_table)
        # Create table
        with open(sample_images_table, 'w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(['image', 'cohort', 'segment_with', 'ligand', 'trackmate_max_link_distance',
                             'channel protein_name', 'trackmate_threshold', 'trackmate frame gap'])
            writer.writerow(
                ['yyyymmdd img_name', 'cell_line drug parameters', 'protein_name', 'x nM search_terms', 'px',
                 'protein_name', 'signal_noise_theshold', 's'])

# Constants
def constants(constants_table):
    try:
        constants_list = pd.read_csv(constants_table)
        # TIFF Compression
        tiff_compression_level = constants_list.loc[constants_list['parameter'] == 'tiff_compression_level']['value']
        tiff_compression_level = tiff_compression_level.to_string(index=False).strip()
        tiff_compression_level = int(tiff_compression_level)

        # Cell diameter
        cell_diameter = constants_list.loc[constants_list['parameter'] == 'cell_diameter']['value']
        cell_diameter = cell_diameter.to_string(index=False).strip()
        cell_diameter = int(cell_diameter)

        # Puncta diameter
        puncta_diameter = constants_list.loc[constants_list['parameter'] == 'puncta_diameter']['value']
        puncta_diameter = puncta_diameter.to_string(index=False).strip()
        puncta_diameter = int(puncta_diameter)

        return tiff_compression_level, cell_diameter, puncta_diameter
    except:
        # Get file path
        sample_path = os.path.dirname(constants_table)
        sample_table = 'sample ' + os.path.basename(constants_table)
        sample_constants_table = os.path.join(sample_path, sample_table)
        print('Input not accepted. Sample will be at ' + sample_constants_table)
        # Create table
        with open(sample_constants_table, 'w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(['parameter', 'value', 'comments'])
            writer.writerow(['tiff_compression_level', '5', 'out of 10'])
            writer.writerow(['cell_diameter', '25', 'px'])
            writer.writerow(['puncta_diameter', '5', 'px'])

# Channels to exclude from trackmate
def exclude_chanels(exclusion_table):
    try:
        # Get table
        exclusion_channels = pd.read_csv(exclusion_table)
        # Extract column
        exclusion_channels = exclusion_channels.value
        # Reformat to list
        exclusion_channels = list(exclusion_channels)

        # TIFF Compression
        return exclusion_channels
    except:
        # Get file path
        sample_path = os.path.dirname(exclusion_table)
        sample_table = 'sample ' + os.path.basename(exclusion_table)
        sample_exclusion_table = os.path.join(sample_path, sample_table)
        print('Input not accepted. Sample will be at ' + sample_exclusion_table)
        # Create table
        with open(sample_exclusion_table, 'w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(['value'])
            writer.writerow(['MyD88'])