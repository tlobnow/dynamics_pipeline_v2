// PARAMETERS
// Get parameters
args = split(getArgument(),"\n");

xml_save_path = args[0]
print('xml_path: ' + xml_save_path)

image_path = args[1]
print('image_path: ' + image_path)

trackmate_threshold = args[2]
print('trackmate_threshold: ' + trackmate_threshold)

trackmate_frame_gap = args[3]
print('trackmate_frame_gap: ' + trackmate_frame_gap)

trackmate_max_link_distance = args[4]
print('trackmate_max_link_distance: ' + trackmate_max_link_distance)

trackmate_gap_link_distance = args[5]
print('trackmate_gap_link_distance: ' + trackmate_gap_link_distance)

puncta_diameter = args[6]
print('puncta_diameter: ' + puncta_diameter)
puncta_diameter = parseFloat(puncta_diameter)
puncta_radius = puncta_diameter/2

// Open image
open(image_path);

// Switch z with t
run("Re-order Hyperstack ...", "channels=[Channels (c)] slices=[Frames (t)] frames=[Slices (z)]");

//Run trackmate
run('TrackMate', "use_gui=false "
+ "save_to=["+ xml_save_path + "] "
+ "display_results=false "
+ "radius="+ puncta_radius +" "
+ "threshold=" + trackmate_threshold + " "
+ "subpixel=true "
+ "median=false "
+ "channel=1 "
+ "max_distance="+ trackmate_max_link_distance +" "
+ "max_gap_distance="+ trackmate_gap_link_distance +" "
+ "max_frame_gap="+ trackmate_frame_gap +" " );
