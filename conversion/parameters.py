import os, tifffile


# Channel names
def get_channels_table(images_list):
    try:
        # Get columns with channel and protein names
        protein_names_cols = [col for col in images_list.columns if ' protein_name' in col]
        # Channels
        channels_table = images_list[protein_names_cols]
        channels_table.columns = [col.replace(' protein_name', '') for col in channels_table.columns]
        # Add image name
        channels_table = channels_table.assign(
            image=list(images_list['image']),
            date=list(images_list['date'])
        )
        return channels_table
    except:
        print('get_channels_table error')
        pass

# Function to extract images for a channel
def get_original_img(img, n_frames, channel):
    try:
        frames = range(0, n_frames)
        all_orig = []
        for t in frames:
            orig = img.get_frame_2D(c=channel, x=0, y=0, t=t)
            all_orig.append(orig)
        return all_orig
    except:
        print('original error')
        pass

# Function to save splitted channel
def save_channel_img(img, images_list, n_frames, channel, channel_names, image_x, save_path, tiff_compression_level):
    try:
        # Get image
        img_channel = get_original_img(img, n_frames, channel)
        # Save file
        protein_x = images_list[channel_names[channel]][image_x]
        out_name = protein_x + '.tif'
        out_path = os.path.join(save_path, out_name)
        tifffile.imwrite(out_path, img_channel, bigtiff=True, compression=tiff_compression_level, dtype=img_channel[0].dtype)
        return out_path
    except:
        print('save_channel_img error')
        pass

