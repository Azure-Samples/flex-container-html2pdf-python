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
            (root / name).write_text(f"{name}\n", encoding="utf-8")
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
                )

                self.assertRegex(context_hash, r"^[0-9a-f]{64}$")
                self.assertEqual(
                    sorted(path.name for path in destination.iterdir()),
                    sorted(imagecontext.IMAGE_INPUTS),
                )
                self.assertFalse((destination / "README.md").exists())

    def test_hash_changes_only_when_image_inputs_change(self):
        with tempfile.TemporaryDirectory() as repository_dir:
            repository = Path(repository_dir)
            self._create_repository(repository)

            with tempfile.TemporaryDirectory() as first_dir:
                first_hash = imagecontext.prepare_image_context(
                    repository,
                    Path(first_dir),
                )

            (repository / "README.md").write_text(
                "documentation changed\n",
                encoding="utf-8",
            )
            with tempfile.TemporaryDirectory() as second_dir:
                second_hash = imagecontext.prepare_image_context(
                    repository,
                    Path(second_dir),
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
                )
            self.assertNotEqual(first_hash, third_hash)


if __name__ == "__main__":
    unittest.main()
