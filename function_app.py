# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

import logging
import os
from pathlib import Path
import signal
import subprocess
import sys

import azure.functions as func

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

MAX_HTML_BYTES = 128 * 1024
MAX_PDF_BYTES = 8 * 1024 * 1024
RENDER_PROCESS_TIMEOUT_SECONDS = 20
RENDER_WORKER = Path(__file__).with_name("render_pdf_worker.py")

def _render_pdf(html: str) -> bytes:
    if not RENDER_WORKER.is_file():
        raise RuntimeError("The isolated PDF renderer is missing.")

    environment = os.environ.copy()
    package_path = Path(__file__).parent / (
        ".python_packages/lib/site-packages"
    )
    existing_python_path = environment.get("PYTHONPATH")
    environment["PYTHONPATH"] = os.pathsep.join(
        str(path)
        for path in (package_path, existing_python_path)
        if path
    )
    process = subprocess.Popen(
        [sys.executable, str(RENDER_WORKER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        start_new_session=True,
    )
    try:
        pdf, _ = process.communicate(
            html.encode("utf-8"),
            timeout=RENDER_PROCESS_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise RuntimeError("PDF rendering timed out.") from error

    if process.returncode != 0:
        raise RuntimeError(
            f"PDF renderer exited with code {process.returncode}."
        )
    if len(pdf) > MAX_PDF_BYTES:
        raise ValueError("Rendered PDF exceeds the output limit.")
    if not pdf.startswith(b"%PDF-") or not pdf.rstrip().endswith(b"%%EOF"):
        raise ValueError("Chromium returned an invalid PDF payload.")
    return pdf


def _error_response(message: str, status_code: int) -> func.HttpResponse:
    return func.HttpResponse(
        message,
        status_code=status_code,
        mimetype="text/plain",
        headers={"Cache-Control": "no-store"},
    )


@app.function_name(name="HtmlToPdf")
@app.route(route="html-to-pdf", methods=["POST"])
def html_to_pdf(req: func.HttpRequest) -> func.HttpResponse:
    content_type = req.headers.get("content-type", "")
    if content_type.split(";", 1)[0].strip().lower() != "text/html":
        return _error_response(
            "POST requires Content-Type: text/html.",
            415,
        )

    body = req.get_body()
    if not body:
        return _error_response("The HTML body is required.", 400)
    if len(body) > MAX_HTML_BYTES:
        return _error_response(
            f"HTML input exceeds {MAX_HTML_BYTES} bytes.",
            413,
        )
    try:
        html = body.decode("utf-8")
    except UnicodeDecodeError:
        return _error_response("HTML must be valid UTF-8.", 400)

    try:
        pdf = _render_pdf(html)
    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError):
        logging.exception("HTML-to-PDF rendering failed.")
        return _error_response("PDF rendering failed.", 500)

    return func.HttpResponse(
        pdf,
        status_code=200,
        mimetype="application/pdf",
        headers={
            "Cache-Control": "no-store",
            "Content-Disposition": 'attachment; filename="document.pdf"',
            "X-Content-Type-Options": "nosniff",
        },
    )
