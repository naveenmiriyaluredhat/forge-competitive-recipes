#!/usr/bin/env python3
"""Generate and optionally submit a reproducible batch of FournosJobs."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import uuid
import yaml

ROOT = Path(__file__).resolve().parents[1]


def read_yaml(path):
    data = yaml.safe_load(Path(path).read_text())
    if not isinstance(data, dict):
        raise ValueError(f'{path}: expected a YAML mapping')
    return data


def resolve(path):
    p = Path(path)
    return p if p.is_absolute() else ROOT / p


def recipe_info(path):
    text = path.read_text()
    match = re.search(r'^(?:vllm|sglang) serve\b', text, re.M)
    if not match:
        raise ValueError(f'{path}: missing serve command')
    tokens = shlex.split(text[match.start():].replace('\\\n', ' '), comments=True)
    engine = tokens[0]
    model = tokens[2] if engine == 'vllm' else tokens[tokens.index('--model-path') + 1]
    model_name = model.split('/')[-1].lower()
    family = next((f for f in ('gemma', 'nemotron', 'qwen', 'laguna', 'glm', 'muse') if f in model_name), None)
    if family is None:
        raise ValueError(f'{path}: unknown family; extend recipe_info family mapping')
    scenario = re.search(r'^scenario:\s*(\S+)', text, re.M)
    if not scenario or scenario[1] not in ('low-latency', 'balanced', 'throughput'):
        raise ValueError(f'{path}: invalid scenario')
    return dict(path=str(path.relative_to(ROOT)), runtime=engine, family=family,
                model=model, scenario=scenario[1])


def command(args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def save(path, data):
    path.write_text(yaml.safe_dump(data, sort_keys=False))


def save_job(path, job, scenario):
    """Render FournosJobs in the style of archive/imported-jobs references."""
    lines = [f'# scenario: {scenario}']
    def scalar(value, quoted=False):
        if isinstance(value, str) and quoted:
            return json.dumps(value)
        return yaml.safe_dump(value, default_flow_style=True, width=10000).split('\n...')[0].strip()

    def mapping(data, indent=0, parent=''):
        for key, value in data.items():
            prefix = ' ' * indent + str(key) + ':'
            if parent == 'configOverrides' and (
                key == 'benchmarks.guidellm.fs_group'
                or key.startswith('rhaiis.engines.') and '.images.' in key
                or key in ('tests.rhaiis.model_key', 'tests.rhaiis.workload_keys')
            ):
                lines.append('')
            if isinstance(value, dict):
                lines.append(prefix)
                mapping(value, indent + 2, key)
            elif isinstance(value, list) and key in ('args', 'secretRefs'):
                lines.append(prefix)
                # Match reference: Forge args indented; secretRefs indentless.
                list_indent = indent + 2 if key == 'args' else indent
                for item in value:
                    lines.append(' ' * list_indent + '- ' + scalar(item))
            else:
                quoted = (parent == 'configOverrides' and key not in ('tests.rhaiis.model_key', 'rhaiis.engine')) or key == 'PULL_PULL_SHA'
                if isinstance(value, list):
                    rendered = '[' + ','.join(scalar(v, True) for v in value) + ']'
                else:
                    rendered = scalar(value, quoted)
                lines.append(prefix + ' ' + rendered)
    mapping(job)
    path.write_text('\n'.join(lines) + '\n')


def image_version(runtime, image, scenario):
    engine = 'vLLM' if runtime == 'vllm' else runtime
    version = image.rsplit(':', 1)[-1].removeprefix('v')
    tag = {'low-latency': 'latency-oriented', 'throughput': 'throughput-oriented'}.get(scenario, scenario)
    return f'{engine}-{version}-recipe-{tag}'


def submit(run_dir, oc):
    manifest_path = run_dir / 'run.yaml'
    manifest = read_yaml(manifest_path)
    if not manifest.get('generation_complete'):
        raise ValueError('Generation did not complete; create a new run')
    namespace = manifest['namespace']
    # Require the same cluster context on retries; never silently switch clusters.
    context = command([oc, 'config', 'current-context'])
    if manifest.get('context') and context != manifest['context']:
        raise ValueError('Current oc context differs from this run’s recorded context')
    manifest['context'] = context
    save(manifest_path, manifest)
    pending = [j for j in manifest['jobs'] if j['status'] != 'created']
    if any(j['status'] == 'submitting' for j in pending):
        raise ValueError('Submission was interrupted; reconcile jobs marked submitting before retrying')
    for job in pending:
        command([oc, 'create', '--dry-run=server', '-f', str(run_dir / job['file']), '-n', namespace, '-o', 'name'])
    failures = 0
    for job in pending:
        job['status'] = 'submitting'
        save(manifest_path, manifest)
        try:
            job['resource'] = command([oc, 'create', '-f', str(run_dir / job['file']), '-n', namespace, '-o', 'name'])
            job['status'] = 'created'
            job.pop('error', None)
            print(job['resource'])
        except subprocess.CalledProcessError as exc:
            # A transport failure may occur after the server accepted a job.
            job['status'] = 'submitting'
            job['error'] = exc.stderr
            failures += 1
        save(manifest_path, manifest)
    if failures:
        raise ValueError('Some submissions failed or are uncertain; inspect run.yaml and reconcile before retrying')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ('experiment', 'environment', 'profile', 'family', 'runtime', 'model', 'scenario', 'sha', 'namespace', 'cluster', 'cluster-preset', 'image', 'version'):
        p.add_argument('--' + key)
    p.add_argument('--recipe', action='append', help='Exact recipe path; repeatable')
    p.add_argument('--list', action='store_true', help='List selected recipes without generating')
    p.add_argument('--launch', action='store_true', help='Validate on server, then oc create all jobs')
    p.add_argument('--resume', help='Submit an existing run; skip already created jobs')
    p.add_argument('--oc', default=os.environ.get('OC_BIN', 'oc'))
    a = p.parse_args()
    if a.resume:
        submit(resolve(a.resume), a.oc)
        return
    cfg = read_yaml(resolve(a.experiment)) if a.experiment else {}
    for key, value in vars(a).items():
        if value is not None and key not in ('list', 'launch', 'resume', 'oc'):
            cfg[key] = value
    paths = [resolve(x) for x in cfg.get('recipe', [])] if cfg.get('recipe') else sorted((ROOT / 'recipes').rglob('*.txt'))
    selected = []
    for path in paths:
        info = recipe_info(path)
        if all(not cfg.get(k) or cfg[k].lower() in (info[k].lower(), 'all') for k in ('runtime', 'family', 'scenario')):
            if not cfg.get('model') or cfg['model'].lower() in info['model'].lower():
                selected.append(info)
    if not selected:
        raise ValueError('No recipes match the selection')
    if a.list:
        for info in selected:
            print(f"{info['runtime']:7} {info['family']:9} {info['scenario']:12} {info['path']}")
        return
    if not cfg.get('sha'):
        raise ValueError('--sha is required (or set sha in the experiment)')
    env = read_yaml(resolve(cfg.get('environment', 'environments/zeus.yaml')))
    profile = read_yaml(resolve(cfg.get('profile', 'profiles/standard/profile4-profile6.yaml')))
    workloads = profile.get('workloads')
    if not isinstance(workloads, list) or not workloads or not all(isinstance(w, str) and re.fullmatch(r'[\w-]+', w) for w in workloads):
        raise ValueError('profile.workloads must be a nonempty list of workload names')
    rates = profile.get('rates', [1, 2, 4, 8])
    if not isinstance(rates, list) or not rates or not all(isinstance(x, (int, float)) and x > 0 for x in rates):
        raise ValueError('profile.rates must be a nonempty list of positive numbers')
    cluster = cfg.get('cluster', env['cluster'])
    cluster_preset = cfg.get('cluster_preset', cluster if cfg.get('cluster') else env.get('cluster_preset', cluster))
    namespace = cfg.get('namespace', env.get('namespace', 'psap-automation'))
    run_id = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    run_dir = ROOT / 'runs' / run_id
    (run_dir / 'jobs').mkdir(parents=True)
    (run_dir / 'inputs').mkdir()
    manifest = dict(id=run_id, namespace=namespace, selection=cfg, environment=env, profile=profile, jobs=[])
    manifest['git_revision'] = command(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'])
    manifest['git_dirty'] = bool(command(['git', '-C', str(ROOT), 'status', '--porcelain']))
    save(run_dir / 'run.yaml', manifest)
    for index, info in enumerate(selected, 1):
        slug = f"{index:03}-{info['runtime']}-{info['family']}-{info['scenario']}"
        dest = run_dir / 'jobs' / (slug + '.yaml')
        source = ROOT / info['path']
        snapshot = run_dir / 'inputs' / (slug + '.txt')
        snapshot.write_text(source.read_text())
        args = ['bash', str(ROOT / 'scripts/gen-from-txt.sh'), str(snapshot), '-o', str(dest), '--sha', str(cfg['sha'])]
        image = cfg.get('image', env.get('images', {}).get(info['runtime']))
        if image:
            args += ['--image', image]
        version = cfg.get('version')
        if not version and image:
            version = image_version(info['runtime'], image, info['scenario'])
        if version:
            args += ['--version', version]
        for workload in workloads:
            args += ['--workload', workload]
        args += ['--rates', json.dumps(rates), '--max-seconds', str(profile.get('max_seconds', 450))]
        command(args)
        job = read_yaml(dest)
        spec = job['spec']
        spec['cluster'] = cluster
        spec['owner'] = env.get('owner', spec['owner'])
        spec['hardware']['gpuType'] = env.get('gpu_type', spec['hardware']['gpuType'])
        forge = spec['executionEngine']['forge']
        forge['args'][2] = cluster_preset
        overrides = forge['configOverrides']
        overrides['tests.rhaiis.warmup'] = profile.get('warmup', True)
        for workload in workloads:
            overrides[f'workloads.{workload}.rampup'] = profile.get('rampup', 0)
        custom = profile.get('config_overrides', {})
        if not isinstance(custom, dict) or any(not k.startswith(('workloads.', 'benchmarks.', 'tests.rhaiis.warmup')) for k in custom):
            raise ValueError('config_overrides must be a mapping of workload/benchmark settings')
        overrides.update(custom)
        job['metadata'].setdefault('labels', {})['recipes.forge/run-id'] = run_id.lower()
        save_job(dest, job, info['scenario'])
        manifest['jobs'].append(dict(recipe=info, file=str(dest.relative_to(run_dir)), status='generated'))
    manifest['generation_complete'] = True
    save(run_dir / 'run.yaml', manifest)
    print(f"Generated {len(selected)} jobs: {run_dir}")
    if a.launch:
        submit(run_dir, a.oc)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, yaml.YAMLError, subprocess.CalledProcessError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError):
            print(exc.stderr, file=sys.stderr)
        sys.exit(1)
