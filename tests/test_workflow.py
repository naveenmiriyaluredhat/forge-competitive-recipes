import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runner', ROOT / 'scripts/run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SubmissionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.run = Path(self.tmp.name)
        runner.save(self.run / 'run.yaml', dict(generation_complete=True, namespace='psap-automation', jobs=[
            dict(file='a.yaml', status='generated'), dict(file='b.yaml', status='generated')]))

    def test_validate_all_before_create_and_skip_created(self):
        calls = []
        def fake(args):
            calls.append(args)
            return 'context' if args[1] == 'config' else 'fournosjob/example'
        with patch.object(runner, 'command', side_effect=fake):
            runner.submit(self.run, 'oc')
            self.assertTrue(all('--dry-run=server' in c for c in calls[1:3]))
            self.assertTrue(all('--dry-run=server' not in c for c in calls[3:]))
            self.assertEqual(len(calls), 5)
            runner.submit(self.run, 'oc')
            self.assertEqual(len(calls), 6)  # only context check on resume

    def test_preflight_failure_creates_nothing(self):
        calls = []
        def fake(args):
            calls.append(args)
            if len(calls) == 3:
                raise subprocess.CalledProcessError(1, args, stderr='invalid')
            return 'context'
        with patch.object(runner, 'command', side_effect=fake):
            with self.assertRaises(subprocess.CalledProcessError):
                runner.submit(self.run, 'oc')
        self.assertTrue(all('--dry-run=server' in c for c in calls[1:]))

    def test_uncertain_submission_blocks_retry(self):
        def fake(args):
            if args[1] == 'config':
                return 'context'
            if '--dry-run=server' not in args:
                raise subprocess.CalledProcessError(1, args, stderr='connection lost')
            return 'valid'
        with patch.object(runner, 'command', side_effect=fake):
            with self.assertRaises(ValueError):
                runner.submit(self.run, 'oc')
            with self.assertRaisesRegex(ValueError, 'interrupted'):
                runner.submit(self.run, 'oc')

    def test_incomplete_generation_blocked(self):
        runner.save(self.run / 'run.yaml', dict(generation_complete=False))
        with self.assertRaisesRegex(ValueError, 'Generation'):
            runner.submit(self.run, 'oc')


class GenerationTests(unittest.TestCase):
    def test_all_recipes_parse_and_hardware_matches_paths(self):
        recipes = list((ROOT / 'recipes').rglob('*.txt'))
        self.assertTrue(recipes)
        for recipe in recipes:
            info = runner.recipe_info(recipe)
            self.assertIn('/' + info['runtime'] + '/' + info['family'] + '/', str(recipe))

    def test_job_format_matches_reference_and_preserves_values(self):
        reference = ROOT / 'archive/imported-jobs/rhaiis-g4-26b-a4b-bal.yaml'
        job = runner.read_yaml(reference)
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'job.yaml'
            runner.save_job(output, job, 'balanced')
            self.assertEqual(output.read_text(), reference.read_text())
            self.assertEqual(runner.read_yaml(output), job)
        self.assertEqual(runner.image_version('vllm', 'vllm/vllm-openai:v0.29.0', 'balanced'),
                         'vLLM-0.29.0-recipe-balanced')

    def test_inkling_exports_reach_model_server(self):
        recipe = ROOT / 'recipes/vllm/inkling/inkling-small-nvfp4/h200-2gpu/low-latency.txt'
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / 'job.yaml'
            subprocess.run(['bash', str(ROOT / 'scripts/gen-from-txt.sh'), str(recipe),
                            '-o', str(dest)], check=True, capture_output=True, text=True)
            job = runner.read_yaml(dest)
        config = job['spec']['executionEngine']['forge']['configOverrides']
        for name in ('VLLM_USE_V2_MODEL_RUNNER', 'FLASH_ATTENTION_CUTE_DSL_CACHE_ENABLED'):
            self.assertEqual(config['rhaiis.env_vars.' + name], '1')
        self.assertEqual(config['rhaiis.engines.vllm.args.tokenizer-mode'], 'inkling')
        self.assertEqual(config['rhaiis.engines.vllm.args.tensor-parallel-size'], 2)

    def test_generator_image_version_overrides(self):
        out = subprocess.run(['bash', str(ROOT / 'scripts/gen-fournos-job.sh'),
            '--from-serve', 'vllm serve example/model --tensor-parallel-size 8',
            '--image', 'example/image:v1', '--version', 'test', '--sha', 'test-sha'],
            check=True, text=True, capture_output=True).stdout
        job = yaml.safe_load(out)
        self.assertEqual(job['spec']['hardware']['gpuCount'], 8)
        self.assertEqual(job['spec']['env']['PULL_PULL_SHA'], 'test-sha')
        self.assertEqual(job['spec']['executionEngine']['forge']['configOverrides']['rhaiis.engines.vllm.images.nvidia'], 'example/image:v1')


if __name__ == '__main__':
    unittest.main()
