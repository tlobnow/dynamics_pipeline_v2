import math, ray, tifffile, os, time
import numpy as np
import cv2 as cv
import matplotlib.pyplot as plt
import pandas as pd
import traceback


@ray.remote
def segment(segment_image, cell_diameter, tiff_compression_level):
    try:
        # Import images
        img = tifffile.imread(segment_image)

        # Max pixel intensity
        img_max = np.max(img, axis=0)
        # Convert to 8-bit
        img_max = img_max - img_max.min()
        img_max = img_max / img_max.max() * 255
        img_max = img_max.astype(np.uint8)

        # Average pixel intensity
        img = np.mean(img, axis=0)
        img = np.round(img)
        # Convert to 8-bit
        img = img - img.min()
        img = img / img.max() * 255
        img = img.astype(np.uint8)

        # Create mask (background vs foreground)
        # Adjust contrast
        contrast_img = img.astype(np.uint16)
        contrast_img = contrast_img * 10
        contrast_img = np.clip(contrast_img, 0, 255)
        contrast_img = contrast_img - contrast_img.min()
        contrast_img = contrast_img / contrast_img.max() * 255
        contrast_img = contrast_img.astype(np.uint8)
        # Blur image
        blur_img = cv.blur(contrast_img, (cell_diameter * 3, cell_diameter * 3))
        blur_img = blur_img * 0.5
        blur_img = blur_img.astype(np.uint8)
        # Median image
        median_img = cv.medianBlur(contrast_img, ksize=cell_diameter)
        # Subtract blurs
        subtracted_img = cv.subtract(median_img, blur_img)

        # Dilate maxima
        kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (cell_diameter * 3, cell_diameter * 3))
        dilated_img = cv.dilate(subtracted_img, kernel, iterations=1)

        # Gamma correct image again to make dim objects brighter
        mid = 1
        mean = np.mean(dilated_img)
        gamma = math.log(mid * 255) / math.log(mean)
        gamma_img = np.power(dilated_img, gamma).clip(0, 255).astype(np.uint8)

        # Make binary applying a threshold
        ret, mask_img = cv.threshold(gamma_img, 1, 255, cv.THRESH_BINARY + cv.THRESH_OTSU)
        mask_img_color = cv.cvtColor(mask_img, cv.COLOR_GRAY2BGR)

        # Create marker
        # Adjust contrast
        contrast_img = img_max.astype(np.uint16)
        contrast_img = contrast_img * 6.67
        contrast_img = np.clip(contrast_img, 0, 255)
        contrast_img = contrast_img - contrast_img.min()
        contrast_img = contrast_img / contrast_img.max() * 255
        contrast_img = contrast_img.astype(np.uint8)

        # Blur image
        blur_img = cv.blur(contrast_img, (cell_diameter * 3, cell_diameter * 3))
        # Median image
        median_img = cv.medianBlur(contrast_img, ksize=cell_diameter)
        # Subtract blurs
        subtracted_img = cv.subtract(median_img, blur_img)
        # Gamma correct image
        gamma_img = np.power(subtracted_img, 1.5).clip(0, 255).astype(np.uint8)
        # Median blur to remove noise
        median_img_2 = cv.medianBlur(gamma_img, ksize=cell_diameter)

        # Marker labelling
        ret, marker_img = cv.connectedComponents(median_img_2)

        # Segment
        final_segmentation = cv.watershed(mask_img_color, marker_img)
        final_segmentation.astype(np.uint8)
        # Eliminate background
        final_segmentation = marker_img * (mask_img / 255)
        final_segmentation = final_segmentation.clip(0, 254)
        final_segmentation = final_segmentation.astype('uint8')
        # Save
        # Create folders
        image_path = os.path.dirname(segment_image)
        segmentation_output_path = os.path.join(image_path, 'Segmentation.tif')
        tifffile.imwrite(segmentation_output_path, final_segmentation, bigtiff=True, compression=tiff_compression_level, dtype=final_segmentation[0].dtype)

        # Plot over image
        # Find edges
        final_segmentation[final_segmentation > 0] = [255]
        # Erode Image
        kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (3, 3))
        eroded_img = cv.erode(final_segmentation, kernel, iterations=1)
        eroded_img[eroded_img < 1] = [0]
        eroded_img = eroded_img.astype(np.uint8)
        # Subtract
        eroded_img = final_segmentation - eroded_img
        eroded_img[eroded_img != 0] = [255]
        # Adjust contrast
        contrast_img = img.astype(np.uint16)
        contrast_img = contrast_img * 3
        contrast_img = contrast_img - np.mean(contrast_img)
        contrast_img = np.clip(contrast_img, 0, 255)
        contrast_img = contrast_img - contrast_img.min()
        contrast_img = contrast_img / contrast_img.max() * 255
        final_segmentation_img = contrast_img.astype(np.uint8)
        # Add boundaries
        final_segmentation_img[eroded_img == 255] = [255]

        plt.imshow(final_segmentation_img, cmap='inferno')
        overlay_file = os.path.join(image_path, 'Segmentation.png')
        plt.savefig(overlay_file)

        return segmentation_output_path
    except Exception as e:
        print('segment error') ; print(f"Error: {e}") ; traceback.print_exc()
        pass

@ray.remote
def make_substacks(substack_segmentation_image, substack_image, puncta_diameter, tiff_compression_level):
    try:
        # Import images
        input_image = tifffile.imread(substack_image)
        if os.path.exists(substack_segmentation_image):
            segmentation_image = tifffile.imread(substack_segmentation_image)
            # Get cell count
            n_cells = segmentation_image.max()
            n_cells = range(1, int(n_cells))

            # Get frame count
            frames = input_image.shape[0]
            frames = range(0, frames)

            # Get cells larger than puncta area
            area_results = []
            for cell_x in n_cells:
                result = sum(sum(segmentation_image == cell_x))
                result = result > puncta_diameter ** 2
                area_results.append(result)
            area_results = np.where(area_results)[0] + 1

            for cell_x in area_results:
                try:
                    # Get cell masks
                    cell_x_mask = segmentation_image == cell_x

                    # Crop cell
                    i, j = np.where(cell_x_mask)
                    indexes = np.meshgrid(np.arange(min(i), max(i) + 1), np.arange(min(j), max(j) + 1), indexing='ij')

                    # Run in parallel
                    cropped_img = []
                    for frame_x in frames:
                        cell_x_img = input_image[frame_x]
                        cutout_img = cell_x_img * cell_x_mask
                        cropped_frame_img = cutout_img[tuple(indexes)]
                        cropped_img.append(cropped_frame_img)
                    # Save image
                    save_path = os.path.dirname(substack_image)
                    cell_path = np.where(area_results == cell_x)[0][0] + 1
                    cell_path = 'Cell_' + cell_path.__str__()
                    cell_path = os.path.join(save_path, cell_path)
                    # Create cell path if it doesn't exist
                    if not os.path.exists(cell_path):
                        os.mkdir(cell_path)
                    # Save name
                    save_name = os.path.basename(substack_image)
                    save_path = os.path.join(cell_path, save_name)
                    # Save image
                    tifffile.imwrite(save_path, cropped_img, bigtiff=False, compression=tiff_compression_level, dtype=cropped_img[0].dtype)
                    time.sleep(3)
                except Exception as e:
                    print('Error making substack: ' + substack_image + 'Cell_' + cell_x) ; print(f"Error: {e}") ; traceback.print_exc()
                    pass
        else:
            # Save image
            save_path = os.path.dirname(substack_image)
            cell_path = os.path.join(save_path, 'Cell_1')
            # Create cell path if it doesn't exist
            if not os.path.exists(cell_path):
                os.mkdir(cell_path)
            # Save name
            save_name = os.path.basename(substack_image)
            save_path = os.path.join(cell_path, save_name)
            # Save image
            tifffile.imwrite(save_path, input_image, bigtiff=False, compression=tiff_compression_level, dtype=input_image[0].dtype)
            time.sleep(3)
    except Exception as e:
        print('make_substacks error') ; print(f"Error: {e}") ; traceback.print_exc()
        pass

@ray.remote
def make_area_list(substack_segmentation_image, puncta_diameter):
    try:
        # Save table
        image_path = os.path.dirname(substack_segmentation_image)
        save_path = os.path.join(image_path, 'cell_area.csv')

        if os.path.exists(substack_segmentation_image):
            segmentation_image = tifffile.imread(substack_segmentation_image)
            # Get cell count
            n_cells = segmentation_image.max()
            n_cells = range(1, int(n_cells))
            # Get number of rows
            n_rows = range(0, segmentation_image.shape[0])

            # Get cells larger than puncta area
            area_results = []
            min_x_results = []
            min_y_results = []
            for cell_x in n_cells:
                # Get area
                area = sum(sum(segmentation_image == cell_x))
                if area > puncta_diameter ** 2:
                    area_results.append(area)
                    # Get x,y coordintes of cell
                    min_x = []
                    min_y = []
                    cell_x_mask = segmentation_image == cell_x
                    for row in n_rows:
                        index = np.argmax(cell_x_mask[row] == True)
                        if not index == 0:
                            min_x.append(index)
                            min_y.append(row)
                    # Get minima
                    min_x = min(min_x) + 1
                    min_x_results.append(min_x)
                    min_y = min(min_y) + 1
                    min_y_results.append(min_y)

            # Get cell folder names
            cell_names = range(1, len(area_results) + 1)
            cell_names = list(cell_names)
            new_cell_names = []
            for cell_name in cell_names:
                cell_name = 'Cell_' + str(cell_name)
                new_cell_names.append(cell_name)
            # Get new cell count
            n_cells = range(0, len(new_cell_names))
            with open(save_path, 'w') as f:
                f.write('cell,area,position_x,position_y\n')
                for cell in n_cells:
                    f.write(new_cell_names[cell] + ',' + str(area_results[cell]) + ',' + str(
                        min_x_results[cell]) + ',' + str(min_y_results[cell]) + '\n')
        else:
            metadata = os.path.join(image_path, 'metadata.csv')
            metadata = pd.read_csv(metadata)
            # Get height
            height = metadata['parameter'] == 'height'
            height = metadata[height]['value']
            height = int(height)
            # Get width
            width = metadata['parameter'] == 'width'
            width = metadata[width]['value']
            width = int(width)
            area = str(height * width)
            # Save table
            with open(save_path, 'w') as f:
                f.write('cell,area,position_x,position_y\n')
                f.write('Cell_1,' + area + ',1,1')
    except Exception as e:
        print('make_substacks error') ; print(f"Error: {e}") ; traceback.print_exc()
        pass
