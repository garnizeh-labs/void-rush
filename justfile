# Void-Rush Validation Scripts

# Run all checks
check: check-docs

# Standard documentation validation
check-docs:
    python3 scripts/doc_lint.py
    python3 scripts/check_links.py
    python3 scripts/check_branding.py
    codespell --config .codespellrc || true
