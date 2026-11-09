"""Loads the parameter tables and resolves the directory layout.

Two structural changes from the original mission_control.py:

1. Paths are derived from the parameter tables folder name (see pipeline.layout)
   instead of being hand-edited per run.

2. The Python stages no longer copy the tree forward at every step. They all
   read and write inside one work directory. That directory is the pipeline's
   tracking folder (<processing>/04_Track), because the R scripts pick the tree
   up from there and move it onward through 05_IntensityExtraction and
   06_Colocalization into the output folder. Python owns everything up to
   04_Track; R owns everything after it.
"""

import csv
import os
import shutil

import settings.global_variables as variables

from pipeline import layout as layout_module
from pipeline.util import log


class ContextError(Exception):
    pass


class Context(object):
    def __init__(self, **kwargs):
        for key, value in kwargs.items():
            setattr(self, key, value)

    @property
    def image_names(self):
        return [self.images_list['image'][i] for i in range(len(self.images_list))]


def _write_sample(path, rows):
    with open(path, 'w', newline='') as handle:
        writer = csv.writer(handle)
        for row in rows:
            writer.writerow(row)
    log('Wrote sample table: ' + path)


def _require(table_path, sample_rows, what):
    """Fail loudly if a required table is missing, leaving a sample behind.

    The original caught this, printed a message and carried on with undefined
    variables. That is how a job ends up "succeeding" with no data.
    """
    if os.path.exists(table_path):
        return
    sample = os.path.join(os.path.dirname(table_path),
                          'sample ' + os.path.basename(table_path))
    _write_sample(sample, sample_rows)
    raise ContextError('Missing required table {} ({}). A sample was written to {}'
                       .format(table_path, what, sample))


def load_context(parameter_tables):
    # --- resolve and materialise the layout -------------------------------
    try:
        layout = layout_module.resolve(parameter_tables)
    except layout_module.LayoutError as e:
        raise ContextError(str(e))

    source_tables = layout['source_tables']

    _require(os.path.join(source_tables, 'images.csv'),
             [['image', 'cohort', 'segment_with', 'ligand', 'trackmate_max_link_distance',
               'channel protein_name', 'channel trackmate_threshold',
               'channel trackmate frame gap'],
              ['yyyymmdd img_name', 'cell_line drug parameters', 'protein_name',
               'x nM search_terms', 'px', 'protein_name', 'signal_noise_theshold', 's']],
             'image list')
    _require(os.path.join(source_tables, 'constants.csv'),
             [['parameter', 'value', 'comments'],
              ['tiff_compression_level', '0', 'out of 10'],
              ['cell_diameter', '25', 'px'],
              ['puncta_diameter', '5', 'px']],
             'constants')
    # dark_frames.csv is normally copied into the run folder by prepare_run.py
    # from the shared copy in 2_parameter_tables. Fall back to that shared copy
    # for runs created before it existed, rather than refusing to start.
    dark_frames_table = os.path.join(source_tables, 'dark_frames.csv')
    if not os.path.exists(dark_frames_table) and layout['root']:
        shared = os.path.join(layout['root'], layout_module.TABLES_DIRNAME,
                              'dark_frames.csv')
        if os.path.exists(shared):
            shutil.copy2(shared, dark_frames_table)
            log('dark_frames.csv was missing from {}; copied the shared one from '
                '{}.'.format(source_tables, shared))
    _require(dark_frames_table,
             [['image', 'exposure'],
              ['20220530 Darkfield 60 ms binned 001.tif', '60 ms'],
              ['20220530 Darkfield 300 ms binned 003.tif', '300 ms']],
             'dark frame list')

    resolved_tables = layout_module.materialise(layout)
    directories_table = os.path.join(resolved_tables, 'directories.csv')

    # --- directories -------------------------------------------------------
    directories = layout['directories']
    input_path = directories.get('input', '')
    output_path = directories.get('output', '')
    dark_frames_path = directories.get('dark_frames', '')
    imagej = directories.get('ImageJ', '')
    processing_path = directories.get('processing', '')

    # The work directory is derived, not taken from processing_paths(). Every
    # stage helper receives it as an argument, so this is the single place that
    # decides where the pipeline writes -- and a stale row in someone's
    # directories.csv cannot move it. It has to be <processing>/04_Track because
    # that is where extract_intensity.R picks the tree up.
    work_path = os.path.join(processing_path, layout_module.TRACK_DIRNAME)

    ligand_path = directories.get('ligand', '')
    if layout['mode'] == 'legacy':
        (input_path, ligand_path, _to_tiff, _bg, _seg, tracking_path,
         output_path, dark_frames_path, imagej) = variables.processing_paths(
            directories_table)
        work_path = tracking_path
    else:
        # Cross-check against the helper module, but do not obey it.
        try:
            reported = variables.processing_paths(directories_table)
            reported_tracking = reported[5]
            if reported_tracking and os.path.abspath(reported_tracking) != \
                    os.path.abspath(work_path):
                log('NOTE: settings.global_variables.processing_paths() reports the '
                    'tracking folder as\n      {}\n      but the pipeline is using\n'
                    '      {}\n      (derived from the processing path, which is '
                    'what the R scripts read).'.format(reported_tracking, work_path))
        except Exception as e:
            log('NOTE: could not cross-check processing_paths(): {}'.format(e))

    if not work_path:
        raise ContextError('Could not resolve a work directory from ' + directories_table)
    if processing_path and not os.path.abspath(work_path).startswith(
            os.path.abspath(processing_path) + os.sep):
        raise ContextError(
            'Work directory {} is not inside the processing folder {}. Refusing '
            'to run: the R scripts would not find the results.'
            .format(work_path, processing_path))
    os.makedirs(work_path, exist_ok=True)

    if not input_path or not os.path.isdir(input_path):
        raise ContextError('Input directory does not exist: ' + str(input_path))

    # --- parameters --------------------------------------------------------
    dark_frames_list = variables.dark_frame_parameters(
        os.path.join(resolved_tables, 'dark_frames.csv'), dark_frames_path)

    images_list, _ = variables.image_parameters(
        os.path.join(resolved_tables, 'images.csv'))
    if len(images_list) == 0:
        raise ContextError('images.csv contains no images: '
                           + os.path.join(source_tables, 'images.csv'))

    tiff_compression_level, cell_diameter, puncta_diameter = variables.constants(
        os.path.join(resolved_tables, 'constants.csv'))

    tolerance_rules = load_tolerance_rules(
        os.path.join(resolved_tables, 'tolerate_failures.csv'))

    exclusion_table = os.path.join(resolved_tables, 'exclusion_channels.csv')
    if os.path.exists(exclusion_table):
        exclusion_channels = variables.exclude_chanels(exclusion_table)
    else:
        exclusion_channels = []
        log('No exclusion_channels.csv found: no channels will be excluded.')

    return Context(
        layout=layout,
        run_name=layout['run_name'],
        parameter_tables=source_tables,
        resolved_tables=resolved_tables,
        processing_path=processing_path,
        input_path=input_path,
        ligand_path=ligand_path,
        work_path=work_path,
        output_path=output_path,
        dark_frames_path=dark_frames_path,
        imagej=imagej,
        images_list=images_list,
        dark_frames_list=dark_frames_list,
        exclusion_channels=exclusion_channels,
        tolerance_rules=tolerance_rules,
        tiff_compression_level=tiff_compression_level,
        cell_diameter=cell_diameter,
        puncta_diameter=puncta_diameter,
    )


DEFAULT_TOLERANCE_RULES = [('Calibrations', ('segment', 'substacks'))]


def load_tolerance_rules(table_path):
    """Stages whose failure is expected for certain images and must not block.

    Calibration images have no cells, so segmentation failing for them is normal
    -- the old pipeline printed the error and carried on. These stages still
    *run* (skipping them starves later stages: tracking_parameters looks for a
    "Calibrations" cohort), but a failure is recorded as `tolerated`, does not
    quarantine the image, and does not fail the job.

    Optional tolerate_failures.csv, in the parameter tables folder:

        match,stages
        Calibrations,segment substacks

    `match` is a cohort name or an exact image name. An empty file tolerates
    nothing; no file at all means the default above.
    """
    if not os.path.exists(table_path):
        log('No tolerate_failures.csv: defaulting to tolerating {} failures for '
            'cohort "Calibrations". Add the file to change this.'
            .format(', '.join(DEFAULT_TOLERANCE_RULES[0][1])))
        return list(DEFAULT_TOLERANCE_RULES)

    rules = []
    with open(table_path, newline='') as handle:
        for row in csv.DictReader(handle):
            match = (row.get('match') or '').strip()
            stages = (row.get('stages') or '').replace(',', ' ').split()
            if match and stages:
                rules.append((match, tuple(stages)))
    log('tolerate_failures.csv: '
        + (', '.join('{} -> {}'.format(m, '/'.join(st)) for m, st in rules)
           or 'nothing tolerated'))
    return rules


def is_tolerated(ctx, image, stage):
    """True when a failure of `stage` for `image` is expected and not fatal."""
    rows = ctx.images_list.loc[ctx.images_list['image'] == image]
    cohort = str(rows.iloc[0]['cohort']) if len(rows) else ''
    for match, stages in getattr(ctx, 'tolerance_rules', []):
        if stage in stages and match in (image, cohort):
            return True
    return False


CRITICAL_COHORTS = ('Calibrations',)


def is_critical(ctx, image):
    """True when the whole batch depends on this image.

    Calibration images are used by track.parameters.tracking_parameters to pair
    exposures, and by the R scripts to convert intensities to molecule counts.
    If one of those fails outright the batch is not analysable, so it is worth
    stopping. A sample image failing costs you that image and nothing else.

    A `critical` column in images.csv (TRUE/FALSE) overrides the cohort default.
    """
    rows = ctx.images_list.loc[ctx.images_list['image'] == image]
    if not len(rows):
        return False
    row = rows.iloc[0]
    for column in ctx.images_list.columns:
        if str(column).strip().lower() == 'critical':
            value = str(row[column]).strip().upper()
            if value in ('TRUE', 'YES', '1'):
                return True
            if value in ('FALSE', 'NO', '0'):
                return False
    return str(row['cohort']) in CRITICAL_COHORTS


def image_folder(ctx, image):
    """Where this image's working files live."""
    rows = ctx.images_list.loc[ctx.images_list['image'] == image]
    if not len(rows):
        return None
    return os.path.join(ctx.work_path, str(rows.iloc[0]['cohort']), image)


def tree_state(folder):
    """(path, size, mtime) for every file below `folder`, for change detection."""
    if not folder or not os.path.isdir(folder):
        return set()
    state = set()
    for root, _dirs, files in os.walk(folder):
        for name in files:
            path = os.path.join(root, name)
            try:
                info = os.stat(path)
            except OSError:
                continue
            state.add((path, info.st_size, int(info.st_mtime)))
    return state


def sync_summary(ctx):
    return layout_module.sync_summary(
        ctx.layout['directories'], ctx.work_path, ctx.resolved_tables,
        expected_images=ctx.image_names)


def describe(ctx):
    return '\n'.join([
        layout_module.describe(ctx.layout),
        'work (python)    : ' + str(ctx.work_path),
        'images selected  : ' + str(len(ctx.images_list)),
        'excluded channels: ' + str(list(ctx.exclusion_channels)),
        'constants        : tiff_compression={} cell_diameter={} puncta_diameter={}'.format(
            ctx.tiff_compression_level, ctx.cell_diameter, ctx.puncta_diameter),
    ])