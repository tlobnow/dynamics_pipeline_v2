print('Python start')

import ray
import settings.parallel
import settings.global_variables as variables
import os
import csv
from sys import argv
import platform
import time
import traceback

print('Import complete')

'''
ligand is separate
'''

# Path to all tables that dictate the parameters
if not platform.system() == 'Darwin':
    script_path, parameter_tables, use_x_cpus = argv
    use_x_cpus = int(use_x_cpus)
else:
    parameter_tables = '/Users/u_lobnow/Desktop/20250522_batch/Input/parameter_tables'
    use_x_cpus = 8

print('Arguments accepted')

# Import directory paths
try:
    # Get directories list
    # Table needs two columns: 'contains' and 'path'
    # 'contains' has row values: 'input', 'processing', 'output', 'dark_frames', 'ImageJ'
    directories_table = os.path.join(parameter_tables, 'directories.csv')
    if not os.path.exists(directories_table):
        print('Need to create directories.csv. Sample will be inside ' + parameter_tables)
        sample_directories_table = os.path.join(parameter_tables, 'sample directories.csv')
        with open(sample_directories_table, 'w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(['contains', 'path'])
            writer.writerow(['input', 'path'])
            writer.writerow(['processing', 'path'])
            writer.writerow(['output', 'path'])
            writer.writerow(['dark_frames', 'path'])
            writer.writerow(['ImageJ', 'path'])
    # Directories
    input_path, ligand_path, to_tiff_path, background_remove_path, segmentation_path, tracking_path, output_path, dark_frames_path, imagej = variables.processing_paths(directories_table)

    print('Successfully imported directories list')
except Exception as e:
    print('Could not obtain directories list') ; print(f"Error: {e}") ; traceback.print_exc()
    #pass

# Get parameters
try:
    # Get dark frames parameters
    # Contains 'image' (yyyymmdd img_name) and 'exposure' (ms) of dark frames
    dark_frames_table = os.path.join(parameter_tables, 'dark_frames.csv')
    if not os.path.exists(dark_frames_table):
        print('Need to create dark_frames.csv. Sample will be inside ' + parameter_tables)
        sample_dark_frames_table = os.path.join(parameter_tables, 'sample dark_frames.csv')
        with open(sample_dark_frames_table, 'w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(['image', 'exposure'])
            writer.writerow(['yyyymmdd img_name', 'ms'])
    # Get dark frame info and add date
    dark_frames_list = variables.dark_frame_parameters(dark_frames_table, dark_frames_path)

    # Get image parameters
    # Contains 'image' (yyyymmdd img_name), 'cohort', 'segment_with' (protein_name), 'ligand' (x_nM search_terms),
    # 'trackmate_max_link_distance' (px),
    # 'channel protein_name', 'channel trackmate_threshold', 'channel trackmate frame gap' (frames)
    # Add columns as necessary
    images_table = os.path.join(parameter_tables, 'images.csv')
    if not os.path.exists(images_table):
        print('Need to create images.csv. Sample will be inside ' + parameter_tables)
        sample_images_table = os.path.join(parameter_tables, 'sample images.csv')
        with open(sample_images_table, 'w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(['image', 'cohort', 'segment_with', 'ligand', 'trackmate_max_link_distance',
                             'channel protein_name', 'channel trackmate_threshold', 'channel trackmate frame gap'])
            writer.writerow(
                ['yyyymmdd img_name', 'cell_line drug parameters', 'protein_name', 'x nM search_terms', 'px',
                 'protein_name', 'signal_noise_theshold', 's'])
    # Get images info and add date
    images_list, n_images = variables.image_parameters(images_table)
    # Get constants
    constants_table = os.path.join(parameter_tables, 'constants.csv')
    if not os.path.exists(constants_table):
        print('Need to create constants.csv. Sample will be inside ' + parameter_tables)
        sample_constants_table = os.path.join(parameter_tables, 'sample constants.csv')
        with open(sample_constants_table, 'w', newline='') as file:
            writer = csv.writer(file)
            writer.writerow(['parameter', 'value', 'comments'])
            writer.writerow(['tiff_compression_level', '0', 'out of 10'])
            writer.writerow(['cell_diameter', '25', 'px'])
            writer.writerow(['puncta_diameter', '5', 'px'])
    # Get constant parameters
    tiff_compression_level, cell_diameter, puncta_diameter = variables.constants(constants_table)
    # Get channels to exclude
    exclusion_table = os.path.join(parameter_tables, 'exclusion_channels.csv')
    if not os.path.exists(exclusion_table):
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
    if os.path.exists(exclusion_table):
        exclusion_channels = variables.exclude_chanels(exclusion_table)
    print('Successfully pulled parameters')
except Exception as e:
    print('Could not get parameters')
    print(f"Error: {e}")
    traceback.print_exc()
    #pass


# Convert nd2 to tiff
import conversion.parameters
import conversion.operations
print(f"Starting Conversion of nd2 to tiff")

try:
    # Get channels to protein names table
    channels_table = conversion.parameters.get_channels_table(images_list) ; print(f"channels_table: {channels_table}")
    # Run in parallel
    ray.shutdown()
    ray.init(num_cpus=use_x_cpus)
    result_ids = []
    for image_x in n_images:
        try:
            # Input image
            image_x_path = os.path.join(input_path, images_list['image'][image_x] + '.nd2')
            if os.path.exists(image_x_path):
                # Get image parameters
                image_x_cohort = images_list['cohort'][image_x]
                image_x_channels = channels_table.loc[image_x]
                # Run if nd2
                if os.path.splitext(os.path.basename(image_x_path))[1] == '.nd2':

                    result_id = conversion.operations.nd2_to_tiff.remote(image_x_path, image_x_cohort, image_x_channels, to_tiff_path, tiff_compression_level)
                    result_ids.append(result_id)
                    print('File was converted: ' + image_x_path)
                else:
                    print('File is not ND2: ' + image_x_path)
            else:
                print('ND2 does not exist: ' + image_x_path)
        except Exception as e:
            print('nd2_to_tiff: image_x ' + image_x + ' failed')
            print(f"Error: {e}")
            traceback.print_exc()
            #pass
    results = settings.parallel.ids_to_vals(result_ids)
    print(results)
    time.sleep(3)
    ray.shutdown()
    time.sleep(3)
except Exception as e:
    print('Could not convert ND2 to TIFF')
    print(f"Error: {e}")
    traceback.print_exc()
    #pass

# Subtract dark frame
import background.parameters
import background.operations

try:
    # Get list of images to have background subtracted
    n_protein_images, background_remove_image_list = background.parameters.background_remove_list(images_list, dark_frames_list, to_tiff_path)
    # Run in parallel
    ray.shutdown()
    ray.init(num_cpus=use_x_cpus)
    result_ids = []
    for protein_image_x in n_protein_images:
        try:
            image_path = background_remove_image_list['image_path'][protein_image_x]
            dark_frame_path = background_remove_image_list['dark_frame'][protein_image_x]
            result_id = background.operations.remove_frame.remote(image_path, dark_frame_path, tiff_compression_level)
            result_ids.append(result_id)
        except Exception as e:
            print('remove_frame: protein_image_x ' + protein_image_x + ' failed')
            print(f"Error: {e}")
            traceback.print_exc()
            pass
    results = settings.parallel.ids_to_vals(result_ids)
    print(results)
    time.sleep(3)
    ray.shutdown()
    time.sleep(3)
    print('Successfully removed dark-frames')
except Exception as e:
    print('Could not remove dark-frames')
    print(f"Error: {e}")
    traceback.print_exc()
    pass

# Subtract median
try:
    # Get list of images to have background subtracted
    n_protein_images, background_remove_image_list = background.parameters.background_remove_list(images_list, dark_frames_list, to_tiff_path)  ; print(f"n_protein_images: {n_protein_images}\nbackground_remove_image_list: {background_remove_image_list}")
    median_remove_image_list = background.parameters.median_remove_list(background_remove_image_list, exclusion_channels)                       ; print(f"median_remove_image_list: {median_remove_image_list}")
    # Get number of protein images
    n_protein_images = len(median_remove_image_list)
    n_protein_images = range(0, n_protein_images)
    # Run
    result_ids = []
    for protein_image_x in n_protein_images:
        try:
            # Get image path
            image_path = median_remove_image_list[protein_image_x]
            old_term = '_darkframe_removed'
            # Remove cell background
            new_term = '_intensity_ref'
            median_size = cell_diameter
            result_id = background.operations.remove_median_blur(image_path, old_term, new_term, median_size, tiff_compression_level)
            result_ids.append(result_id)

            # Remove puncta background
            new_term = '_puncta_median_removed'
            median_size = puncta_diameter * 2 + 1
            result_id = background.operations.remove_median_blur(image_path, old_term, new_term, median_size, tiff_compression_level)
            result_ids.append(result_id)

        except Exception as e:
            print('remove_median_blur: protein_image_x ' + protein_image_x + ' failed')
            print(f"Error: {e}")
            traceback.print_exc()
            #pass

    print(result_ids)
    print('Successfully calculated _puncta_median_removed images')
except Exception as e:
    print('Could not calculate _puncta_median_removed image')
    print(f"Error: {e}")
    traceback.print_exc()
    #pass

try:
    # Run in parallel
    ray.shutdown()
    ray.init(num_cpus=use_x_cpus)
    result_ids = []
    for protein_image_x in n_protein_images:
        try:
            # Get image path
            image_path = median_remove_image_list[protein_image_x]
            old_term = '_darkframe_removed'
            new_term = '_puncta_median_removed'
            median_image_path = image_path.replace(old_term, new_term)

            # Blur and average frames
            old_term = '_puncta_median_removed'
            new_term = '_tracking_ref'
            median_size = 3  # Must be odd
            result_id = background.operations.tracking_image.remote(median_image_path, old_term, new_term, median_size,
                                                                    tiff_compression_level)
            result_ids.append(result_id)
        except Exception as e:
            print('tracking_image: protein_image_x ' + protein_image_x + ' failed')
            print(f"Error: {e}")
            traceback.print_exc()
            #pass

    results = settings.parallel.ids_to_vals(result_ids)
    print(results)
    time.sleep(3)
    ray.shutdown()
    time.sleep(3)

    print('Successfully calculated _tracking_ref images')
except Exception as e:
    print('Could not calculate _tracking_ref image')
    print(f"Error: {e}")
    traceback.print_exc()
    #pass

try:
    table_ending = '_darkframe_removed.tif'
    merge_ending = '_tracking_ref.tif'
    '''
    # Only experimental images
    select_images_list = images_list.loc[images_list['cohort'] != 'Calibrations']
    select_images_list = select_images_list.reset_index()
    select_images_list = select_images_list.drop(columns=['index'])
    '''
    # Get list of images to have background subtracted
    n_protein_images, background_remove_image_list = background.parameters.background_remove_list(images_list, dark_frames_list, to_tiff_path)
    median_remove_image_list = background.parameters.median_remove_list(background_remove_image_list, exclusion_channels)
    to_combine = background.parameters.combine_images_list(median_remove_image_list, table_ending, merge_ending)

    unique_images = to_combine.output.unique()
    unique_images = unique_images.tolist()

    n_images = len(unique_images)
    n_images = range(0, n_images)

    # Run in parallel
    ray.shutdown()
    ray.init(num_cpus=use_x_cpus)
    result_ids = []    # Get images to combine
    for image_x in n_images:
        try:
            # Get parameters
            input_folder = unique_images[image_x]
            input_folder = os.path.dirname(input_folder)
            input_images = to_combine.loc[to_combine['folder'] == input_folder]
            input_images = input_images.reset_index()
            input_images = input_images.drop(columns=['index'])
            output_image = input_images.output[0]
            input_images = input_images.input
            input_images = input_images.tolist()

            # Run operation
            result_id = background.operations.combine_images.remote(input_images, output_image, tiff_compression_level)
            result_ids.append(result_id)
        except Exception as e:
            print('combine_images: image_x ' + image_x + ' failed')
            print(f"Error: {e}")
            traceback.print_exc()
            #pass

    results = settings.parallel.ids_to_vals(result_ids)
    print(results)
    time.sleep(3)
    ray.shutdown()
    time.sleep(3)
    print('Successfully calculated Combined_tracking_ref images')

except Exception as e:
    print('Could not calculate Combined_tracking_ref images')

# Move directories of files with removed background
import shutil

try:

    source_folder=to_tiff_path
    destination_folder=background_remove_path

    # Copy everything while preserving the folder structure
    for root, dirs, files in os.walk(source_folder):
        for file in files:
            # Recreate the relative path in the destination
            relative_path = os.path.relpath(root, source_folder)
            target_dir = os.path.join(destination_folder, relative_path)

            # Ensure target directory exists
            os.makedirs(target_dir, exist_ok=True)

            # Copy file
            shutil.copy2(os.path.join(root, file), os.path.join(target_dir, file))

    print(f"Copied from source_folder {source_folder}\n to destination_folder {destination_folder}")

except Exception as e:
    print(f"Error: {e}")
    traceback.print_exc()   

# Segment images
import segmentation.parameters
import segmentation.operations

try:
    # Get parameters
    file_ending = '_intensity_ref.tif'
    segmentation_image_list = segmentation.parameters.segmentation_list(images_list, file_ending, background_remove_path)
    # Run in parallel
    ray.shutdown()
    ray.init(num_cpus=use_x_cpus)
    result_ids = []
    n_segmentation_images = len(segmentation_image_list)
    n_segmentation_images = range(0, n_segmentation_images)
    for image_x in n_segmentation_images:
        try:
            segment_image = segmentation_image_list[image_x]
            # Run segmentation
            result_id = segmentation.operations.segment.remote(segment_image, cell_diameter, tiff_compression_level)
            result_ids.append(result_id)
        except Exception as e:
            print('segment: image_x ' + image_x + ' failed')
            #pass

    results = settings.parallel.ids_to_vals(result_ids)
    print(results)
    time.sleep(3)
    ray.shutdown()
    time.sleep(3)

    # Make substacks
    file_ending = ['_intensity_ref.tif', '_puncta_median_removed', '_tracking_ref.tif']
    substack_segmentation_images, substack_image_list = segmentation.parameters.substack_list(images_list, exclusion_channels, background_remove_path, file_ending)

    # Run in parallel
    ray.shutdown()
    ray.init(num_cpus=use_x_cpus)
    result_ids = []
    n_segmentation_images = len(substack_image_list)
    n_segmentation_images = range(0, n_segmentation_images)
    for image_x in n_segmentation_images:
        try:
            # Get image and segmentation file
            substack_segmentation_image = substack_segmentation_images[image_x]
            substack_image = substack_image_list[image_x]
            # Segment
            result_id = segmentation.operations.make_substacks.remote(substack_segmentation_image, substack_image,
                                                                      puncta_diameter, tiff_compression_level)
            segmentation.operations.make_area_list.remote(substack_segmentation_image, puncta_diameter)
            result_ids.append(result_id)
        except Exception as e:
            print('make_substacks: image_x ' + image_x + ' failed')
            print(f"Error: {e}")
            traceback.print_exc()
            #pass

    results = settings.parallel.ids_to_vals(result_ids)
    print(results)
    time.sleep(3)
    ray.shutdown()
    time.sleep(3)

    print('Successfully segmented images')
except Exception as e:
    print('Could not segment images')
    print(f"Error: {e}")
    traceback.print_exc()
    
# Move / copy stuff
import shutil

try:
    source_folder=background_remove_path
    destination_folder=segmentation_path

    # Copy everything while preserving the folder structure
    for root, dirs, files in os.walk(source_folder):
        for file in files:
            # Recreate the relative path in the destination
            relative_path = os.path.relpath(root, source_folder)
            target_dir = os.path.join(destination_folder, relative_path)

            # Ensure target directory exists
            os.makedirs(target_dir, exist_ok=True)

            # Copy file
            shutil.copy2(os.path.join(root, file), os.path.join(target_dir, file))

    print(f"Copied from source_folder {source_folder}\n to destination_folder {destination_folder}")

except Exception as e:
    print(f"Error: {e}")
    traceback.print_exc()   

# Run tracking
import track.parameters
import track.operations

try:
    # Get images list
    print(f"images_list:\n {images_list}")
    print(f"exclusion_channels:\n {exclusion_channels}")
    print(f"segmentation_path:\n {segmentation_path}")
    print(f"input_path:\n {input_path}")
    print(f"cell_diameter:\n {cell_diameter}")
    print(f"puncta_diameter:\n {puncta_diameter}")
    all_channels_metadata = track.parameters.tracking_list(images_list, exclusion_channels, segmentation_path, input_path, cell_diameter, puncta_diameter)

    print(f"all_channels_metadata:\n {all_channels_metadata}")
    print(f"segmentation_path: {segmentation_path}")
    file_ending = '_tracking_ref.tif' ; print(f"file_ending: {file_ending}")
    n_trackings, protein_paths, image_paths, trackmate_thresholds, trackmate_frame_gaps, trackmate_max_link_distances, trackmate_gap_link_distances = track.parameters.tracking_parameters(all_channels_metadata, file_ending, segmentation_path)
    # print(f"n_trackings: {n_trackings}")
    # print(f"protein_paths: {protein_paths}")
    # print(f"image_paths: {image_paths}")
    # print(f"trackmate_thresholds: {trackmate_thresholds}")
    # print(f"trackmate_frame_gaps: {trackmate_frame_gaps}")
    # print(f"trackmate_max_link_distances: {trackmate_max_link_distances}")
    # print(f"trackmate_gap_link_distances: {trackmate_gap_link_distances}")

    # Send to terminal
    for image_x in n_trackings:
        protein_path = protein_paths[image_x]
        image_path = image_paths[image_x]
        trackmate_threshold = trackmate_thresholds[image_x]
        trackmate_frame_gap = trackmate_frame_gaps[image_x]
        trackmate_max_link_distance = trackmate_max_link_distances[image_x]
        trackmate_gap_link_distance = trackmate_gap_link_distances[image_x]
        track.operations.trackmate(imagej, protein_path, image_path, trackmate_threshold, trackmate_frame_gap, trackmate_max_link_distance, trackmate_gap_link_distance, puncta_diameter)

    print('Successfully tracked puncta')
except Exception as e:
    print('Could not track puncta') ; print(f"Error: {e}") ; traceback.print_exc()


# Move / copy stuff
import shutil

try:
    source_folder=segmentation_path
    destination_folder=tracking_path

    # Copy everything while preserving the folder structure
    for root, dirs, files in os.walk(source_folder):
        for file in files:
            # Recreate the relative path in the destination
            relative_path = os.path.relpath(root, source_folder)
            target_dir = os.path.join(destination_folder, relative_path)

            # Ensure target directory exists
            os.makedirs(target_dir, exist_ok=True)

            # Copy file
            shutil.copy2(os.path.join(root, file), os.path.join(target_dir, file))

    print(f"Copied from source_folder {source_folder}\n to destination_folder {destination_folder}")

except Exception as e:
    print(f"Error: {e}")
    traceback.print_exc()   

# # Move directories of files with removed background
# import shutil

# for path in image_paths:
#     xml_path = path + '.xml'
#     try:
#         if os.path.exists(xml_path):
#             image_path = os.path.dirname(xml_path)
#             image_path = os.path.dirname(image_path)
#             old_cohort_path = os.path.dirname(image_path)
#             image_name = os.path.basename(image_path)
#             cohort_name = os.path.basename(old_cohort_path)
#             # Make it the new path
#             if not os.path.exists(tracking_path):
#                 os.mkdir(tracking_path)
#             new_cohort_path = os.path.join(tracking_path, cohort_name)
#             if not os.path.exists(new_cohort_path):
#                 os.mkdir(new_cohort_path)
#             shutil.copy(image_path, new_cohort_path)
#             if len(list(os.walk(old_cohort_path))[1:]) == 0:
#                 shutil.rmtree(old_cohort_path)
#     except Exception as e:
#         print('Image already transferred')
#         print(f"Error: {e}")
#         traceback.print_exc()
#         #pass

# time.sleep(3)
