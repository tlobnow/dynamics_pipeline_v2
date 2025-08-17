'''
# Run ligand
import ligand.parameters
import ligand.operations
try:
    # Get ligand parameters
    ligand_list = ligand.parameters.get_ligand_images(parameter_tables)
    # Get number of images to separate
    n_ligand_images = len(ligand_list)
    n_ligand_images = range(0, n_ligand_images)
    # Run in parallel
    ray.init(num_cpus=use_x_cpus)
    result_ids = []
    for image_x in n_ligand_images:
        try:
            # Get parameters
            image_x_path = ligand_list['img_input_path'][image_x]
            tiff_path = ligand_list['tiff_path'][image_x]
            img_processing_path = ligand_list['img_processing_path'][image_x]
            ligand_puncta_radius = int(ligand_list['puncta_diameter'][image_x] / 2)
            ligand_puncta_radius = ligand_puncta_radius if ligand_puncta_radius > 2 else 3
            if os.path.exists(image_x_path):
                # Run if nd2
                if os.path.splitext(os.path.basename(image_x_path))[1] == '.nd2':
                    result_id = ligand.operations.make_tiff.remote(image_x_path, img_processing_path, tiff_path,
                                                                   ligand_puncta_radius)
                    result_ids.append(result_id)
                else:
                    print('File is not ND2: ' + image_x_path)
            else:
                print('ND2 does not exist: ' + image_x_path)
        except:
            print('Error with make_tiff of image_x = ' + image_x)
    results = settings.parallel.ids_to_vals(result_ids)
    print(results)
    ray.shutdown()

    # Send to terminal
    for image_x in n_ligand_images:
        # Get parameters
        protein_path = ligand_list.xml_path[image_x]
        puncta_diameter = ligand_list.puncta_diameter[image_x]
        image_path = ligand_list.tiff_path[image_x]
        trackmate_threshold = ligand_list.trackmate_threshold[image_x]
        trackmate_frame_gap = ligand_list.trackmate_frame_gap[image_x]
        trackmate_max_link_distance = ligand_list.trackmate_max_link_distance[image_x]
        trackmate_gap_link_distance = puncta_diameter * 1.5
        # Run
        if os.path.exists(image_path):
            ligand.operations.trackmate(imagej, protein_path, image_path, trackmate_threshold, trackmate_frame_gap,
                                        trackmate_max_link_distance,
                                        trackmate_gap_link_distance, puncta_diameter)

    try:
        # Get R script path
        R_script_path = os.path.dirname(os.path.realpath(__file__))
        R_script_path = os.path.join(R_script_path, 'ligand', 'get_density.R')
        call(['Rscript', '--vanilla', '--verbose', R_script_path, parameter_tables])
    except:
        print('Failed get_density.R')
except:
    print('Could not analyze ligand images')
'''
