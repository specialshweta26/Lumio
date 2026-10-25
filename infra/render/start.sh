#!/usr/bin/env bash
# One Render web service runs migrations, the API, the worker, and the web UI.
# The published image listens on 5173; Render assigns $PORT and proxies HTTPS to it.
set -euo pipefail
umask 077

public_url="${RENDER_EXTERNAL_URL:-${BETTER_AUTH_URL:-}}"
host="${public_url#https://}"
host="${host#http://}"
host="${host%%/*}"

export NODE_ENV=production
export SANDBOX_PROVIDER="${SANDBOX_PROVIDER:-e2b}"
export PHONE_CALLS_ENABLED="${PHONE_CALLS_ENABLED:-true}"
export DATA_DIR="${DATA_DIR:-/tmp/rakazo-data}"
export API_HOST="${API_HOST:-127.0.0.1}"
export API_URL="${API_URL:-http://127.0.0.1:3100}"
export API_PROXY_TARGET="${API_PROXY_TARGET:-http://127.0.0.1:3100}"
export WEB_PORT="${PORT:-5173}"
export TRUSTED_PROXIES="${TRUSTED_PROXIES:-127.0.0.1}"
export SIGNUPS_ENABLED="${SIGNUPS_ENABLED:-true}"
export CONTENT_ENCRYPTION="${CONTENT_ENCRYPTION:-on}"

if [[ -n "$public_url" ]]; then
  export BETTER_AUTH_URL="${BETTER_AUTH_URL:-$public_url}"
  export WEB_ORIGIN="${WEB_ORIGIN:-$public_url}"
  export RAKAZO_HOST="${RAKAZO_HOST:-$host}"
  export RAKAZO_ALLOWED_HOSTS="${RAKAZO_ALLOWED_HOSTS:-$host}"
fi

mkdir -p "$DATA_DIR"

# A computer saved as "none" or "fake" fails the chat snapshot and skips the
# real sandbox. Point existing rows at the configured provider.
if [[ "$SANDBOX_PROVIDER" != "none" ]]; then
  (
    cd /app/packages/db
    node --input-type=module -e '
      import pg from "pg";
      const kind = process.env.SANDBOX_PROVIDER;
      const allowed = new Set(["docker", "e2b", "daytona", "createos", "boat", "railway", "desktop", "fake"]);
      if (!allowed.has(kind)) process.exit(0);
      const client = new pg.Client({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 8000 });
      await client.connect();
      const result = await client.query(
        "update computers set kind=$1, \"providerRef\"=null, state=$2 where kind <> $1",
        [kind, "stopped"],
      );
      console.log("computer-kind-updated", result.rowCount);
      await client.query(`
        CREATE OR REPLACE FUNCTION revoke_computer_screens() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF (NEW.state IS DISTINCT FROM OLD.state AND NOT (
                (OLD.state = $s$booting$s$ AND NEW.state = $s$running$s$)
                OR (OLD.state = $s$running$s$ AND NEW.state = $s$booting$s$)
              ))
            OR NEW."providerRef" IS DISTINCT FROM OLD."providerRef" THEN
            NEW."screenGeneration" := OLD."screenGeneration" + 1;
          END IF;
          RETURN NEW;
        END;
        $$`);
      console.log("screen-trigger-updated");
      await client.end();
    '
  ) || echo "computer-kind-update-failed" >&2
fi

# The published image is branded Rakazo. Serve a copy whose visible name is Lumio.
lumio_root=/tmp/lumio
rm -rf "$lumio_root"
mkdir -p "$lumio_root/apps/web"
ln -s /app/node_modules "$lumio_root/node_modules"
ln -s /app/packages "$lumio_root/packages"
for app in api worker; do
  mkdir -p "$lumio_root/apps/$app/dist"
  for entry in /app/apps/$app/* /app/apps/$app/.[!.]*; do
    [[ -e "$entry" ]] || continue
    name="$(basename "$entry")"
    [[ "$name" == "dist" ]] && continue
    ln -s "$entry" "$lumio_root/apps/$app/$name"
  done
  for entry in /app/apps/$app/dist/*; do
    name="$(basename "$entry")"
    case "$name" in
      index.js | index.js.map) ;;
      *) ln -s "$entry" "$lumio_root/apps/$app/dist/$name" ;;
    esac
  done
  sed "s/Rakazo/Lumio/g" "/app/apps/$app/dist/index.js" > "$lumio_root/apps/$app/dist/index.js"
done
cp -a /app/apps/web/dist "$lumio_root/apps/web/dist"
find "$lumio_root/apps/web/dist" -type f \( \
  -name "*.js" -o -name "*.css" -o -name "*.html" -o -name "*.json" -o \
  -name "*.webmanifest" -o -name "*.svg" -o -name "*.txt" \
\) -exec sed -i "s/Rakazo/Lumio/g" {} +
echo "lumio-rename-done" >&2

# One automatic Retry while the computer is still running. The published web
# bundle otherwise leaves a revoked screen on the error until the user clicks.
node --input-type=module -e '
import { readFileSync, writeFileSync } from "node:fs";
const page = process.env.LUMIO_INDEX || "'"$lumio_root"'/apps/web/dist/index.html";
const script = `<script id="lumio-screen-retry">
(function () {
  var tries = 0;
  new MutationObserver(function () {
    if (tries >= 1) return;
    var alert = document.querySelector("[role=alert]");
    if (!alert || alert.textContent.indexOf("Could not connect to the computer screen") < 0) return;
    var button = alert.querySelector("button");
    if (!button) return;
    tries += 1;
    setTimeout(function () { button.click(); }, 600);
  }).observe(document.documentElement, { subtree: true, childList: true, characterData: true });
})();
</script>`;
let html = readFileSync(page, "utf8");
if (html.includes("lumio-screen-retry")) process.exit(0);
html = html.includes("</body>") ? html.replace("</body>", script + "</body>") : html + script;
writeFileSync(page, html);
console.log("screen-retry-injected");
' || echo "screen-retry-inject-failed" >&2

cd /app
node --enable-source-maps apps/api/dist/cli/migrate-database.js
echo "migrate-done" >&2

trap 'kill $(jobs -p) 2>/dev/null || true; wait || true' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

(cd "$lumio_root/apps/api" && node dist/index.js) &
(cd "$lumio_root/apps/worker" && node dist/index.js) &
(
  cd /app/apps/web
  exec ./node_modules/.bin/vite preview --host 0.0.0.0 --port "$WEB_PORT" --outDir "$lumio_root/apps/web/dist"
) &
wait
