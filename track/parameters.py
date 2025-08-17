import os
import pandas as pd
from datetime import datetime
import traceback


def tracking_list(images_list, exclusion_channels, segmentation_path, input_path, cell_diameter, puncta_diameter):
    try:
        n_images = range(0, len(images_list))
        all_channels_metadata = []
        for image_x in n_images:
            try:
                # Get paths
                relative_path = images_list['relative_path'][image_x]
                image_path = os.path.join(segmentation_path, relative_path)
                image_name = images_list['image'][image_x]
                cohort_name = images_list['cohort'][image_x]

                # Get image parameters
                ligand = images_list['ligand'][image_x]
                ligand_density = images_list['ligand_density'][image_x]
                trackmate_max_link_distance = images_list['trackmate_max_link_distance'][image_x]

                # Get tables to merge
                select_images_list = images_list['image'] == image_name
                select_images_list = list(select_images_list)
                select_images_list = images_list.loc[select_images_list]
                # Get table paths
                channels_csv_path = os.path.join(image_path, 'channels_metadata.csv')
                area_csv_path = os.path.join(image_path, 'cell_area.csv')
                metadata_csv_path = os.path.join(image_path, 'metadata.csv')
                if os.path.exists(channels_csv_path) and os.path.exists(area_csv_path) and os.path.exists(metadata_csv_path):
                    # Get tables
                    metadata = pd.read_csv(metadata_csv_path)
                    width = metadata.loc[metadata['parameter'] == 'width']['value']
                    width = int(width.iloc[0])
                    height = metadata.loc[metadata['parameter'] == 'height']['value']
                    height = int(height.iloc[0])
                    calibration_um = metadata.loc[metadata['parameter'] == 'calibration_um']['value']
                    calibration_um = float(calibration_um.iloc[0])
                    time_start = metadata.loc[metadata['parameter'] == 'time_start']['value']
                    time_start = time_start.to_string(index=False).strip()
                    objective = metadata.loc[metadata['parameter'] == 'objective']['value']
                    objective = objective.to_string(index=False).strip()
                    frame_rate = metadata.loc[metadata['parameter'] == 'frame_rate']['value']
                    frame_rate = float(frame_rate.iloc[0])

                    # Get channel metadata
                    channel_metadata = pd.read_csv(channels_csv_path)
                    # Drop exclusion channels
                    channel_metadata = channel_metadata[
                        ~channel_metadata['protein_name'].isin(exclusion_channels)]

                    channel_metadata = channel_metadata.reset_index()
                    channel_metadata.drop('index', inplace=True, axis=1)

                    cells = pd.read_csv(area_csv_path)
                    image_channels_metadata = []
                    # Get channel parameters
                    for channel_x in range(0, len(channel_metadata)):
                        try:
                            # Channel metadata
                            protein_name = channel_metadata.protein_name[channel_x]
                            select_channel_metadata = channel_metadata.loc[[channel_x]]

                            # Get trackmate parameters
                            trackmate_threshold = select_images_list.trackmate_threshold
                            trackmate_threshold = float(trackmate_threshold.iloc[0])
                            select_channel_metadata['trackmate_threshold'] = trackmate_threshold

                            trackmate_frame_gap = select_images_list.trackmate_frame_gap
                            trackmate_frame_gap = int(trackmate_frame_gap.iloc[0])
                            select_channel_metadata['trackmate_frame_gap'] = trackmate_frame_gap

                            trackmate_gap_link_distance = trackmate_max_link_distance
                            select_channel_metadata['trackmate_gap_link_distance'] = trackmate_gap_link_distance

                            # Get protein image paths
                            protein_relative_paths = []
                            cell_areas = []
                            position_x_list = []
                            position_y_list = []
                            for cell_x in range(0, len(cells)):
                                try:
                                    cell_name = cells.cell[cell_x]

                                    protein_relative_path = os.path.join(relative_path, cell_name, protein_name)
                                    protein_relative_paths.append(protein_relative_path)

                                    cell_area = cells.area[cell_x]
                                    cell_areas.append(cell_area)

                                    position_x = cells.position_x[cell_x]
                                    position_x_list.append(position_x)

                                    position_y = cells.position_y[cell_x]
                                    position_y_list.append(position_y)
                                except Exception as e:
                                    print('tracking_list cell loop error') ; print(f"Error: {e}") ; traceback.print_exc()
                                    pass
                            # Expand rows and incorporate cell data
                            select_channel_metadata = select_channel_metadata.loc[
                                select_channel_metadata.index.repeat(len(cells))]
                            select_channel_metadata['protein_relative_path'] = protein_relative_paths
                            select_channel_metadata['area'] = cell_areas
                            select_channel_metadata['position_x'] = position_x_list
                            select_channel_metadata['position_y'] = position_y_list
                            select_channel_metadata['ligand'] = ligand
                            select_channel_metadata['ligand_density'] = ligand_density
                            select_channel_metadata['cohort'] = cohort_name
                            select_channel_metadata['trackmate_max_link_distance'] = trackmate_max_link_distance
                            select_channel_metadata['width'] = width
                            select_channel_metadata['height'] = height
                            select_channel_metadata['calibration_um'] = calibration_um
                            select_channel_metadata['time_start'] = time_start
                            select_channel_metadata['objective'] = objective
                            select_channel_metadata['frame_rate'] = frame_rate
                            select_channel_metadata['puncta_diameter'] = puncta_diameter
                            select_channel_metadata['cell_diameter'] = cell_diameter
                            select_channel_metadata['segment_with'] = images_list['segment_with'][image_x]

                            all_channels_metadata.append(select_channel_metadata)
                            image_channels_metadata.append(select_channel_metadata)
                        except Exception as e:
                            print('tracking_list channel error') ; print(f"Error: {e}") ; traceback.print_exc()
                            pass

                    # Save
                    image_channels_metadata = pd.concat(image_channels_metadata)
                    csv_name = os.path.join(image_path, 'summmary.csv')
                    image_channels_metadata.to_csv(csv_name, index=False)
            except Exception as e:
                print('tracking_list image loop error') ; print(f"Error: {e}") ; traceback.print_exc()
                pass
        # Concatenate
        all_channels_metadata = pd.concat(all_channels_metadata)
        all_channels_metadata = all_channels_metadata.reset_index()
        all_channels_metadata.drop('index', inplace=True, axis=1)

        # Double checking to remove exclusion channels
        all_channels_metadata = all_channels_metadata[~all_channels_metadata['protein_name'].isin(exclusion_channels)]
        # Make it a csv
        csv_name = os.path.join(input_path, 'summary.csv')
        all_channels_metadata.to_csv(csv_name, index=False)
        now = datetime.now()
        now = now.strftime("%Y%m%d %H:%M:%S")

        csv_name = os.path.join(input_path, 'summary ' + now + '.csv')
        all_channels_metadata.to_csv(csv_name, index=False)

        return all_channels_metadata
    except Exception as e:
        print('tracking_list error') ; print(f"Error: {e}") ; traceback.print_exc()
        pass

def tracking_parameters(all_channels_metadata, file_ending, segmentation_path):
    try:
        calibration_table = all_channels_metadata.loc[all_channels_metadata['cohort'] == 'Calibrations']
        experimental_table = all_channels_metadata.loc[all_channels_metadata['cohort'] != 'Calibrations']
        experimental_table = experimental_table[['protein_name', 'protein_relative_path', 'trackmate_threshold', 'trackmate_frame_gap', 'trackmate_gap_link_distance', 'trackmate_max_link_distance']]
        experimental_table['protein_name'] = 'Combined'

        experimental_table = experimental_table.assign(protein_relative_path=lambda dataframe: dataframe['protein_relative_path'].map(lambda path: os.path.dirname(path)))
        experimental_table = experimental_table.assign(protein_relative_path=lambda dataframe: dataframe['protein_relative_path'].map(lambda path: os.path.join(path, 'Combined')))
        experimental_table = experimental_table.drop_duplicates()

        all_channels_metadata = pd.concat([experimental_table, calibration_table], ignore_index=True)
        all_channels_metadata = all_channels_metadata.reset_index(drop=True)

        protein_paths = []
        image_paths = []
        trackmate_thresholds = []
        trackmate_frame_gaps = []
        trackmate_max_link_distances = []
        trackmate_gap_link_distances = []
        n_trackings = range(len(all_channels_metadata))

        for row in n_trackings:
            relative_path = all_channels_metadata['protein_relative_path'][row]

            protein_path = os.path.join(segmentation_path, relative_path)
            protein_paths.append(protein_path)

            image_path = protein_path + file_ending
            image_paths.append(image_path)

            trackmate_threshold = all_channels_metadata['trackmate_threshold'][row]
            trackmate_thresholds.append(trackmate_threshold)

            trackmate_frame_gap = all_channels_metadata['trackmate_frame_gap'][row]
            trackmate_frame_gaps.append(trackmate_frame_gap)

            trackmate_max_link_distance = all_channels_metadata['trackmate_max_link_distance'][row]
            trackmate_max_link_distances.append(trackmate_max_link_distance)

            trackmate_gap_link_distance = all_channels_metadata['trackmate_gap_link_distance'][row]
            trackmate_gap_link_distances.append(trackmate_gap_link_distance)

        return n_trackings, image_paths, protein_paths, trackmate_thresholds, trackmate_frame_gaps, trackmate_max_link_distances, trackmate_gap_link_distances
    except Exception as e:
        print('tracking_parameters error') ; print(f"Error: {e}") ; traceback.print_exc()
        pass