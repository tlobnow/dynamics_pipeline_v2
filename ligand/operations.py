'''
Converts ND2 file to multi-page TIFF
'''

import shutil, warnings, ray, tifffile, os, time
from pims_nd2 import ND2_Reader  # Install as pims-nd2
import numpy as np
import cv2 as cv
from scipy import ndimage
from subprocess import call


def flatten_dictionary(dd, separator='_', prefix=''):
    return {prefix + separator + k if prefix else k: v
            for kk, vv in dd.items()
            for k, v in flatten_dictionary(vv, separator, kk).items()
            } if isinstance(dd, dict) else {prefix: dd}


def nearest_date(array, value):
    return min(array, key=lambda x: abs(x - value))


@ray.remote
def make_tiff(image_x_path, img_processing_path, tiff_path, ligand_puncta_radius):
    try:
        warnings.filterwarnings("ignore")
        img = ND2_Reader(image_x_path)
        warnings.filterwarnings("default")
    except:
        print('Cannot open ND2 image')

    try:
        save_path = img_processing_path
        # Create if it doesn't exist
        if not os.path.exists(save_path):
            os.makedirs(save_path)
    except:
        print('Cannot create image path')

    try:
        '''
        # Save metadata to text file
        file = os.path.join(save_path, 'metadata.txt')
        file = open(file, 'w')
        file.write(img.metadata_text)
        file.close()
        '''

        # Save metadata to csv
        img_metadata = flatten_dictionary(img.metadata)
        with open(os.path.join(save_path, 'metadata.csv'), 'w') as f:
            f.write('parameter,value,value2,value3\n')
            for key in img_metadata.keys():
                f.write('%s,%s\n' % (key, img_metadata[key]))
    except:
        print('Metadata error')

    try:
        # Get frame count
        n_frames = img.sizes['t'] - 1
        frames = range(0, n_frames)

        img_frames = []
        for t in frames:
            orig = img.get_frame_2D(c=0, x=0, y=0, t=t)
            img_frames.append(orig)

        # Avg pixel intensity
        img_min = np.min(img_frames, axis=0)
        img_max = np.max(img_frames)
        img_subtracted = []
        for t in frames:
            img_frame = img_frames[t]
            img_frame = cv.subtract(img_frame, img_min)
            img_frame = (img_frame / img_max * 255).astype('uint8')
            img_subtracted.append(img_frame)

        # Median blur
        median_img = []
        for t in frames:
            frame_image = img_subtracted[t]
            median = ndimage.median_filter(frame_image, size=(ligand_puncta_radius * 2 + 1))
            med_rm = frame_image - np.minimum(median, frame_image)
            med = ndimage.median_filter(med_rm, size=(ligand_puncta_radius - 2))
            median_img.append(med)

        # Save file
        tifffile.imsave(tiff_path, median_img, bigtiff=False, dtype='uint8')

    except:
        print('Cannot process image')

    try:
        # Move ND2 file once finished
        shutil.move(image_x_path, img_processing_path)
        # Clos e image
        img.close()
        time.sleep(5)
    except:
        print('Cannot move processed nd2 file')

    return image_x_path


def trackmate(imagej, protein_path, image_path, trackmate_threshold, trackmate_frame_gap, trackmate_max_link_distance,
              trackmate_gap_link_distance, puncta_diameter):
    # Get macro path
    macro_path = os.getcwd()
    macro_path = os.path.join(macro_path, 'ligand', 'run_trackmate.ijm')
    # Numbers to string
    trackmate_threshold = str(trackmate_threshold)
    trackmate_frame_gap = str(trackmate_frame_gap)
    trackmate_max_link_distance = str(trackmate_max_link_distance)
    trackmate_gap_link_distance = str(trackmate_gap_link_distance)
    puncta_diameter = str(puncta_diameter)

    # Execute
    separator = '\n'
    call([imagej, '--headless', '--console', '-macro', macro_path,
          protein_path + separator + image_path + separator +
          trackmate_threshold + separator + trackmate_frame_gap + separator + trackmate_max_link_distance + separator + trackmate_gap_link_distance + separator +
          puncta_diameter])

    return image_path
