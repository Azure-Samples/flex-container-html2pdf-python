import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT_PATH = (
    Path(__file__).parents[1] / "infra" / "scripts" / "imagecontext.py"
)
SPEC = importlib.util.spec_from_file_location("imagecontext", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Unable to load image-context helper.")
imagecontext = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(imagecontext)


class ImageContextTests(unittest.TestCase):
    def _create_repository(self, root: Path) -> None:
        for name in imagecontext.IMAGE_INPUTS:
            value = (
                "https://aka.ms/example-worker.tar.gz\n"
                if name == imagecontext.WORKER_RELEASE_FILE
                else f"{name}\n"
            )
            (root / name).write_text(value, encoding="utf-8")
        (root / "README.md").write_text("not an image input\n", encoding="utf-8")

    def test_context_contains_only_declared_inputs(self):
        with tempfile.TemporaryDirectory() as repository_dir:
            with tempfile.TemporaryDirectory() as destination_dir:
                repository = Path(repository_dir)
                destination = Path(destination_dir)
                self._create_repository(repository)

                context_hash = imagecontext.prepare_image_context(
                    repository,
                    destination,
                    worker_url_resolver=lambda _: (
                        "https://github.com/Azure/"
                        "azure-functions-python-worker/releases/download/"
                        "4.47.1/worker.tar.gz"
                    ),
                )

                self.assertRegex(context_hash, r"^[0-9a-f]{64}$")
                self.assertEqual(
                    sorted(path.name for path in destination.iterdir()),
                    sorted(imagecontext.IMAGE_INPUTS),
                )
                self.assertFalse((destination / "README.md").exists())
                self.assertEqual(
                    (
                        destination / imagecontext.WORKER_RELEASE_FILE
                    ).read_text(encoding="utf-8").strip(),
                    (
                        "https://github.com/Azure/"
                        "azure-functions-python-worker/releases/download/"
                        "4.47.1/worker.tar.gz"
                    ),
                )

    def test_hash_changes_only_when_image_inputs_change(self):
        with tempfile.TemporaryDirectory() as repository_dir:
            repository = Path(repository_dir)
            self._create_repository(repository)

            with tempfile.TemporaryDirectory() as first_dir:
                first_hash = imagecontext.prepare_image_context(
                    repository,
                    Path(first_dir),
                    worker_url_resolver=lambda _: (
                        "https://github.com/Azure/"
                        "azure-functions-python-worker/releases/download/"
                        "4.47.1/worker.tar.gz"
                    ),
                )

            (repository / "README.md").write_text(
                "documentation changed\n",
                encoding="utf-8",
            )
            with tempfile.TemporaryDirectory() as second_dir:
                second_hash = imagecontext.prepare_image_context(
                    repository,
                    Path(second_dir),
                    worker_url_resolver=lambda _: (
                        "https://github.com/Azure/"
                        "azure-functions-python-worker/releases/download/"
                        "4.47.1/worker.tar.gz"
                    ),
                )
            self.assertEqual(first_hash, second_hash)

            (repository / "function_app.py").write_text(
                "application changed\n",
                encoding="utf-8",
            )
            with tempfile.TemporaryDirectory() as third_dir:
                third_hash = imagecontext.prepare_image_context(
                    repository,
                    Path(third_dir),
                    worker_url_resolver=lambda _: (
                        "https://github.com/Azure/"
                        "azure-functions-python-worker/releases/download/"
                        "4.47.1/worker.tar.gz"
                    ),
                )
            self.assertNotEqual(first_hash, third_hash)

    def test_hash_changes_when_worker_release_changes(self):
        with tempfile.TemporaryDirectory() as repository_dir:
            repository = Path(repository_dir)
            self._create_repository(repository)

            with tempfile.TemporaryDirectory() as first_dir:
                first_hash = imagecontext.prepare_image_context(
                    repository,
                    Path(first_dir),
                    worker_url_resolver=lambda _: (
                        "https://github.com/Azure/"
                        "azure-functions-python-worker/releases/download/"
                        "4.47.1/worker.tar.gz"
                    ),
                )
            with tempfile.TemporaryDirectory() as second_dir:
                second_hash = imagecontext.prepare_image_context(
                    repository,
                    Path(second_dir),
                    worker_url_resolver=lambda _: (
                        "https://github.com/Azure/"
                        "azure-functions-python-worker/releases/download/"
                        "4.48.0/worker.tar.gz"
                    ),
                )

            self.assertNotEqual(first_hash, second_hash)


if __name__ == "__main__":
    unittest.main()
