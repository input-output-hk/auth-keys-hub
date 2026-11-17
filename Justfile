list:
  just -l

test:
  crystal spec

test-invalid-token:
  rm -rf tmp
  mkdir -p tmp
  crystal build ./src/auth-keys-hub.cr
  ./auth-keys-hub --ttl 0s --dir tmp --github-token-file tests/fixtures/dummy-token --github-users manveru --github-teams input-output-hk/devops
  cat tmp/log

test-invalid-user:
  rm -rf tmp
  mkdir -p tmp
  crystal build ./src/auth-keys-hub.cr
  ./auth-keys-hub --ttl 0s --dir tmp --github-users a1b2c3d4e5f6g7h8 --github-teams input-output-hk/devops
  cat tmp/log

# Offline CLI tests with synthetic keys, tokens, and loopback HTTP endpoints.
test-regressions:
  crystal spec spec/cache_regressions_spec.cr
