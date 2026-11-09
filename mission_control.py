#!/usr/bin/env python
"""Dynamics pipeline orchestrator.

Runs one or more stages over the images listed in images.csv, records what
completed in a per-image manifest, and never redoes work you did not ask it to
redo.

Layout
------
Point it at a parameter tables folder and everything else is derived:

    <root>/2_parameter_tables/parameter_tables_IRAK2   ->  run name "IRAK2"
    <root>/1_input                                     ->  the .nd2 files
    <root>/3_processing/IRAK2                          ->  working data
    <root>/4_output/IRAK2                              ->  results

Typical use
-----------
  python mission_control.py .../parameter_tables_IRAK2 12            # outstanding work
  python mission_control.py .../parameter_tables_IRAK2 --status      # state table
  python mission_control.py .../parameter_tables_IRAK2 12 --stages track --force
  python mission_control.py .../parameter_tables_IRAK2 12 --from segment
  python mission_control.py .../parameter_tables_IRAK2 12 --images "20260807 img_03"

Behaviour worth knowing
-----------------------
* A stage already recorded as done is skipped, and is never rerun automatically
  -- not even when its parameters changed. Those are reported as STALE and left
  for you to rerun explicitly with --force.
* An image that fails a stage is quarantined: dropped from the remaining stages
  of that run, the other images carry on, and the job exits non-zero.
"""

import argparse
import os
import platform
import sys
import time

from pipeline.context import (ContextError, describe, image_folder, is_critical,
                              is_tolerated, load_context, sync_summary,
                              tree_state)
from pipeline.layout import (filter_summary, filter_summary_channels,
                             isolate_incomplete, snapshot_to_output,
                             validate_summary)
from pipeline.state import (DONE, FAILED, TOLERATED, Manifest, status_table)
from pipeline.stages import (STAGE_ORDER, STAGES, UNATTRIBUTED,
                             stage_param_hash, subset)
from pipeline.util import log, set_log_stream

MAC_DEFAULT_TABLES = '/Users/u_lobnow/Desktop/20250522_batch/Input/parameter_tables'


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description='Run selected stages of the dynamics pipeline.',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('parameter_tables', nargs='?',
                        help='e.g. <root>/2_parameter_tables/parameter_tables_IRAK2')
    parser.add_argument('cpus', nargs='?', type=int, default=8,
                        help='CPUs handed to ray (default: 8)')
    parser.add_argument('--stages', default=None,
                        help='Comma-separated stages to run. Default: all.')
    parser.add_argument('--from', dest='from_stage', default=None,
                        help='Start at this stage (inclusive).')
    parser.add_argument('--to', dest='to_stage', default=None,
                        help='Stop after this stage (inclusive).')
    parser.add_argument('--images', default=None,
                        help='Comma-separated image names to restrict this run to.')
    parser.add_argument('--images-file', default=None,
                        help='File with one image name per line.')
    parser.add_argument('--cohort', default=None,
                        help='Restrict this run to one cohort.')
    parser.add_argument('--force', action='store_true',
                        help='Rerun selected stages even if recorded as done.')
    parser.add_argument('--status', action='store_true',
                        help='Print the image x stage state table and exit.')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would run, then exit.')
    parser.add_argument('--list-stages', action='store_true',
                        help='Print stage names in order and exit.')
    parser.add_argument('--print-r-path', action='store_true',
                        help='Set up the run folders and print the parameter '
                             'tables path to hand to the R scripts, then exit.')
    parser.add_argument('--median-parallel', action='store_true',
                        help='Try running the median stage through ray. Off by '
                             'default: the workers die on this cluster and the '
                             'serial path is known to work.')
    parser.add_argument('--median-cpus', type=int, default=None,
                        help='Workers for --median-parallel (default: min(cpus, 4)).')
    parser.add_argument('--strict', action='store_true',
                        help='Ignore tolerate_failures.csv, and treat any failed '
                             'image as fatal to the batch.')
    parser.add_argument('--keep-incomplete', action='store_true',
                        help='Leave partial image folders in the work tree '
                             'instead of moving them to _incomplete/.')
    parser.add_argument('--no-tree-check', action='store_true',
                        help='Do not fail a stage that reports success without '
                             'creating or modifying any file. Use if a stage '
                             'legitimately writes nothing.')
    parser.add_argument('--inspect', action='store_true',
                        help='List what each selected image actually has in the '
                             'work folder, then exit.')
    parser.add_argument('--keep-going', action='store_true',
                        help='Do not quarantine failed images from later stages '
                             '(not recommended: later stages run on missing inputs).')
    args = parser.parse_args(argv)

    if args.parameter_tables is None:
        if platform.system() == 'Darwin':
            args.parameter_tables = MAC_DEFAULT_TABLES
        else:
            parser.error('parameter_tables is required')
    return args


def resolve_stages(args):
    if args.stages:
        requested = [s.strip() for s in args.stages.split(',') if s.strip()]
        unknown = [s for s in requested if s not in STAGES]
        if unknown:
            raise SystemExit('Unknown stage(s): {}. Valid stages: {}'
                             .format(', '.join(unknown), ', '.join(STAGE_ORDER)))
        return [s for s in STAGE_ORDER if s in requested]

    start, end = 0, len(STAGE_ORDER) - 1
    if args.from_stage:
        if args.from_stage not in STAGE_ORDER:
            raise SystemExit('Unknown stage: ' + args.from_stage)
        start = STAGE_ORDER.index(args.from_stage)
    if args.to_stage:
        if args.to_stage not in STAGE_ORDER:
            raise SystemExit('Unknown stage: ' + args.to_stage)
        end = STAGE_ORDER.index(args.to_stage)
    if end < start:
        raise SystemExit('--to comes before --from')
    return STAGE_ORDER[start:end + 1]


def resolve_images(ctx, args):
    names = list(ctx.image_names)

    if args.cohort:
        wanted = set(ctx.images_list.loc[
            ctx.images_list['cohort'] == args.cohort]['image'].tolist())
        names = [n for n in names if n in wanted]
        if not names:
            raise SystemExit('No images in images.csv for cohort ' + args.cohort)

    requested = []
    if args.images:
        requested += [s.strip() for s in args.images.split(',') if s.strip()]
    if args.images_file:
        with open(args.images_file) as handle:
            requested += [line.strip() for line in handle
                          if line.strip() and not line.startswith('#')]
    if requested:
        missing = [r for r in requested if r not in names]
        if missing:
            raise SystemExit('Not in images.csv (or filtered out by --cohort): '
                             + ', '.join(missing))
        names = [n for n in names if n in set(requested)]
    return names


def warn_if_moved_downstream(ctx, manifest, images, stages):
    """The R scripts move image folders out of the work directory.

    extract_intensity.R moves <work>/<cohort>/<image> into 05_IntensityExtraction,
    colocalization.R into 06_Colocalization, compile_tables.R into the output
    folder. So a completed image is no longer in the work directory, and forcing
    a rerun of a middle stage would find nothing.
    """
    if stages == ['convert']:
        return
    moved = []
    for image in images:
        if manifest.status(image, 'convert') != 'done':
            continue
        cohorts = ctx.images_list.loc[ctx.images_list['image'] == image]['cohort']
        if not len(cohorts):
            continue
        folder = os.path.join(ctx.work_path, str(cohorts.iloc[0]), image)
        if not os.path.isdir(folder):
            moved.append(image)
    if moved:
        log('')
        log('NOTE: {} image(s) are recorded as processed but are no longer in the'
            .format(len(moved)))
        log('work folder. The R scripts move finished images onward into')
        log('05_IntensityExtraction / 06_Colocalization / the output folder.')
        log('Rerunning a Python stage for these needs --stages convert --force')
        log('to rebuild from the ND2, or the folder moved back by hand:')
        for image in moved[:10]:
            log('  ' + image)
        if len(moved) > 10:
            log('  ... and {} more'.format(len(moved) - 10))


def inspect(ctx, images):
    """Show what each image actually has on disk.

    When a stage says it found nothing to do, this is the question worth
    answering first: which artefacts exist and which are missing.
    """
    summary_path = os.path.join(ctx.processing_path or '', 'summary.csv')
    log('summary.csv: ' + (summary_path if os.path.exists(summary_path)
                           else 'MISSING (the R scripts need this)'))
    import glob as _glob
    stray = _glob.glob(os.path.join(ctx.input_path or '', 'summary*.csv'))
    if stray:
        log('unarchived summary files still in the input folder: '
            + ', '.join(os.path.basename(p) for p in stray))

    for image in images:
        folder = image_folder(ctx, image)
        log('')
        log(image)
        log('  ' + str(folder))
        if not folder or not os.path.isdir(folder):
            log('  (folder does not exist)')
            continue

        by_suffix = {}
        subfolders = []
        for entry in sorted(os.listdir(folder)):
            path = os.path.join(folder, entry)
            if os.path.isdir(path):
                subfolders.append(entry)
                continue
            for marker in ('_intensity_ref', '_puncta_median_removed',
                           '_tracking_ref', '_darkframe_removed'):
                if marker in entry:
                    by_suffix.setdefault(marker, []).append(entry)
                    break
            else:
                by_suffix.setdefault(os.path.splitext(entry)[1] or 'other',
                                     []).append(entry)

        for marker in sorted(by_suffix):
            names = by_suffix[marker]
            log('  {:<24} {} file(s): {}'.format(
                marker, len(names), ', '.join(names[:3])
                + (' ...' if len(names) > 3 else '')))
        if subfolders:
            log('  {:<24} {}: {}'.format(
                'subfolders', len(subfolders), ', '.join(subfolders[:6])
                + (' ...' if len(subfolders) > 6 else '')))
        else:
            log('  {:<24} none  <- per-cell folders live here'.format('subfolders'))


def main(argv=None):
    args = parse_args(argv)

    if args.list_stages:
        log('\n'.join(STAGE_ORDER))
        return 0

    if args.print_r_path:
        # stdout must carry the path and nothing else: it is captured by
        # `r_path=$(python mission_control.py ... --print-r-path)`.
        set_log_stream(sys.stderr)

    run_id = '{}-{}'.format(time.strftime('%Y%m%d_%H%M%S'),
                            os.environ.get('SLURM_JOB_ID', 'local'))

    try:
        ctx = load_context(args.parameter_tables)
    except ContextError as e:
        log('FATAL: ' + str(e))
        return 2

    if args.print_r_path:
        # Folders and the resolved tables now exist; tell the caller where.
        print(ctx.resolved_tables)
        return 0

    manifest = Manifest(ctx.work_path)
    stages = resolve_stages(args)
    images = resolve_images(ctx, args)

    hashes = {(i, s): stage_param_hash(ctx, i, s)
              for i in images for s in STAGE_ORDER}

    log('=' * 78)
    log('run_id: ' + run_id)
    log(describe(ctx))
    log('=' * 78)

    if args.inspect:
        inspect(ctx, images)
        return 0

    if args.status:
        log(status_table(manifest, images, STAGE_ORDER, hashes))
        warn_if_moved_downstream(ctx, manifest, images, STAGE_ORDER)
        return 0

    # ---- plan -------------------------------------------------------------
    plan = {}
    stale_notices = []
    for stage in stages:
        todo = []
        for image in images:
            state = manifest.status(image, stage, hashes[(image, stage)])
            if state == 'tolerated' and not args.force:
                continue
            if state == 'done' and not args.force:
                continue
            if state == 'stale' and not args.force:
                stale_notices.append((image, stage))
                continue
            todo.append(image)
        plan[stage] = todo

    log('Planned work ({} stage(s), {} image(s) selected):'.format(
        len(stages), len(images)))
    for stage in stages:
        log('  {:<13} {} image(s)'.format(stage, len(plan[stage])))

    if stale_notices:
        log('')
        log('STALE - complete, but the parameters they depend on have changed since.')
        log('Nothing was rerun. To redo them, use e.g. --stages <stage> --force.')
        for image, stage in stale_notices:
            log('  {:<13} {}'.format(stage, image))

    warn_if_moved_downstream(ctx, manifest, images, stages)

    if args.dry_run:
        log('\n--dry-run: stopping here.')
        return 0

    # ---- run --------------------------------------------------------------
    quarantined = {}
    unattributed_failures = []

    for stage in stages:
        todo = [i for i in plan[stage] if i not in quarantined]
        if not todo:
            log('\n--- {} : nothing to do'.format(stage))
            continue

        log('\n' + '-' * 78)
        log('--- {} : {} image(s)'.format(stage, len(todo)))
        log('-' * 78)

        started = time.time()
        images_list = subset(ctx.images_list, todo)
        before = {image: tree_state(image_folder(ctx, image)) for image in todo}
        kwargs = {}
        if stage == 'median':
            kwargs['median_parallel'] = args.median_parallel
            kwargs['median_cpus'] = args.median_cpus
        try:
            results = STAGES[stage](ctx, images_list, todo, args.cpus, **kwargs)
        except Exception as e:
            import traceback
            traceback.print_exc(file=sys.stdout)
            log('STAGE FAILED OUTRIGHT: {} ({})'.format(stage, e))
            log('Nothing was recorded for this stage. Fix the cause and rerun it.')
            sync_summary(ctx)
            return 1

        elapsed = time.time() - started
        sync_summary(ctx)

        if UNATTRIBUTED in results:
            ok, error = results.pop(UNATTRIBUTED)
            if not ok:
                unattributed_failures.append((stage, error))
                log('  ! failure in {} that could not be traced to a single '
                    'image: {}'.format(stage, error))

        tolerated = {}
        for image in todo:
            ok, error = results.get(
                image, (False, 'stage produced no work for this image - check '
                               'that its inputs from the previous stage exist'))

            # Last line of defence. The helper operations catch their own
            # exceptions and return normally, so a stage can report success
            # having written nothing at all. If not one file under the image
            # folder was created or changed, the stage did not run.
            if ok and not args.no_tree_check:
                after = tree_state(image_folder(ctx, image))
                if not (after - before.get(image, set())):
                    ok = False
                    error = ('reported success but no file under {} was created '
                             'or modified'.format(image_folder(ctx, image)))

            if ok:
                manifest.record(image, stage, DONE,
                                param_hash=hashes[(image, stage)],
                                duration=elapsed, run_id=run_id)
            elif not args.strict and is_tolerated(ctx, image, stage):
                manifest.record(image, stage, TOLERATED,
                                param_hash=hashes[(image, stage)],
                                error=error, duration=elapsed, run_id=run_id)
                tolerated[image] = error
                log('  tolerated failure {} : {}'.format(image, error))
            else:
                manifest.record(image, stage, FAILED,
                                param_hash=hashes[(image, stage)],
                                error=error, duration=elapsed, run_id=run_id)
                if not args.keep_going:
                    quarantined[image] = (stage, error)
                log('  FAILED {} : {}'.format(image, error))

        done_count = sum(1 for i in todo
                         if i not in quarantined and i not in tolerated)
        log('--- {} finished: {}/{} ok in {:.0f}s'.format(
            stage, done_count, len(todo), elapsed))

    # ---- summary ----------------------------------------------------------
    log('\n' + '=' * 78)
    log('SUMMARY (run {})'.format(run_id))
    log('=' * 78)
    log(status_table(manifest, images, STAGE_ORDER, hashes))

    # ---- who finished, who did not ---------------------------------------
    completed = [i for i in images if i not in quarantined]
    critical_failures = [i for i in quarantined if is_critical(ctx, i)]
    sample_failures = [i for i in quarantined if i not in critical_failures]

    if not args.keep_incomplete and quarantined:
        isolate_incomplete(
            ctx.work_path, ctx.processing_path,
            [image_folder(ctx, i) for i in quarantined])

    summary_path = sync_summary(ctx)
    if summary_path and os.path.exists(summary_path):
        # Excluded channels first: they are excluded for every image, whereas
        # the completed-image filter only applies to a partial batch.
        summary_path = filter_summary_channels(
            summary_path, ctx.images_list, ctx.exclusion_channels)
        summary_path = filter_summary(summary_path, completed,
                                      list(quarantined))

        ok, message = validate_summary(summary_path, completed)
        if message:
            log('')
            log(message)
        if not ok:
            log('')
            log('Refusing to hand this to the R scripts. They would filter every '
                'row out on file.exists() and fail with an empty table.')
            log('summary.csv is written during conversion into the shared input '
                'folder, so a run with nothing to redo can inherit a previous '
                "batch's file. To rebuild it:")
            log('  rm "{}"'.format(summary_path))
            log('  python mission_control.py "{}" {} --from convert --force'
                .format(ctx.parameter_tables, args.cpus))
            return 1
        log('\nsummary.csv ready for the R scripts: ' + summary_path)
    else:
        log('\nWARNING: no summary.csv in ' + str(ctx.processing_path))
        log('The R scripts read image metadata from it and will stop without it.')
        log('The pipeline writes it as "summary <timestamp>.csv"; if none exists '
            'anywhere, the stage that produces it has not succeeded yet.')

    snapshot_to_output(
        ctx.layout, run_id,
        note='stages={} images={} failed={}'.format(
            ','.join(stages), len(images), len(quarantined)))

    tolerated_any = [(i, s) for i in images for s in stages
                     if manifest.status(i, s) == 'tolerated']
    if tolerated_any:
        log('\nTolerated failures (expected; see tolerate_failures.csv):')
        for image, stage in tolerated_any:
            log('  {:<13} {}'.format(stage, image))

    if quarantined:
        log('\nFailed images (dropped from later stages in this run):')
        for image, (stage, error) in quarantined.items():
            marker = ' [CRITICAL]' if is_critical(ctx, image) else ''
            log('  {}{} - failed at {}: {}'.format(image, marker, stage, error))

    # ---- exit code -------------------------------------------------------
    # 0  everything finished
    # 3  some sample images failed, but the batch is still analysable, so the
    #    R scripts should run on what did finish
    # 1  the batch is not analysable: a critical image failed, nothing
    #    finished, or a failure could not be traced to an image
    if unattributed_failures:
        log('\nExiting 1: a failure could not be attributed to a single image, '
            'so the extent of the damage is unknown.')
        return 1

    if critical_failures:
        log('\nExiting 1: {} calibration/critical image(s) failed. The batch '
            'cannot be quantified without them, so the R scripts are not worth '
            'running:'.format(len(critical_failures)))
        for image in critical_failures:
            log('  ' + image)
        return 1

    if not completed:
        log('\nExiting 1: no image completed.')
        return 1

    if sample_failures:
        log('\nExiting 3: {} sample image(s) failed, {} completed. The '
            'calibrations are intact, so the R scripts can run on the {} '
            'finished image(s).'.format(len(sample_failures), len(completed),
                                        len(completed)))
        log('Failed images are in {} and are excluded from summary.csv.'
            .format(os.path.join(ctx.processing_path, '_incomplete')))
        log('To retry one:  --images "<name>" --from convert --force')
        return 3

    log('\nAll selected work completed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())