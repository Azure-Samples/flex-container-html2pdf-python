#!/usr/bin/env python3

import hashlib
from pathlib import Path
import shutil
import stat
import sys
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


WORKER_RELEASE_FILE = "worker-release-url.txt"
IMAGE_INPUTS = (
    ".dockerignore",
    "Dockerfile",
    "function_app.py",
    "host.json",
    "render_pdf_worker.py",
    "requirements.txt",
    WORKER_RELEASE_FILE,
)


class _NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(
        self,
        request,
        file_pointer,
        code,
        message,
        headers,
        new_url,
    ):
        return None


def resolve_worker_release_url(url: str) -> str:
    request = Request(
        url,
        headers={"User-Agent": "flex-container-image-context"},
        method="HEAD",
    )
    try:
        with build_opener(_NoRedirectHandler).open(
            request,
            timeout=30,
        ) as response:
            location = response.headers.get("Location")
    except HTTPError as error:
        if error.code not in {301, 302, 303, 307, 308}:
            raise
        location = error.headers.get("Location")

    if not location:
        raise ValueError("The worker release URL did not return a redirect.")

    parsed = urlparse(location)
    if (
        parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or not parsed.path.startswith(
            "/Azure/azure-functions-python-worker/releases/download/"
        )
    ):
        raise ValueError(
            f"Unexpected worker release redirect target: {location}"
        )
    return location


def _copy_entry(source: Path, destination: Path) -> None:
    if source.is_symlink():
        raise ValueError(f"Symbolic links are not allowed: {source}")
    if source.is_dir():
        destination.mkdir(mode=0o755)
        for child in sorted(source.iterdir(), key=lambda path: path.name):
            _copy_entry(child, destination / child.name)
        return
    if not source.is_file():
        raise ValueError(f"Unsupported image-context entry: {source}")

    shutil.copyfile(source, destination)
    destination.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH)


def hash_image_context(context_root: Path) -> str:
    root = context_root.resolve()
    digest = hashlib.sha256()
    digest.update(b"flex-container-image-context-v1\0")

    def visit(path: Path) -> None:
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise ValueError(f"Symbolic links are not allowed: {path}")
        if path.is_dir():
            digest.update(f"directory\0{relative}\0".encode())
            for child in sorted(path.iterdir(), key=lambda item: item.name):
                visit(child)
            return
        if not path.is_file():
            raise ValueError(f"Unsupported image-context entry: {path}")

        content = path.read_bytes()
        digest.update(f"file\0{relative}\0{len(content)}\0".encode())
        digest.update(content)
        digest.update(b"\0")

    for entry in sorted(root.iterdir(), key=lambda path: path.name):
        visit(entry)
    return digest.hexdigest()


def prepare_image_context(
    repository_root: Path,
    destination_root: Path,
    worker_url_resolver=resolve_worker_release_url,
) -> str:
    repository = repository_root.resolve()
    destination = destination_root.resolve()
    destination.mkdir(parents=True, mode=0o755, exist_ok=True)
    if any(destination.iterdir()):
        raise ValueError(
            f"Image-context destination must be empty: {destination}"
        )

    for input_name in IMAGE_INPUTS:
        source = repository / input_name
        if not source.exists():
            raise FileNotFoundError(f"Required image input is missing: {source}")
        destination_path = destination / input_name
        if input_name == WORKER_RELEASE_FILE:
            floating_url = source.read_text(encoding="utf-8").strip()
            resolved_url = worker_url_resolver(floating_url)
            destination_path.write_text(
                f"{resolved_url}\n",
                encoding="utf-8",
            )
            destination_path.chmod(
                stat.S_IRUSR
                | stat.S_IWUSR
                | stat.S_IRGRP
                | stat.S_IROTH
            )
        else:
            _copy_entry(source, destination_path)

    return hash_image_context(destination)


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Usage: python infra/scripts/imagecontext.py "
            "<empty-destination-directory>",
            file=sys.stderr,
        )
        return 2

    repository_root = Path(__file__).resolve().parents[2]
    try:
        context_hash = prepare_image_context(
            repository_root,
            Path(sys.argv[1]),
        )
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1

    print(context_hash)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
