set shell := ["sh", "-eu", "-c"]

test:
  ./scripts/test.sh

fmt-check:
  if command -v stylua >/dev/null 2>&1; then \
    stylua --check lua plugin tests examples; \
  elif [ "${CI:-}" = "true" ]; then \
    echo "stylua is required in CI"; \
    exit 1; \
  else \
    echo "stylua not installed; skipping format check"; \
  fi

ci: test fmt-check

validate-ra:
  mkdir -p .tmp/nvim-state .tmp/nvim-cache
  XDG_STATE_HOME="$PWD/.tmp/nvim-state" XDG_CACHE_HOME="$PWD/.tmp/nvim-cache" nvim --headless -u NONE -i NONE -n -c "lua local ok, err = pcall(dofile, 'scripts/validate-rust-analyzer.lua'); if not ok then print(err); vim.cmd('cquit') end" -c "qa"
