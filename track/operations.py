import os
from subprocess import call
import traceback


def trackmate(imagej, protein_path, image_path, trackmate_threshold, trackmate_frame_gap, trackmate_max_link_distance, trackmate_gap_link_distance, puncta_diameter):
    try:
        # Get macro path
        macro_path = os.getcwd()
        macro_path = os.path.join(macro_path, 'track', 'run_trackmate.ijm')
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

        return image_path + '.xml'
    except Exception as e:
        print('trackmate error')
        pass

