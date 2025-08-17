import os
import pandas as pd
import traceback


def segmentation_list(images_list, file_ending, background_remove_path):
    try:
        n_images = range(0, len(images_list))
        # Add to_tiff_path
        segmentation_image_list = []
        for image_x in n_images:
            segmentation_image = images_list['segment_with'][image_x] + file_ending

            if not images_list['cohort'][image_x] == 'Calibrations':
                segmentation_image = os.path.join(background_remove_path, images_list['relative_path'][image_x],
                                                  segmentation_image)
                if os.path.exists(segmentation_image):
                    segmentation_image_list.append(segmentation_image)

        return segmentation_image_list
    except Exception as e:
        print('segmentation_list error') ; print(f"Error: {e}") ; traceback.print_exc()
        pass

def substack_list(images_list, exclusion_channels, background_remove_path, file_ending):
    try:
        n_images = range(0, len(images_list))
        substack_image_list = []
        substack_segmentation_images = []
        for image_x in n_images:
            relative_path = images_list['relative_path'][image_x]
            image_path = os.path.join(background_remove_path, relative_path)
            csv_path = os.path.join(image_path, 'channels_metadata.csv')
            segmentation_image = os.path.join(image_path, 'Segmentation.tif')
            if os.path.exists(csv_path):
                channel_metadata = pd.read_csv(csv_path)
                protein_names = channel_metadata['protein_name']
                protein_names = list(protein_names)
                protein_names = [x for x in protein_names if x not in exclusion_channels]
                protein_names.append('Combined')
                print(protein_names)
                for protein_name in protein_names:
                    for ending in file_ending:
                        substack_image = os.path.join(image_path, protein_name + ending)
                        if os.path.exists(substack_image):
                            substack_image_list.append(substack_image)
                            substack_segmentation_images.append(segmentation_image)

        return substack_segmentation_images, substack_image_list
    except Exception as e:
        print('substack_list error') ; print(f"Error: {e}") ; traceback.print_exc()
        pass
