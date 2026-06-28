# `--sosumi-base-url`

Use a Sosumi HTTP API endpoint for rendered documentation Markdown during web crawls.

```bash
cupertino fetch --source apple-docs --sosumi-base-url https://sosumi.ai
```

This keeps Apple DocC JSON as the primary path in `--discovery-mode auto`, but replaces the WKWebView rendered-page fallback with Sosumi Markdown. For large crawls, prefer a self-hosted Sosumi instance over the public shared service.
