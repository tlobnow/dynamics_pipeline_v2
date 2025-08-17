import tifffile, ray, settings, time, os
import cv2 as cv # Install as opencv-python
import numpy as np
from scipy import ndimage
import traceback

@ray.remote
def remove_frame(image_path, frame_path, tiff_compression_level):
    try:
        # Save name
        path = os.path.dirname(image_path)
        file = os.path.basename(image_path)
        file = os.path.splitext(file)[0] + '_darkframe_removed.tif'
        save_image_path = os.path.join(path, file)
        # Import images
        original_image = tifffile.imread(image_path)
        frame_image = tifffile.imread(frame_path)

        # Subtract images
        # Get frame count
        frames = original_image.shape[0]
        frames = range(0, frames)
        # Subtract
        frame_removed_image = []
        for t in frames:
            frame_removed = original_image[t]
            frame_removed = cv.subtract(frame_removed, frame_image)
            frame_removed_image.append(frame_removed)
        # Save image
        tifffile.imwrite(save_image_path, frame_removed_image, bigtiff=True, compression=tiff_compression_level, dtype=frame_removed_image[0].dtype)
        time.sleep(5)
        return save_image_path
    except Exception as e:
        print("Cannot complete remove") ; print(f"Error: {e}") ; traceback.print_exc()
        pass


@ray.remote
def median_blur_remove(img, median_filter_size):
    try:
        # Remove blur
        med = ndimage.median_filter(img, size=median_filter_size)
        med_rm = img - np.minimum(med, img)

        return med_rm
    except Exception as e:
        print('median_blur_remove error') ; print(f"Error: {e}") ; traceback.print_exc()
        pass

def remove_median_blur(image_path, old_term, new_term, median_size, tiff_compression_level):
    try:
        # Save name
        path = os.path.dirname(image_path)
        file = os.path.basename(image_path)
        file = os.path.splitext(file)[0]
        file = file.replace(old_term, new_term) + '.tif'
        save_image_path = os.path.join(path, file)

        # Import image
        original_image = tifffile.imread(image_path)

        # Get frame count
        frames = original_image.shape[0]
        frames = range(0, frames)

        # Run in parallel
        ray.shutdown()
        ray.init()
        result_ids = []
        for frame in frames:
            result_id = median_blur_remove.remote(original_image[frame], median_size)
            result_ids.append(result_id)
        med_rm_img = settings.parallel.ids_to_vals(result_ids)

        # Save image
        tifffile.imwrite(save_image_path, med_rm_img, bigtiff=True, compression=tiff_compression_level, dtype=med_rm_img[0].dtype)
        time.sleep(10)
        ray.shutdown()
        time.sleep(10)
        return save_image_path
    except Exception as e:
        print("Cannot complete remove") ; print(f"Error: {e}") ; traceback.print_exc()
        pass


@ray.remote
def tracking_image(median_image_path, old_term, new_term, median_size, tiff_compression_level):
    try:
        # Save name
        path = os.path.dirname(median_image_path)
        file = os.path.basename(median_image_path)
        file = os.path.splitext(file)[0]
        file = file.replace(old_term, new_term) + '.tif'
        save_image_path = os.path.join(path, file)

        # Import image
        original_image = tifffile.imread(median_image_path)

        # Get frame count
        frames = original_image.shape[0]
        frames = range(0, frames)

        # Blur image
        median_imgs = []
        for frame in frames:
            median_img = ndimage.median_filter(original_image[frame], size=median_size)
            median_imgs.append(median_img)

        # Average frames
        frames = original_image.shape[0]
        frames = range(1, frames-1)
        moving_avg_imgs = []
        for frame in frames:
            moving_avg_img = (median_imgs[frame - 1], median_imgs[frame], median_imgs[frame + 1])
            moving_avg_img = np.array(np.mean(moving_avg_img, axis=0))
            moving_avg_imgs.append(moving_avg_img)

        # Save image
        tifffile.imwrite(save_image_path, moving_avg_imgs, bigtiff=True, compression=tiff_compression_level, dtype=original_image[0].dtype)
        time.sleep(5)
        return save_image_path
    except Exception as e:
        print("Cannot complete remove") ; print(f"Error: {e}") ; traceback.print_exc()
        pass


@ray.remote
def combine_images(input_images, output_image, tiff_compression_level):
    try:
        n_inputs = len(input_images)
        n_inputs = range(0, n_inputs)
        existing_images = []
        for x in n_inputs:
            if os.path.exists(input_images[x]):
                existing_images.append(input_images[x])

        # Import image
        channels = len(existing_images)
        channels = range(0, channels)

        for c in channels:
            original_image = tifffile.imread(existing_images[c])
            if c == 0:
                summed_image = original_image
            else:
                summed_image = cv.add(summed_image, original_image)

        # Save image
        tifffile.imwrite(output_image, summed_image, bigtiff=True, compression=tiff_compression_level, dtype=original_image[0].dtype)
        time.sleep(5)
        return output_image
    except Exception as e:
        print("Cannot complete combine_images") ; print(f"Error: {e}") ; traceback.print_exc()
        pass
