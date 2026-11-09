"""The pipeline stages.

Each stage is a function with the same signature:

    stage(ctx, images_list, image_names, cpus) -> {image_name: (ok, error)}

`images_list` is already filtered down to the images this stage should touch and
re-indexed from 0, so the existing helper modules (conversion.parameters,
background.parameters, ...) can be handed it unchanged and will only build work
for the selected images. That is what makes "rerun just these two images"
possible without editing images.csv.

Nothing in here copies files between directories any more; every stage reads and
writes inside ctx.work_path.
"""

import os

# Side-effect import, and not an optional one. The helper operations reference
# settings.parallel, but only `import settings`, so the attribute exists only if
# something has imported the submodule first. The original mission_control.py
# did that on line 4. Without it remove_median_blur raises AttributeError,
# catches its own exception, prints "Cannot complete remove", and returns
# normally -- so it looks like it worked and writes nothing.
import settings.parallel  # noqa: F401

from pipeline.state import param_hash
from pipeline.util import (UNATTRIBUTED, attribute, fmt_exc, gather, log,
                           merge_results, ray_session)

STAGE_ORDER = [
    'convert',       # nd2 -> tiff
    'darkframe',     # subtract dark frame
    'median',        # intensity_ref + puncta_median_removed
    'tracking_ref',  # blurred / averaged tracking reference
    'combine',       # Combined_tracking_ref
    'segment',       # cell segmentation
    'substacks',     # per-cell substacks + area lists
    'track',         # TrackMate
]

# Which parameters each stage actually depends on. Used to flag a completed
# stage as STALE when you change something in images.csv or constants.csv.
# Column entries are matched as case-insensitive substrings of column names.
STAGE_PARAM_SPEC = {
    'convert':      {'columns': ['image', 'cohort', 'protein_name'],
                     'constants': ['tiff_compression_level']},
    'darkframe':    {'columns': ['image', 'cohort'],
                     'constants': ['tiff_compression_level'], 'dark_frames': True},
    'median':       {'columns': ['image', 'cohort'],
                     'constants': ['tiff_compression_level', 'cell_diameter', 'puncta_diameter'],
                     'exclusion': True},
    'tracking_ref': {'columns': ['image', 'cohort'],
                     'constants': ['tiff_compression_level'], 'exclusion': True},
    'combine':      {'columns': ['image', 'cohort'],
                     'constants': ['tiff_compression_level'], 'exclusion': True},
    'segment':      {'columns': ['image', 'cohort', 'segment_with'],
                     'constants': ['cell_diameter', 'tiff_compression_level']},
    'substacks':    {'columns': ['image', 'cohort', 'segment_with'],
                     'constants': ['puncta_diameter', 'tiff_compression_level'],
                     'exclusion': True},
    'track':        {'columns': ['image', 'cohort', 'segment_with', 'ligand', 'trackmate'],
                     'constants': ['puncta_diameter', 'cell_diameter'], 'exclusion': True},
}


def stage_param_hash(ctx, image_name, stage):
    """Hash of the parameters `stage` depends on, for this image."""
    spec = STAGE_PARAM_SPEC.get(stage, {})
    payload = {'stage': stage}

    rows = ctx.images_list.loc[ctx.images_list['image'] == image_name]
    if len(rows):
        row = rows.iloc[0]
        for column in ctx.images_list.columns:
            lowered = str(column).lower()
            if any(token in lowered for token in spec.get('columns', [])):
                payload['col:' + str(column)] = row[column]

    for name in spec.get('constants', []):
        payload['const:' + name] = getattr(ctx, name, None)

    if spec.get('exclusion'):
        payload['exclusion_channels'] = sorted(str(c) for c in ctx.exclusion_channels)

    if spec.get('dark_frames'):
        try:
            payload['dark_frames'] = sorted(
                str(v) for v in ctx.dark_frames_list['image'].tolist())
        except Exception:
            payload['dark_frames'] = 'unknown'

    return param_hash(payload)


def subset(images_list, names):
    """Filter images_list to `names` and re-index from 0."""
    selected = images_list.loc[images_list['image'].isin(list(names))]
    return selected.reset_index(drop=True)


def check_files(results, expected, what):
    """Turn "the operation printed an error and returned anyway" into a failure.

    The helper operations in conversion/, background/ and segmentation/ wrap
    their bodies in try/except, print "Cannot complete X" and return normally.
    Nothing raises, so ray reports success and the manifest records success --
    and the missing file only surfaces two stages later as something obscure.
    Checking that the files a stage was supposed to write actually exist is the
    only reliable signal available without editing those modules.

    `expected` is a list of (label, path).
    """
    missing = {}
    for label, path in expected:
        if path and not os.path.exists(path):
            missing.setdefault(label, []).append(os.path.basename(path))
    for label, files in missing.items():
        shown = ', '.join(sorted(set(files))[:3])
        if len(set(files)) > 3:
            shown += ' (+{} more)'.format(len(set(files)) - 3)
        results[label] = (False, '{} did not produce: {}'.format(what, shown))
    return results


def require_inputs(results, expected, what):
    """Fail an image up front when the previous stage left nothing to work on."""
    missing = {}
    for label, path in expected:
        if path and not os.path.exists(path):
            missing.setdefault(label, []).append(os.path.basename(path))
    for label, files in missing.items():
        shown = ', '.join(sorted(set(files))[:3])
        if len(set(files)) > 3:
            shown += ' (+{} more)'.format(len(set(files)) - 3)
        results[label] = (False, 'missing input for {}: {}'.format(what, shown))
    return set(missing)


def _submit(results, label, thunk, pairs):
    """Run `thunk` (which returns a ray ref) and record submission failures."""
    try:
        pairs.append((label, thunk()))
    except Exception as e:
        results[label] = (False, fmt_exc(e))


# ---------------------------------------------------------------------------
# Stage 1: nd2 -> tiff
# ---------------------------------------------------------------------------
def link_directory(ctx):
    """Per-run folder of symlinks to the ND2 files this run uses."""
    if not getattr(ctx, 'processing_path', ''):
        return None
    path = os.path.join(ctx.processing_path, '_nd2')
    try:
        os.makedirs(path, exist_ok=True)
    except OSError as e:
        log('  convert: could not create {} ({}); reading ND2s directly from '
            'the shared input folder'.format(path, e))
        return None
    return path


def link_for(link_dir, source, name):
    """Symlink to `source` inside link_dir, falling back to `source` itself."""
    if not link_dir:
        return source
    link = os.path.join(link_dir, name + '.nd2')
    try:
        if os.path.islink(link) or os.path.exists(link):
            if os.path.realpath(link) == os.path.realpath(source):
                return link
            os.remove(link)
        os.symlink(source, link)
        return link
    except OSError:
        # No symlink support (some filesystems), or a race with another job.
        return source


def stage_convert(ctx, images_list, image_names, cpus):
    import conversion.operations
    import conversion.parameters

    results = {}
    channels_table = conversion.parameters.get_channels_table(images_list)
    pairs = []

    # conversion writes summary.csv next to the ND2 it was handed. With one
    # shared 1_input that means every run writes into the same folder and can
    # read back another run's metadata. Handing it a per-run symlink instead
    # puts that file inside this run's processing folder, so concurrent batches
    # cannot see each other's. The ND2 bytes are still read from 1_input.
    link_dir = link_directory(ctx)

    with ray_session(cpus):
        for index in range(len(images_list)):
            name = images_list['image'][index]
            source = os.path.join(ctx.input_path, name + '.nd2')
            if not os.path.exists(source):
                results[name] = (False, 'ND2 not found in master input folder: ' + source)
                continue
            if os.path.splitext(source)[1] != '.nd2':
                results[name] = (False, 'Not an ND2 file: ' + source)
                continue
            image_path = link_for(link_dir, source, name)
            cohort = images_list['cohort'][index]
            channels = channels_table.loc[index]
            _submit(results, name, lambda p=image_path, c=cohort, ch=channels:
                    conversion.operations.nd2_to_tiff.remote(
                        p, c, ch, ctx.work_path, ctx.tiff_compression_level), pairs)
        merge_results(results, gather(pairs))

    for index in range(len(images_list)):
        name = images_list['image'][index]
        folder = os.path.join(ctx.work_path, str(images_list['cohort'][index]), name)
        if not os.path.isdir(folder) or not os.listdir(folder):
            results[name] = (False, 'no TIFFs written to ' + folder)
    return results


# ---------------------------------------------------------------------------
# Stage 2: dark frame subtraction
# ---------------------------------------------------------------------------
def stage_darkframe(ctx, images_list, image_names, cpus):
    import background.operations
    import background.parameters

    results = {}
    n_protein_images, remove_list = background.parameters.background_remove_list(
        images_list, ctx.dark_frames_list, ctx.work_path)
    pairs = []

    with ray_session(cpus):
        for index in n_protein_images:
            image_path = remove_list['image_path'][index]
            dark_frame_path = remove_list['dark_frame'][index]
            label = attribute(image_path, image_names)
            _submit(results, label, lambda p=image_path, d=dark_frame_path:
                    background.operations.remove_frame.remote(
                        p, d, ctx.tiff_compression_level), pairs)
        merge_results(results, gather(pairs))

    # median_remove_list is exactly the set of _darkframe_removed files the next
    # stage will open, so it is the right thing to check against.
    expected = [(attribute(p, image_names), p)
                for p in _median_remove_list(ctx, images_list)]
    check_files(results, expected, 'darkframe')
    return results


def _median_remove_list(ctx, images_list):
    import background.parameters
    _, remove_list = background.parameters.background_remove_list(
        images_list, ctx.dark_frames_list, ctx.work_path)
    return background.parameters.median_remove_list(remove_list, ctx.exclusion_channels)


# ---------------------------------------------------------------------------
# Stage 3: median blur removal (intensity_ref + puncta_median_removed)
# ---------------------------------------------------------------------------
def _median_jobs(ctx, median_list, image_names):
    """(label, image_path, new_term, median_size) for every median-blur call."""
    jobs = []
    for image_path in median_list:
        label = attribute(image_path, image_names)
        jobs.append((label, image_path, '_intensity_ref', ctx.cell_diameter))
        jobs.append((label, image_path, '_puncta_median_removed',
                     ctx.puncta_diameter * 2 + 1))
    return jobs


def _median_serial(ctx, jobs, results):
    import background.operations
    for label, image_path, new_term, median_size in jobs:
        try:
            background.operations.remove_median_blur(
                image_path, '_darkframe_removed', new_term, median_size,
                ctx.tiff_compression_level)
            results.setdefault(label, (True, None))
        except Exception as e:
            results[label] = (False, fmt_exc(e))
    return results


def _looks_like_oom(errors):
    """WorkerCrashedError means the process died, not that the code raised."""
    markers = ('WorkerCrashed', 'OwnerDied', 'OutOfMemory', 'ObjectStoreFull',
               'RayOutOfMemory')
    return any(any(m in (e or '') for m in markers) for e in errors)


def stage_median(ctx, images_list, image_names, cpus, median_parallel=False,
                 median_cpus=None):
    """Median blur removal.

    In the original script this was the one stage called without .remote(), so
    it ran single-threaded on a 72-core node. It is tried in parallel here. If
    the parallel attempt fails, the failing work is retried serially and the
    result of that retry is reported: serial-succeeds means the function is not
    safe to parallelise (unpicklable state, a native library that is not
    fork-safe, memory pressure), serial-fails-too means the image itself is bad.
    """
    import background.operations
    import ray

    results = {}
    median_list = _median_remove_list(ctx, images_list)

    blocked = require_inputs(
        results, [(attribute(p, image_names), p) for p in median_list], 'median')
    if blocked:
        log('  median: {} image(s) have no _darkframe_removed input and are '
            'skipped'.format(len(blocked)))
    median_list = [p for p in median_list
                   if attribute(p, image_names) not in blocked]

    jobs = _median_jobs(ctx, median_list, image_names)
    expected = [(label, image_path.replace('_darkframe_removed', new_term))
                for label, image_path, new_term, _ in jobs]

    if not median_parallel:
        log('  median: running serially (the default; --median-parallel to try '
            'ray)')
        _median_serial(ctx, jobs, results)
        return check_files(results, expected, 'median')

    # A median filter over a full time-lapse stack holds several copies of the
    # stack in memory, so this stage is memory-bound rather than CPU-bound and
    # gets far fewer workers than the rest of the pipeline.
    if not median_cpus:
        median_cpus = max(1, min(cpus, 4))
    log('  median: using {} worker(s) (of {} CPUs) because this stage is '
        'memory-bound'.format(median_cpus, cpus))

    operation = background.operations.remove_median_blur
    if hasattr(operation, 'remote'):
        remote_operation = operation
        log('  median: remove_median_blur is already a ray remote function')
    else:
        # Wrap the plain function at call time. This does not modify
        # background/operations.py; if it works, decorating the function there
        # with @ray.remote makes it permanent.
        try:
            remote_operation = ray.remote(num_cpus=1)(operation)
        except TypeError:
            remote_operation = ray.remote(operation)
        log('  median: remove_median_blur is a plain function, wrapping it with '
            'ray.remote() for this run')

    parallel_results = {}
    with ray_session(median_cpus):
        pairs = []
        for label, image_path, new_term, median_size in jobs:
            _submit(parallel_results, label,
                    lambda p=image_path, n=new_term, m=median_size:
                    remote_operation.remote(p, '_darkframe_removed', n, m,
                                            ctx.tiff_compression_level), pairs)
        merge_results(parallel_results, gather(pairs))

    check_files(parallel_results, expected, 'median')
    failed_labels = {label for label, (ok, _) in parallel_results.items() if not ok}
    if not failed_labels:
        log('  median: parallel run succeeded for all {} call(s)'.format(len(jobs)))
        results.update(parallel_results)
        return results

    errors = [err for label, (ok, err) in parallel_results.items() if not ok]
    example = next(iter(e for e in errors if e), 'no error message')
    log('  median: {} image(s) failed in parallel. First error: {}'
        .format(len(failed_labels), example))

    if _looks_like_oom(errors):
        log('  median: the workers were killed rather than raising an exception, '
            'so this is the process dying (OOM kill or a segfault in native '
            'code), not remove_median_blur raising.')
        log('  median: check MaxRSS in the Slurm epilogue. If it is well under '
            'the node limit this is not memory and the serial path is the '
            'answer; if it is near the limit, lower --median-cpus (currently '
            '{}).'.format(median_cpus))

    log('  median: retrying those serially to find out whether the image is bad '
        'or the parallelisation is')

    retry_jobs = [j for j in jobs if j[0] in failed_labels]
    retry_results = _median_serial(ctx, retry_jobs, {})

    recovered = sorted(l for l, (ok, _) in retry_results.items() if ok)
    if recovered:
        log('  median: {} image(s) succeeded serially after failing in parallel: {}'
            .format(len(recovered), ', '.join(recovered)))
        log('  median: so the data is fine and remove_median_blur is not safe '
            'to run this way. Leave the stage serial (the default).')

    for key, value in parallel_results.items():
        if key not in failed_labels:
            results.setdefault(key, value)
    results.update(retry_results)
    return check_files(results, expected, 'median')


# ---------------------------------------------------------------------------
# Stage 4: tracking reference images
# ---------------------------------------------------------------------------
def stage_tracking_ref(ctx, images_list, image_names, cpus):
    import background.operations

    results = {}
    median_list = _median_remove_list(ctx, images_list)

    inputs = [(attribute(p, image_names),
               p.replace('_darkframe_removed', '_puncta_median_removed'))
              for p in median_list]
    blocked = require_inputs(results, inputs, 'tracking_ref')
    if blocked:
        log('  tracking_ref: {} image(s) have no _puncta_median_removed input '
            'and are skipped'.format(len(blocked)))

    pairs = []
    expected = []
    with ray_session(cpus):
        for label, median_image_path in inputs:
            if label in blocked:
                continue
            expected.append((label, median_image_path.replace(
                '_puncta_median_removed', '_tracking_ref')))
            _submit(results, label, lambda p=median_image_path:
                    background.operations.tracking_image.remote(
                        p, '_puncta_median_removed', '_tracking_ref', 3,
                        ctx.tiff_compression_level), pairs)
        merge_results(results, gather(pairs))
    return check_files(results, expected, 'tracking_ref')


# ---------------------------------------------------------------------------
# Stage 5: combined tracking reference
# ---------------------------------------------------------------------------
def stage_combine(ctx, images_list, image_names, cpus):
    import background.operations
    import background.parameters

    results = {}
    median_list = _median_remove_list(ctx, images_list)
    to_combine = background.parameters.combine_images_list(
        median_list, '_darkframe_removed.tif', '_tracking_ref.tif')

    unique_outputs = to_combine.output.unique().tolist()
    pairs = []
    expected = []

    with ray_session(cpus):
        for output in unique_outputs:
            folder = os.path.dirname(output)
            label = attribute(folder, image_names)
            try:
                inputs = to_combine.loc[to_combine['folder'] == folder]
                inputs = inputs.reset_index(drop=True)
                output_image = inputs.output[0]
                input_images = inputs.input.tolist()
            except Exception as e:
                results[label] = (False, fmt_exc(e))
                continue
            missing = [p for p in input_images if not os.path.exists(p)]
            if missing:
                results[label] = (
                    False, 'missing input for combine: ' + ', '.join(
                        sorted({os.path.basename(m) for m in missing})[:3]))
                continue
            expected.append((label, output_image))
            _submit(results, label, lambda i=input_images, o=output_image:
                    background.operations.combine_images.remote(
                        i, o, ctx.tiff_compression_level), pairs)
        merge_results(results, gather(pairs))
    return check_files(results, expected, 'combine')


# ---------------------------------------------------------------------------
# Stage 6: segmentation
# ---------------------------------------------------------------------------
def stage_segment(ctx, images_list, image_names, cpus):
    import segmentation.operations
    import segmentation.parameters

    results = {}
    segmentation_images = segmentation.parameters.segmentation_list(
        images_list, '_intensity_ref.tif', ctx.work_path)
    pairs = []

    with ray_session(cpus):
        for index in range(len(segmentation_images)):
            image_path = segmentation_images[index]
            label = attribute(image_path, image_names)
            _submit(results, label, lambda p=image_path:
                    segmentation.operations.segment.remote(
                        p, ctx.cell_diameter, ctx.tiff_compression_level), pairs)
        merge_results(results, gather(pairs))
    return results


# ---------------------------------------------------------------------------
# Stage 7: substacks and area lists
# ---------------------------------------------------------------------------
def stage_substacks(ctx, images_list, image_names, cpus):
    import segmentation.operations
    import segmentation.parameters

    results = {}
    file_ending = ['_intensity_ref.tif', '_puncta_median_removed', '_tracking_ref.tif']
    substack_segmentation_images, substack_image_list = segmentation.parameters.substack_list(
        images_list, ctx.exclusion_channels, ctx.work_path, file_ending)
    pairs = []

    with ray_session(cpus):
        for index in range(len(substack_image_list)):
            segmentation_image = substack_segmentation_images[index]
            substack_image = substack_image_list[index]
            label = attribute(substack_image, image_names)
            _submit(results, label, lambda s=segmentation_image, i=substack_image:
                    segmentation.operations.make_substacks.remote(
                        s, i, ctx.puncta_diameter, ctx.tiff_compression_level), pairs)
            # The original fired this off and threw the reference away, so any
            # failure was invisible. It is now waited on like everything else.
            _submit(results, label, lambda s=segmentation_image:
                    segmentation.operations.make_area_list.remote(
                        s, ctx.puncta_diameter), pairs)
        merge_results(results, gather(pairs))
    return results


# ---------------------------------------------------------------------------
# Stage 8: TrackMate
# ---------------------------------------------------------------------------
def stage_track(ctx, images_list, image_names, cpus):
    import track.operations
    import track.parameters

    results = {}
    all_channels_metadata = track.parameters.tracking_list(
        images_list, ctx.exclusion_channels, ctx.work_path, ctx.input_path,
        ctx.cell_diameter, ctx.puncta_diameter)

    # tracking_list swallows its own exceptions and returns None, which used to
    # surface as "'NoneType' object has no attribute 'loc'" inside
    # tracking_parameters two frames later.
    if all_channels_metadata is None or len(all_channels_metadata) == 0:
        message = ('track: tracking_list found no channel metadata under {}. The '
                   'earlier stages did not leave the per-cell folders it expects '
                   '-- run with --inspect to see what is actually there.'
                   .format(ctx.work_path))
        log('  ' + message)
        return {name: (False, message) for name in image_names}

    tracking_parameters = track.parameters.tracking_parameters(
        all_channels_metadata, '_tracking_ref.tif', ctx.work_path)
    if tracking_parameters is None or tracking_parameters[0] is None:
        message = ('track: tracking_parameters returned nothing for {} metadata '
                   'row(s). It needs a "Calibrations" cohort to pair exposures '
                   'against; check that the calibration images reached this '
                   'stage.'.format(len(all_channels_metadata)))
        log('  ' + message)
        return {name: (False, message) for name in image_names}

    (n_trackings, protein_paths, image_paths, thresholds, frame_gaps,
     max_link_distances, gap_link_distances) = tracking_parameters

    # TrackMate runs through ImageJ, one call at a time, as before.
    for index in n_trackings:
        image_path = image_paths[index]
        label = attribute(image_path, image_names)
        try:
            track.operations.trackmate(
                ctx.imagej, protein_paths[index], image_path, thresholds[index],
                frame_gaps[index], max_link_distances[index],
                gap_link_distances[index], ctx.puncta_diameter)
            results.setdefault(label, (True, None))
        except Exception as e:
            results[label] = (False, fmt_exc(e))
            log('  trackmate failed for {}: {}'.format(label, fmt_exc(e)))
    return results


STAGES = {
    'convert': stage_convert,
    'darkframe': stage_darkframe,
    'median': stage_median,
    'tracking_ref': stage_tracking_ref,
    'combine': stage_combine,
    'segment': stage_segment,
    'substacks': stage_substacks,
    'track': stage_track,
}

assert set(STAGES) == set(STAGE_ORDER) == set(STAGE_PARAM_SPEC)

__all__ = ['STAGES', 'STAGE_ORDER', 'STAGE_PARAM_SPEC', 'stage_param_hash',
           'subset', 'UNATTRIBUTED']