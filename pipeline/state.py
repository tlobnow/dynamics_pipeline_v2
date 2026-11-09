"""Per-image stage manifest.

One small JSON file per image under <work>/_pipeline_state/. Per-image files
(rather than one central manifest) mean two Slurm jobs working on *different*
images never touch the same file, so no locking is needed. Writes are atomic
(temp file + os.replace) so a job killed mid-write cannot corrupt state.

Deliberate design choice: this manifest never triggers a rerun on its own. If
the parameters for a stage changed since it last ran, the stage is reported as
STALE and left alone. You decide whether to rerun it.
"""

import hashlib
import json
import os
import re
import time

DONE = 'done'
FAILED = 'failed'
SKIPPED = 'skipped'
TOLERATED = 'tolerated'

STATE_DIRNAME = '_pipeline_state'

_SAFE = re.compile(r'[^A-Za-z0-9._-]+')


def param_hash(payload):
    """Stable hash of a dict of parameters."""
    blob = json.dumps(payload, sort_keys=True, default=str)
    return hashlib.sha1(blob.encode('utf-8')).hexdigest()[:12]


class Manifest(object):
    def __init__(self, work_path):
        self.dir = os.path.join(work_path, STATE_DIRNAME)
        os.makedirs(self.dir, exist_ok=True)
        self._cache = {}

    # -- file layout --------------------------------------------------------
    def _path(self, image):
        safe = _SAFE.sub('_', image).strip('_') or 'image'
        digest = hashlib.sha1(image.encode('utf-8')).hexdigest()[:8]
        return os.path.join(self.dir, '{}.{}.json'.format(safe, digest))

    def load(self, image):
        if image in self._cache:
            return self._cache[image]
        path = self._path(image)
        record = {'image': image, 'stages': {}}
        if os.path.exists(path):
            try:
                with open(path) as handle:
                    loaded = json.load(handle)
                if isinstance(loaded, dict) and 'stages' in loaded:
                    record = loaded
            except (ValueError, OSError):
                # Corrupt state file: treat as empty rather than crashing the run.
                record['note'] = 'previous state file was unreadable and was reset'
        self._cache[image] = record
        return record

    def _save(self, image):
        record = self._cache[image]
        path = self._path(image)
        tmp = path + '.tmp.{}'.format(os.getpid())
        with open(tmp, 'w') as handle:
            json.dump(record, handle, indent=2, sort_keys=True)
        os.replace(tmp, path)

    # -- queries ------------------------------------------------------------
    def get(self, image, stage):
        return self.load(image)['stages'].get(stage)

    def status(self, image, stage, current_hash=None):
        """Return one of: 'new', 'done', 'stale', 'failed'."""
        entry = self.get(image, stage)
        if entry is None:
            return 'new'
        if entry.get('status') == SKIPPED:
            return 'skipped'
        if entry.get('status') == TOLERATED:
            return 'tolerated'
        if entry.get('status') != DONE:
            return 'failed' if entry.get('status') == FAILED else 'new'
        if current_hash and entry.get('param_hash') and entry['param_hash'] != current_hash:
            return 'stale'
        return 'done'

    def known_images(self):
        names = []
        for filename in sorted(os.listdir(self.dir)):
            if not filename.endswith('.json'):
                continue
            try:
                with open(os.path.join(self.dir, filename)) as handle:
                    names.append(json.load(handle).get('image'))
            except (ValueError, OSError):
                continue
        return [n for n in names if n]

    # -- updates ------------------------------------------------------------
    def record(self, image, stage, status, param_hash=None, error=None,
               duration=None, run_id=None):
        record = self.load(image)
        entry = {
            'status': status,
            'timestamp': time.strftime('%Y-%m-%d %H:%M:%S'),
            'run_id': run_id,
        }
        if param_hash is not None:
            entry['param_hash'] = param_hash
        if error is not None:
            entry['error'] = str(error)[:2000]
        if duration is not None:
            entry['duration_s'] = round(duration, 1)
        if status == DONE:
            entry['error'] = None
        record['stages'][stage] = entry
        self._save(image)
        return entry

    def clear(self, image, stage):
        record = self.load(image)
        if stage in record['stages']:
            del record['stages'][stage]
            self._save(image)


SYMBOLS = {
    'done': 'ok',
    'stale': 'STALE',
    'failed': 'FAIL',
    'skipped': 'skip',
    'tolerated': 'warn',
    'new': '--',
}


def status_table(manifest, images, stages, hashes=None):
    """Render an image x stage overview."""
    hashes = hashes or {}
    width = max([len(i) for i in images] + [5]) if images else 5
    widths = [max(len(s), 5) for s in stages]
    header = 'image'.ljust(width) + ' | ' + ' | '.join(
        s.center(w) for s, w in zip(stages, widths))
    lines = [header, '-' * len(header)]
    for image in images:
        cells = []
        for stage, cell_width in zip(stages, widths):
            state = manifest.status(image, stage, hashes.get((image, stage)))
            cells.append(SYMBOLS.get(state, '?').center(cell_width))
        lines.append(image.ljust(width) + ' | ' + ' | '.join(cells))
    lines.append('')
    lines.append('ok = recorded complete   STALE = complete, but parameters changed since')
    lines.append('FAIL = last attempt failed   warn = failed but tolerated   -- = never run')
    return '\n'.join(lines)