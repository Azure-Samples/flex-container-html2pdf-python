import os
import sys

from playwright.sync_api import sync_playwright

MAX_HTML_BYTES = 128 * 1024
MAX_PDF_BYTES = 8 * 1024 * 1024
PLAYWRIGHT_TIMEOUT_MS = 15_000
CHROMIUM_EXECUTABLE = os.environ.get(
    "CHROMIUM_EXECUTABLE",
    "/usr/bin/chromium",
)


def _handle_route(route) -> None:
    if route.request.url.startswith(("data:", "about:blank")):
        route.continue_()
    else:
        route.abort()


def _render(html: str) -> bytes:
    if not os.path.isfile(CHROMIUM_EXECUTABLE):
        raise RuntimeError("System Chromium is unavailable.")

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path=CHROMIUM_EXECUTABLE,
            headless=True,
            timeout=PLAYWRIGHT_TIMEOUT_MS,
        )
        try:
            context = browser.new_context(
                accept_downloads=False,
                java_script_enabled=False,
                service_workers="block",
            )
            try:
                context.set_default_timeout(PLAYWRIGHT_TIMEOUT_MS)
                page = context.new_page()
                try:
                    page.route("**/*", _handle_route)
                    page.emulate_media(media="print")
                    page.set_content(
                        html,
                        wait_until="domcontentloaded",
                        timeout=PLAYWRIGHT_TIMEOUT_MS,
                    )
                    pdf = page.pdf(
                        format="A4",
                        margin={
                            "top": "0",
                            "right": "0",
                            "bottom": "0",
                            "left": "0",
                        },
                        prefer_css_page_size=True,
                        print_background=True,
                    )
                finally:
                    page.close()
            finally:
                context.close()
        finally:
            browser.close()

    if len(pdf) > MAX_PDF_BYTES:
        raise ValueError("Rendered PDF exceeds the output limit.")
    if not pdf.startswith(b"%PDF-") or not pdf.rstrip().endswith(b"%%EOF"):
        raise ValueError("Chromium returned an invalid PDF payload.")
    return pdf


def main() -> int:
    body = sys.stdin.buffer.read(MAX_HTML_BYTES + 1)
    if not body or len(body) > MAX_HTML_BYTES:
        return 2
    html = body.decode("utf-8")
    sys.stdout.buffer.write(_render(html))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(type(error).__name__, file=sys.stderr)
        raise SystemExit(1) from error
