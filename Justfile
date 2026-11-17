list:
  just -l

test:
  crystal spec

# Offline CLI tests with synthetic keys, tokens, and loopback HTTP endpoints.
test-regressions:
  crystal spec spec/cache_regressions_spec.cr
