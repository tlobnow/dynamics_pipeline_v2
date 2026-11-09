"""Folder layout.

The convention
--------------
    <root>/
        1_input/                     all .nd2 files, shared across runs
            dark_frames/
        2_parameter_tables/
            defaults.csv             machine-specific bits (ImageJ path, ...)
            parameter_tables_IRAK2/  images.csv, constants.csv, dark_frames.csv,
                                     exclusion_channels.csv
        3_processing/
            IRAK2/                   working data for this run
        4_output/
            IRAK2/                   final data + the parameter tables used

Everything except `images.csv` and the folder name is derived. Point the
pipeline at `.../2_parameter_tables/parameter_tables_IRAK2` and the run name
(`IRAK2`), the processing folder and the output folder all follow. No editing
directories.csv per run.

What gets generated
-------------------
The R scripts read `directories.csv` from the parameter tables folder they are
given, and `compile_tables.R` additionally reads `summary.csv` from that
folder's *parent*. So rather than editing the user's tables, this module
materialises a resolved copy:

    <root>/3_processing/IRAK2/
        summary.csv                  <- placed here by the pipeline
        parameter_tables/            <- generated: pass THIS path to the R scripts
            directories.csv          <- generated, absolute paths
            images.csv               <- copied verbatim
            constants.csv            <- copied verbatim
            ...

Legacy batches (`.../<batch>/Input/parameter_tables`, with a hand-written
directories.csv) still work: if the folder does not match the convention, the
directories.csv found there is used as-is.
"""

import csv
import glob
import io
import os
import shutil
import time

from pipeline.util import log

PARAMETER_TABLES_PREFIX = 'parameter_tables_'
PARAMETER_TABLES_PARENT = '2_parameter_tables'

INPUT_DIRNAME = '1_input'
TABLES_DIRNAME = '2_parameter_tables'
PROCESSING_DIRNAME = '3_processing'
OUTPUT_DIRNAME = '4_output'

DEFAULTS_FILENAME = 'defaults.csv'
RESOLVED_TABLES_DIRNAME = 'parameter_tables'

# The R scripts hardcode these under the processing path, so the pipeline does
# too: extract_intensity.R reads file.path(processing_path, '04_Track').
TRACK_DIRNAME = '04_Track'

# Tables copied verbatim into the resolved folder for the R scripts to read.
COPIED_TABLES = ['images.csv', 'constants.csv', 'dark_frames.csv',
                 'exclusion_channels.csv', 'tolerate_failures.csv']


class LayoutError(Exception):
    pass


def read_key_value_csv(path):
    """Read a two-column contains/path table into an ordered dict."""
    mapping = {}
    if not os.path.exists(path):
        return mapping
    with open(path, newline='') as handle:
        for row in csv.DictReader(handle):
            key = (row.get('contains') or '').strip()
            value = (row.get('path') or '').strip()
            if key:
                mapping[key] = value
    return mapping


def detect(parameter_tables):
    """Return (root, run_name) if the path follows the convention, else None."""
    parameter_tables = os.path.abspath(parameter_tables.rstrip(os.sep))
    base = os.path.basename(parameter_tables)
    parent = os.path.dirname(parameter_tables)

    if os.path.basename(parent) != PARAMETER_TABLES_PARENT:
        return None
    if not base.startswith(PARAMETER_TABLES_PREFIX):
        raise LayoutError(
            'Folder "{}" sits in {} but is not named "{}<run>". The run name is '
            'taken from that suffix, so it cannot be derived.'
            .format(base, PARAMETER_TABLES_PARENT, PARAMETER_TABLES_PREFIX))

    run_name = base[len(PARAMETER_TABLES_PREFIX):].strip()
    if not run_name:
        raise LayoutError('Folder "{}" has an empty run name after "{}".'
                          .format(base, PARAMETER_TABLES_PREFIX))
    return os.path.dirname(parent), run_name


# Shared across every run, so it is fine for defaults.csv to set these.
SHARED_KEYS = ('input', 'dark_frames', 'ImageJ', 'ligand')

# Must differ per run. Always derived from the run name: an override here would
# make two runs write into the same processing or output folder.
PER_RUN_KEYS = ('processing', 'output')

# Stage folders the pipeline derives from `processing` itself. Rows for these
# left over from the old directories.csv would silently point work somewhere
# else, so they are dropped with a warning.
LEGACY_STAGE_KEYS = ('to_tiff', 'background_remove', 'segmentation', 'tracking',
                     'processing_path', 'work')


def derive(root, run_name, overrides=None):
    """Build the directory entries the pipeline and the R scripts need.

    Only the shared keys can be overridden. `processing` and `output` are always
    <root>/3_processing/<run> and <root>/4_output/<run>.
    """
    overrides = overrides or {}
    paths = {
        'input': os.path.join(root, INPUT_DIRNAME),
        'dark_frames': os.path.join(root, INPUT_DIRNAME, 'dark_frames'),
    }
    for key in SHARED_KEYS:
        if overrides.get(key):
            paths[key] = overrides[key]
    paths['processing'] = os.path.join(root, PROCESSING_DIRNAME, run_name)
    paths['output'] = os.path.join(root, OUTPUT_DIRNAME, run_name)
    return paths


def load_defaults(root):
    """Machine-specific settings shared by every run, e.g. the ImageJ path."""
    return read_key_value_csv(
        os.path.join(root, TABLES_DIRNAME, DEFAULTS_FILENAME))


def resolve(parameter_tables):
    """Work out every path for this run.

    Returns a dict with: mode, root, run_name, source_tables, resolved_tables,
    directories (the contains/path mapping), and created (list of new dirs).
    """
    parameter_tables = os.path.abspath(parameter_tables.rstrip(os.sep))
    if not os.path.isdir(parameter_tables):
        raise LayoutError('parameter_tables folder does not exist: ' + parameter_tables)

    detected = detect(parameter_tables)
    run_level = read_key_value_csv(os.path.join(parameter_tables, 'directories.csv'))

    if detected is None:
        # Legacy batch: trust the directories.csv that is already there.
        if not run_level:
            raise LayoutError(
                'No directories.csv in {} and the folder does not follow the\n'
                '  <root>/{}/{}<run>\n'
                'convention, so paths cannot be derived. Either move it into the\n'
                'standard layout or provide a directories.csv.'
                .format(parameter_tables, PARAMETER_TABLES_PARENT,
                        PARAMETER_TABLES_PREFIX))
        log('Legacy layout: using directories.csv from ' + parameter_tables)
        return {
            'mode': 'legacy',
            'root': None,
            'run_name': os.path.basename(os.path.dirname(parameter_tables)),
            'source_tables': parameter_tables,
            'resolved_tables': parameter_tables,
            'directories': run_level,
        }

    root, run_name = detected
    defaults = load_defaults(root)

    supplied = dict(defaults)
    # A run-level directories.csv still contributes, and wins over defaults.csv.
    supplied.update({k: v for k, v in run_level.items() if v})

    for key in PER_RUN_KEYS:
        if supplied.get(key):
            log('IGNORING "{}" row ({}): this path has to differ per run, so it '
                'is always derived as <root>/{}/{}.'
                .format(key, supplied[key],
                        PROCESSING_DIRNAME if key == 'processing' else OUTPUT_DIRNAME,
                        run_name))
    for key in LEGACY_STAGE_KEYS:
        if supplied.get(key):
            log('IGNORING leftover "{}" row ({}): stage folders are derived from '
                'the processing path.'.format(key, supplied[key]))

    directories = {k: v for k, v in supplied.items()
                   if k not in PER_RUN_KEYS and k not in LEGACY_STAGE_KEYS}
    directories.update(derive(root, run_name, overrides=supplied))

    missing_imagej = not directories.get('ImageJ')
    if missing_imagej:
        raise LayoutError(
            'No ImageJ path found. Add a row to {}:\n'
            '    contains,path\n'
            '    ImageJ,/path/to/ImageJ\n'
            'It is the same for every run, which is why it lives in defaults.csv.'
            .format(os.path.join(root, TABLES_DIRNAME, DEFAULTS_FILENAME)))

    return {
        'mode': 'standard',
        'root': root,
        'run_name': run_name,
        'source_tables': parameter_tables,
        'resolved_tables': os.path.join(directories['processing'],
                                        RESOLVED_TABLES_DIRNAME),
        'directories': directories,
    }


def materialise(layout):
    """Create the run folders and the resolved parameter tables for the R scripts.

    Returns the path to hand to the R scripts.
    """
    if layout['mode'] == 'legacy':
        return layout['source_tables']

    directories = layout['directories']
    for key in ('input', 'dark_frames', 'processing', 'output'):
        os.makedirs(directories[key], exist_ok=True)

    resolved = layout['resolved_tables']
    os.makedirs(resolved, exist_ok=True)

    # Copy the tables the user actually edits.
    for name in COPIED_TABLES:
        source = os.path.join(layout['source_tables'], name)
        if os.path.exists(source):
            shutil.copy2(source, os.path.join(resolved, name))

    # Generate directories.csv with absolute paths, keeping any extra keys.
    ordered = ['input', 'processing', 'output', 'dark_frames', 'ImageJ']
    extras = [k for k in directories if k not in ordered]
    with open(os.path.join(resolved, 'directories.csv'), 'w', newline='') as handle:
        writer = csv.writer(handle, lineterminator='\n')
        writer.writerow(['contains', 'path'])
        for key in ordered + sorted(extras):
            if directories.get(key):
                writer.writerow([key, directories[key]])

    return resolved


def snapshot_to_output(layout, run_id, note=''):
    """Keep a copy of the parameter tables that produced the output."""
    if layout['mode'] == 'legacy':
        return None

    output_path = layout['directories']['output']
    destination = os.path.join(output_path, 'parameter_tables')
    os.makedirs(destination, exist_ok=True)

    for name in os.listdir(layout['resolved_tables']):
        source = os.path.join(layout['resolved_tables'], name)
        if os.path.isfile(source):
            shutil.copy2(source, os.path.join(destination, name))

    with open(os.path.join(output_path, 'run_history.log'), 'a') as handle:
        handle.write('{}\t{}\t{}\n'.format(
            time.strftime('%Y-%m-%d %H:%M:%S'), run_id, note))
    return destination


def _summary_overlap(path, expected_images):
    """How many rows of `path` describe images this run is actually processing."""
    try:
        with open(path, newline='') as handle:
            rows = list(csv.DictReader(handle))
    except (OSError, UnicodeDecodeError, csv.Error):
        return 0, 0
    if not rows:
        return 0, 0
    if not expected_images:
        return len(rows), len(rows)
    wanted = set(expected_images)
    matched = sum(1 for row in rows if _summary_image(row) in wanted)
    return matched, len(rows)


def validate_summary(summary_path, expected_images):
    """Check summary.csv describes this run before handing it to R.

    extract_intensity.R filters on file.exists() and simply ends up with an
    empty table when the paths belong to another batch -- which then surfaces as
    "FileX = 0" with no indication of the real cause.

    Returns (ok, message).
    """
    if not summary_path or not os.path.exists(summary_path):
        return False, 'summary.csv does not exist at ' + str(summary_path)

    matched, total = _summary_overlap(summary_path, expected_images)
    if total == 0:
        return False, 'summary.csv is empty: ' + summary_path
    if matched == 0:
        found = set()
        with open(summary_path, newline='') as handle:
            for row in csv.DictReader(handle):
                name = _summary_image(row)
                if name:
                    found.add(name)
        return False, (
            'summary.csv describes a different batch.\n'
            '  file    : {}\n'
            '  rows    : {}, none matching this run\n'
            '  contains: {}\n'
            '  expected: {}'.format(
                summary_path, total,
                ', '.join(sorted(found)[:3]) + (' ...' if len(found) > 3 else ''),
                ', '.join(sorted(expected_images)[:3])
                + (' ...' if len(expected_images) > 3 else '')))
    if matched < total:
        return True, ('summary.csv: {} of {} rows match this run; the rest '
                      'belong to other images and are ignored by the R scripts.'
                      .format(matched, total))
    return True, ''


def sync_summary(directories, work_path, parameter_tables, expected_images=None):
    """Build this run's summary.csv from rows belonging to this run's images.

    Design constraints this satisfies:

    * One summary.csv per run, never a growing shared file.
    * Concurrent batches cannot corrupt each other. Rows are selected by image
      name, so a file containing another run's rows is simply not harvested from
      -- no locking, no ordering assumption, no reliance on mtime.
    * Nothing is copied wholesale. An earlier version copied the newest
      summary*.csv it could find, which silently imported a previous batch's
      metadata when the current run had nothing to reconvert.

    Sources are searched in order of trustworthiness: the per-run _nd2 symlink
    folder (where conversion writes for this run), then the run's own folders,
    then the shared input folder as a fallback for runs converted before the
    symlink change. Files in the shared folder are read, never rewritten, so a
    job running concurrently cannot be disturbed.
    """
    processing = directories.get('processing')
    if not processing:
        return None
    destination = os.path.join(processing, 'summary.csv')
    input_path = directories.get('input', '')

    search_dirs = [d for d in (os.path.join(processing, '_nd2'),
                               processing,
                               work_path,
                               os.path.dirname(parameter_tables),
                               input_path) if d]

    candidates = []
    seen_dirs = set()
    for directory in search_dirs:
        key = os.path.abspath(directory)
        if key in seen_dirs:
            continue
        seen_dirs.add(key)
        candidates.extend(sorted(glob.glob(os.path.join(directory, 'summary*.csv'))))
    candidates = [c for c in candidates
                  if os.path.isfile(c) and 'summary_archive' not in c
                  and os.path.basename(c) not in ('summary_all.csv',
                                                  'summary_unfiltered.csv')]
    if not candidates:
        return destination if os.path.exists(destination) else None

    wanted = set(expected_images or [])
    fieldnames = []
    harvested = {}
    contributions = []
    foreign = []

    for candidate in candidates:
        try:
            with open(candidate, newline='') as handle:
                reader = csv.DictReader(handle)
                names = reader.fieldnames or []
                rows = list(reader)
        except (OSError, UnicodeDecodeError, csv.Error) as e:
            log('summary: could not read {} ({})'.format(candidate, e))
            continue

        taken = 0
        for row in rows:
            image = _summary_image(row)
            if wanted and image not in wanted:
                continue
            key = (row.get('protein_relative_path') or '').strip() or repr(sorted(row.items()))
            if key not in harvested:
                harvested[key] = row
                for name in names:
                    if name not in fieldnames:
                        fieldnames.append(name)
            taken += 1

        if taken:
            contributions.append((candidate, taken, len(rows)))
        elif rows:
            foreign.append((candidate, len(rows)))

    if not harvested:
        log('summary: found {} candidate file(s), none containing rows for this '
            "run's images. Not writing summary.csv:".format(len(candidates)))
        for candidate, total in foreign:
            log('  {} row(s), all other images  {}'.format(total, candidate))
        return destination if os.path.exists(destination) else None

    rows = list(harvested.values())

    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=fieldnames,
                            lineterminator='\n', extrasaction='ignore')
    writer.writeheader()
    writer.writerows(rows)
    payload = buffer.getvalue()

    # sync_summary runs after every stage; stay silent unless something changed.
    unchanged = False
    if os.path.exists(destination):
        try:
            with open(destination) as handle:
                unchanged = handle.read() == payload
        except OSError:
            unchanged = False
    if unchanged:
        _archive_own_summaries(input_path, processing, wanted)
        return destination

    with open(destination + '.tmp', 'w', newline='') as handle:
        handle.write(payload)
    os.replace(destination + '.tmp', destination)

    log('summary: {} row(s) for this run -> {}'.format(len(rows), destination))
    for candidate, taken, total in contributions:
        note = '' if taken == total else '  (of {} rows; the rest are other runs)'.format(total)
        log('  {} row(s) from {}{}'.format(taken, candidate, note))
    for candidate, total in foreign:
        log('  0 row(s) from {} ({} rows, all other runs -- left untouched)'
            .format(candidate, total))

    _archive_own_summaries(input_path, processing, wanted)
    return destination


def _archive_own_summaries(input_path, processing, wanted):
    """Move summary files out of the shared input folder, but only ours.

    A file is moved only when every row in it belongs to this run, so a file
    another job is writing is never touched. Files that mix runs are left alone;
    harvesting is by row, so leaving them costs nothing but tidiness.
    """
    if not input_path or not wanted:
        return
    archive = os.path.join(processing, 'summary_archive')
    for candidate in sorted(glob.glob(os.path.join(input_path, 'summary*.csv'))):
        try:
            with open(candidate, newline='') as handle:
                rows = list(csv.DictReader(handle))
        except (OSError, UnicodeDecodeError, csv.Error):
            continue
        if not rows or any(_summary_image(r) not in wanted for r in rows):
            continue
        os.makedirs(archive, exist_ok=True)
        target = os.path.join(archive, os.path.basename(candidate))
        if os.path.exists(target):
            target += time.strftime('.%Y%m%d_%H%M%S')
        try:
            shutil.move(candidate, target)
            log('summary: moved {} out of the shared input folder'
                .format(os.path.basename(candidate)))
        except OSError:
            pass


def _summary_image(row):
    """Image name for a summary row.

    summary.csv has no `image` column: the R scripts derive it themselves with
    dirname(dirname(protein_relative_path)). Do the same rather than assuming a
    column that is not there.
    """
    name = (row.get('image') or '').strip()
    if name:
        return name
    relative = (row.get('protein_relative_path') or '').strip()
    if not relative:
        return ''
    return os.path.basename(os.path.dirname(os.path.dirname(relative.replace('\\', '/'))))


def _rewrite(summary_path, fieldnames, rows, archive_suffix):
    """Write `rows` back to summary.csv, keeping the original once."""
    archive = os.path.join(os.path.dirname(summary_path), archive_suffix)
    if not os.path.exists(archive):
        shutil.copy2(summary_path, archive)
    with open(summary_path, 'w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames,
                                lineterminator='\n', extrasaction='ignore')
        writer.writeheader()
        writer.writerows(rows)
    return archive


def excluded_channels_by_image(images_list, exclusion_channels):
    """Which acquisition channels are excluded, per image.

    exclusion_channels lists *protein* names (Brightfield, IL-1). images.csv maps
    a channel to a protein per image, in columns named "<channel> protein_name"
    -- e.g. "WideField Finn protein_name" -> "Brightfield". So the channel to
    drop is derived from that mapping rather than from the name in summary.csv,
    which cannot be relied on: when the mapping is missing the metadata writer
    falls back to the raw channel name, and then no protein-name match can work.
    """
    excluded = {name.strip() for name in exclusion_channels if str(name).strip()}
    if not excluded:
        return {}, excluded

    channel_columns = []
    for column in images_list.columns:
        text = str(column)
        if text.lower().endswith('protein_name'):
            channel = text[:-len('protein_name')].strip()
            if channel:
                channel_columns.append((channel, column))

    by_image = {}
    for index in range(len(images_list)):
        image = str(images_list['image'][index])
        drop = set()
        for channel, column in channel_columns:
            protein = str(images_list[column][index]).strip()
            if protein in excluded:
                drop.add(channel)
        if drop:
            by_image[image] = drop
    return by_image, excluded


def filter_summary_channels(summary_path, images_list, exclusion_channels):
    """Drop excluded channels from summary.csv before the R scripts read it.

    exclusion_channels is applied at median, substacks and tracking, but never
    at conversion -- which is what writes summary.csv. So excluded channels have
    always reached the R scripts. Usually harmless; not always. A WideField row
    whose `power` field holds the ND2 illuminator configuration block instead of
    a number makes fread type the whole power column as character, and
    GetCalibrationImages then fails for every row in the batch.

    The unfiltered table is kept as summary_unfiltered.csv.
    """
    if not summary_path or not os.path.exists(summary_path):
        return summary_path

    by_image, excluded = excluded_channels_by_image(images_list, exclusion_channels)
    if not excluded:
        return summary_path

    with open(summary_path, newline='') as handle:
        reader = csv.DictReader(handle)
        fieldnames = reader.fieldnames or []
        rows = list(reader)
    if not rows:
        return summary_path

    kept, removed = [], {}
    for row in rows:
        image = _summary_image(row)
        channel = (row.get('channel') or '').strip()
        protein = (row.get('protein_name') or '').strip()

        drop_reason = None
        if protein in excluded:
            drop_reason = protein
        elif channel in by_image.get(image, ()):
            drop_reason = channel
        elif channel in excluded:
            drop_reason = channel

        if drop_reason:
            removed[drop_reason] = removed.get(drop_reason, 0) + 1
        else:
            kept.append(row)

    if not removed:
        return summary_path
    if not kept:
        log('summary: excluding {} would empty the table -- leaving it alone. '
            'Check exclusion_channels.csv.'.format(sorted(excluded)))
        return summary_path

    archive = _rewrite(summary_path, fieldnames, kept, 'summary_unfiltered.csv')
    log('summary: dropped {} excluded-channel row(s) so the R scripts do not '
        'see them: {}'.format(
            sum(removed.values()),
            ', '.join('{} x{}'.format(k, v) for k, v in sorted(removed.items()))))
    log('         unfiltered table kept as ' + archive)
    return summary_path


def filter_summary(summary_path, keep_images, dropped):
    """Restrict summary.csv to the images that finished the Python stages.

    extract_intensity.R builds its work list from summary.csv, so an image that
    failed here would still be handed to R, which would then fail on missing
    files. Filtering the handoff is what lets a partial batch go downstream.

    The full table is kept as summary_all.csv.
    """
    if not summary_path or not os.path.exists(summary_path) or not dropped:
        return summary_path

    with open(summary_path, newline='') as handle:
        reader = csv.DictReader(handle)
        fieldnames = reader.fieldnames or []
        rows = list(reader)
    if not rows:
        return summary_path

    keep = set(keep_images)
    kept = [r for r in rows if _summary_image(r) in keep]
    removed = len(rows) - len(kept)
    if removed == 0:
        return summary_path
    if not kept:
        log('summary: filtering by completed images would empty the table -- '
            'leaving it alone.')
        return summary_path

    archive = _rewrite(summary_path, fieldnames, kept, 'summary_all.csv')
    log('summary: dropped {} row(s) for {} incomplete image(s) so the R scripts '
        'only see finished data.'.format(removed, len(dropped)))
    log('         full table kept as ' + archive)
    return summary_path


def isolate_incomplete(work_path, processing, folders):
    """Move partial image folders out of the work tree.

    The R scripts walk the cohort folders under 04_Track and move what they find
    onward. A half-converted image left in place gets swept along with the good
    ones. Moving it aside (rather than deleting) keeps it available for
    inspection and keeps the tree clean for R.
    """
    if not folders:
        return []
    destination_root = os.path.join(processing, '_incomplete')
    moved = []
    for folder in folders:
        if not folder or not os.path.isdir(folder):
            continue
        relative = os.path.relpath(folder, work_path)
        destination = os.path.join(destination_root, relative)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        if os.path.exists(destination):
            destination += time.strftime('.%Y%m%d_%H%M%S')
        try:
            shutil.move(folder, destination)
            moved.append((folder, destination))
        except OSError as e:
            log('could not move {} aside: {}'.format(folder, e))
    if moved:
        log('Moved {} incomplete image folder(s) to {} so the R scripts do not '
            'pick them up:'.format(len(moved), destination_root))
        for source, destination in moved:
            log('  ' + os.path.basename(source))
    return moved


def describe(layout):
    directories = layout['directories']
    lines = ['layout mode      : ' + layout['mode']]
    if layout['root']:
        lines.append('root             : ' + layout['root'])
    lines.append('run name         : ' + str(layout['run_name']))
    for key in ('input', 'dark_frames', 'processing', 'output', 'ImageJ'):
        if directories.get(key):
            lines.append('{:<17}: {}'.format(key, directories[key]))
    lines.append('tables for R     : ' + layout['resolved_tables'])
    return '\n'.join(lines)