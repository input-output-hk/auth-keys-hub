list:
  just -l

test:
  just test-invalid-token
  just test-invalid-user

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
