"""Check fresh/repeated dependency preparation without network or game inputs."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import build_vulkan_core as gpu


class VulkanDependencyTests(unittest.TestCase):
    def test_gpu_completion_patch_is_idempotent(self):
        patch_file = Path(__file__).resolve().parents[1] / 'patches/libretro-vulkan-frame-completion.patch'
        original = ''.join(line[1:] + '\n' for line in patch_file.read_text().splitlines()[3:]
                           if line.startswith((' ', '-')))
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            target = source / 'src/citra_libretro/libretro_vk.cpp'
            target.parent.mkdir(parents=True)
            target.write_text('\n' * 696 + original)
            gpu.apply_source_patch(source, patch_file)
            gpu.apply_source_patch(source, patch_file)
            self.assertEqual(target.read_text().count('scheduler.Finish();'), 1)

    def test_pinned_initialization_repeat_and_provenance_refusal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / '.local/source'
            source.mkdir(parents=True)
            metadata = root / f'.local/reference/upstream-tree-{gpu.COMMIT}.json'
            metadata.parent.mkdir()
            revisions = {module: f'{i:040x}' for i, module in enumerate(gpu.MODULES, 1)}
            metadata.write_text(json.dumps({'tree': [{'path': module, 'type': 'commit', 'sha': revision}
                for module, revision in revisions.items()]}))
            (source / '.gitmodules').write_text('\n'.join(
                f'[submodule "{module}"]\npath={module}\nurl=https://example.invalid/{i}'
                for i, module in enumerate(gpu.MODULES)))
            fetches = []

            def fake_run(*args, **kwargs):
                if args[1] == 'fetch':
                    fetches.append(args[-1])
                if args[1] == 'checkout':
                    (kwargs['cwd'] / 'CMakeLists.txt').write_text('# synthetic dependency\n')

            with patch.object(gpu, 'ROOT', root), patch.object(gpu, 'SOURCE', source), patch.object(gpu, 'run', fake_run):
                gpu.prepare_graphics_dependencies()
                self.assertEqual(fetches, list(revisions.values()))
                gpu.prepare_graphics_dependencies()
                self.assertEqual(len(fetches), len(gpu.MODULES))
                provenance = root / '.local/vulkan-source-provenance.json'
                data = json.loads(provenance.read_text())
                data['submodules'][0]['commit'] = 'wrong revision'
                provenance.write_text(json.dumps(data))
                with self.assertRaisesRegex(ValueError, 'Unverified graphics dependency'):
                    gpu.prepare_graphics_dependencies()


if __name__ == '__main__':
    unittest.main()
