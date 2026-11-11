#!/usr/bin/env bash
# Build only the modular Original Lampa core, preserving ILampa's tested ByLampa plugin resources.
set -euo pipefail
SHA="9dce3c08fa92ca3ffd43939b06d66062f88046e5"
ROOT="$PWD"
STAGING="$ROOT/build/upstream-fusion"
mkdir -p "$ROOT/build"
if [ ! -d "$STAGING/.git" ]; then
  git clone --filter=blob:none https://github.com/yumata/lampa-source.git "$STAGING"
fi
git -C "$STAGING" fetch --no-tags origin "$SHA"
git -C "$STAGING" checkout --detach "$SHA"
test "$(git -C "$STAGING" rev-parse HEAD)" = "$SHA"
(
  cd "$STAGING"
  # Upstream has no lockfile at this revision. Dependency graph must be separately locked
  # before treating this as a fully reproducible release build.
  npm install --ignore-scripts --no-audit --no-fund
  printf '\nexports.ilampa_merge = merge;\n' >> gulpfile.js
  npx --no-install gulp ilampa_merge
  test -s dest/app.js
)
cp "$STAGING/dest/app.js" "$ROOT/iLampa/Resources/www/app.min.js"
node --check "$ROOT/iLampa/Resources/www/app.min.js"
test -s "$ROOT/iLampa/Resources/plugins/online_mod.js"
printf 'Original Lampa source SHA=%s; local ByLampa Online Mod preserved\n' "$SHA"
