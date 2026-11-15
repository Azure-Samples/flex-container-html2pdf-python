# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

import unittest
from unittest import mock

import render_pdf_worker


class RenderPdfWorkerTests(unittest.TestCase):
    def test_sandboxed_render_preserves_browser_and_resource_controls(self):
        pdf = b"%PDF-1.7\nrendered document\n%%EOF\n"
        html = "<h1>Sandboxed document</h1>"
        with (
            mock.patch.object(render_pdf_worker.os.path, "isfile", return_value=True),
            mock.patch.object(render_pdf_worker, "sync_playwright") as playwright,
        ):
            chromium = playwright.return_value.__enter__.return_value.chromium
            browser = chromium.launch.return_value
            context = browser.new_context.return_value
            page = context.new_page.return_value
            page.pdf.return_value = pdf

            self.assertEqual(render_pdf_worker._render(html), pdf)

            chromium.launch.assert_called_once()
            launch_options = chromium.launch.call_args.kwargs
            self.assertIs(launch_options.get("chromium_sandbox"), True)
            self.assertIs(launch_options["headless"], True)
            self.assertGreater(launch_options["timeout"], 0)
            self.assertEqual(
                launch_options["executable_path"],
                render_pdf_worker.CHROMIUM_EXECUTABLE,
            )
            context_options = browser.new_context.call_args.kwargs
            self.assertIs(context_options["accept_downloads"], False)
            self.assertIs(context_options["java_script_enabled"], False)
            self.assertEqual(context_options["service_workers"], "block")
            context.set_default_timeout.assert_called_once_with(
                launch_options["timeout"],
            )
            page.set_content.assert_called_once_with(
                html,
                wait_until="domcontentloaded",
                timeout=launch_options["timeout"],
            )
            page.route.assert_called_once()
            pattern, handle_route = page.route.call_args.args
            self.assertEqual(pattern, "**/*")
            for url, allowed in (
                ("https://example.invalid/tracker.png", False),
                ("file:///etc/passwd", False),
                ("data:image/png;base64,aGVsbG8=", True),
                ("about:blank", True),
            ):
                with self.subTest(url=url):
                    route = mock.Mock()
                    route.request.url = url
                    handle_route(route)
                    if allowed:
                        route.continue_.assert_called_once_with()
                        route.abort.assert_not_called()
                    else:
                        route.abort.assert_called_once_with()
                        route.continue_.assert_not_called()
            page.close.assert_called_once_with()
            context.close.assert_called_once_with()
            browser.close.assert_called_once_with()

    def test_sandbox_launch_failure_does_not_retry_without_sandbox(self):
        with (
            mock.patch.object(render_pdf_worker.os.path, "isfile", return_value=True),
            mock.patch.object(render_pdf_worker, "sync_playwright") as playwright,
        ):
            chromium = playwright.return_value.__enter__.return_value.chromium
            chromium.launch.side_effect = RuntimeError("Sandbox unavailable")

            with self.assertRaisesRegex(RuntimeError, "Sandbox unavailable"):
                render_pdf_worker._render("<h1>Untrusted document</h1>")

            chromium.launch.assert_called_once()
            self.assertIs(
                chromium.launch.call_args.kwargs.get("chromium_sandbox"),
                True,
            )
            chromium.launch.return_value.new_context.assert_not_called()


if __name__ == "__main__":
    unittest.main()
