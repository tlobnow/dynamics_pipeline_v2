import pandas as pd
import os
# To prevent truncating paths
pd.options.display.max_colwidth = 10000

def get_ligand_images(parameter_tables):
    # Get directory paths
    directory_list = os.path.join(parameter_tables, 'directories.csv')
    directory_list = pd.read_csv(directory_list)

    # Input path
    input_path = directory_list.loc[directory_list['contains'] == 'input']['path']
    input_path = input_path.to_string(index=False).strip()

    # Ligand processing path
    processing_path = directory_list.loc[directory_list['contains'] == 'processing']['path']
    processing_path = processing_path.to_string(index=False).strip()
    # Create if it doesn't exist
    if not os.path.exists(processing_path):
        os.makedirs(processing_path)
    ligand_processing_path = os.path.join(processing_path, '00_Ligand')
    # Create if it doesn't exist
    if not os.path.exists(ligand_processing_path):
        os.makedirs(ligand_processing_path)

    # Output path
    output_path = directory_list.loc[directory_list['contains'] == 'output']['path']
    output_path = output_path.to_string(index=False).strip()
    # Create if it doesn't exist
    if not os.path.exists(output_path):
        os.makedirs(output_path)

    # Get ligand table
    ligand_list = os.path.join(parameter_tables, 'ligand.csv')
    ligand_list = pd.read_csv(ligand_list)

    # Get dates
    # Get paths
    # Combine directory with image name
    ligand_list = ligand_list.assign(
        img_input_path=lambda dataframe: dataframe['image'].map(lambda image: os.path.join(input_path, image)),
        image=lambda dataframe: dataframe['image'].map(lambda image: os.path.splitext(image)[0]),
        img_processing_path=lambda dataframe: dataframe['image'].map(lambda image: os.path.join(ligand_processing_path, image))
    )
    ligand_list = ligand_list.assign(
        tiff_path=ligand_list.apply(lambda dataframe: os.path.join(ligand_processing_path, dataframe['image'], dataframe['protein_name'] + '.tif'), axis=1),
        xml_path=ligand_list.apply(lambda dataframe: os.path.join(ligand_processing_path, dataframe['image'], dataframe['protein_name'] + '.xml'), axis=1),
        date=lambda dataframe: dataframe['image'].map(lambda image: image[:8])
    )

    return ligand_list
