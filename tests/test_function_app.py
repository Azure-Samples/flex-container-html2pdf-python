# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

import azure.functions as func

import function_app

FUNCTIONS = {
    function.get_function_name(): function
    for function in function_app.app.get_functions()
}
HTML_TO_PDF_HANDLER = FUNCTIONS["HtmlToPdf"].get_user_function()


class FunctionMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.functions = FUNCTIONS

    def test_indexing_metadata(self):
        self.assertEqual(set(self.functions), {"HtmlToPdf"})
        expected_routes = {
            "HtmlToPdf": ("html-to-pdf", {"POST"}),
        }

        for function_name, (route, methods) in expected_routes.items():
            with self.subTest(function=function_name):
                function = self.functions[function_name]
                bindings = json.loads(function.get_function_json())["bindings"]
                self.assertEqual(len(bindings), 2)
                trigger = next(
                    binding for binding in bindings
                    if binding["type"] == "httpTrigger"
                )
                self.assertEqual(trigger["name"], "req")
                self.assertEqual(trigger["direction"], "IN")
                self.assertEqual(trigger["route"], route)
                self.assertEqual(
                    {method.upper() for method in trigger["methods"]},
                    methods,
                )
                self.assertEqual(trigger["authLevel"], "ANONYMOUS")

                output = next(
                    binding for binding in bindings
                    if binding["type"] == "http"
                )
                self.assertEqual(output["name"], "$return")
                self.assertEqual(output["direction"], "OUT")


class HtmlToPdfFunctionTests(unittest.TestCase):
    def _request(
        self,
        method,
        body=b"",
        headers=None,
    ):
        return func.HttpRequest(
            method=method,
            url="http://localhost/api/html-to-pdf",
            headers=headers or {},
            params={},
            body=body,
        )

    def _assert_pdf(self, response, filename):
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.mimetype, "application/pdf")
        self.assertEqual(
            response.headers["Content-Disposition"],
            f'attachment; filename="{filename}"',
        )
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertEqual(
            response.headers["X-Content-Type-Options"],
            "nosniff",
        )
        pdf = response.get_body()
        self.assertGreater(len(pdf), 1000)
        self.assertTrue(pdf.startswith(b"%PDF-"))
        self.assertTrue(pdf.rstrip().endswith(b"%%EOF"))

    def test_post_renders_bounded_html_and_blocks_external_resources(self):
        html = b"""<!doctype html>
<html>
<body>
  <h1>Posted document</h1>
  <img src="https://example.invalid/tracker.png">
  <script>document.body.innerHTML = "JavaScript ran";</script>
</body>
</html>"""
        response = HTML_TO_PDF_HANDLER(
            self._request(
                "POST",
                body=html,
                headers={"content-type": "text/html; charset=utf-8"},
            )
        )
        self._assert_pdf(response, "document.pdf")

    def test_post_requires_text_html(self):
        response = HTML_TO_PDF_HANDLER(
            self._request(
                "POST",
                body=b"<h1>Wrong type</h1>",
                headers={"content-type": "text/plain"},
            )
        )
        self.assertEqual(response.status_code, 415)

    def test_post_rejects_empty_body(self):
        response = HTML_TO_PDF_HANDLER(
            self._request(
                "POST",
                headers={"content-type": "text/html"},
            )
        )
        self.assertEqual(response.status_code, 400)

    def test_post_rejects_oversized_body(self):
        response = HTML_TO_PDF_HANDLER(
            self._request(
                "POST",
                body=b"x" * (function_app.MAX_HTML_BYTES + 1),
                headers={"content-type": "text/html"},
            )
        )
        self.assertEqual(response.status_code, 413)

    def test_renderer_process_is_killed_after_hard_timeout(self):
        worker_path = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                suffix=".py",
                delete=False,
            ) as worker:
                worker.write("import time\ntime.sleep(60)\n")
                worker_path = Path(worker.name)

            started = time.monotonic()
            with (
                mock.patch.object(
                    function_app,
                    "RENDER_WORKER",
                    worker_path,
                ),
                mock.patch.object(
                    function_app,
                    "RENDER_PROCESS_TIMEOUT_SECONDS",
                    0.2,
                ),
                self.assertRaisesRegex(RuntimeError, "timed out"),
            ):
                function_app._render_pdf("<p>timeout</p>")
            self.assertLess(time.monotonic() - started, 5)
        finally:
            if worker_path:
                worker_path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
