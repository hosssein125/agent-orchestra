#!/usr/bin/env bash
# _build-pkg.sh — build the publishable package of the orchestration into a
# temp dir: the engine + docs + empty ledger skeleton; NO live data
# (transcripts, feature files, session ids, activity log, product config).
set -euo pipefail
SRC="F:/Projects/BonnychowCoordination"
P="/tmp/agent-orchestra-pkg"
rm -rf "$P" && mkdir -p "$P"

# engine + docs (generic; product names scrubbed in-repo already)
cp -r "$SRC/scripts" "$SRC/templates" "$SRC/hooks" "$SRC/docs" "$SRC/rules" "$P/"
rm -f "$P/scripts/_build-pkg.sh" "$P/scripts/_test-harness.sh" "$P/scripts/_seed-demo.js"
cp "$SRC/README.md" "$SRC/CHANGELOG.md" "$SRC/CONTRIBUTING.md" "$SRC/LICENSE" "$SRC/.gitignore" "$SRC/orchestration.example.json" "$P/"

# ledger skeleton: discipline docs + empty dirs, no live data
mkdir -p "$P/ledger/messages" "$P/ledger/heartbeats" "$P/hooks/on-start.d"
cp "$SRC/ledger/README.md" "$P/ledger/README.md"
# TEMPLATE with generic axes pre-filled (init re-renders it per workspace)
sed -e 's#{{AXES_BULLETS}}#- endpoints: <clean | overlap>\n- schemas/DTOs: <clean | overlap>\n- permissions: <clean | overlap>\n- migrations: <clean | overlap>\n#' \
    -e 's#{{CONTRACT_ROOT}}#Docs/frontend#g' \
    "$SRC/templates/ledger-TEMPLATE.md" > "$P/ledger/TEMPLATE.md"
printf '{\n  "backend": null,\n  "admin-front": null,\n  "customer-front": null\n}\n' > "$P/ledger/sessions.json"
printf '{}\n' > "$P/ledger/tasks.json"
touch "$P/ledger/messages/.gitkeep" "$P/ledger/heartbeats/.gitkeep" "$P/hooks/on-start.d/.gitkeep"

# generic example config (the live one stays private)
cat > "$P/orchestration.example.json" <<'EOF'
{
  "project": "MyProduct",
  "roles": {
    "backend": "C:/Projects/my-product-api",
    "admin-front": "C:/Projects/my-product-admin",
    "customer-front": "C:/Projects/my-product-app"
  },
  "overlap_axes": ["endpoints", "schemas/DTOs", "permissions", "migrations"],
  "contract_note_root": "Docs/frontend"
}
EOF

# safety: nothing private may ride along
echo "=== privacy scan (expect no output) ==="
grep -rn "sess_[A-Za-z0-9-]\{20,\}" "$P" || true
grep -rln "Bonnychow" "$P" || true
ls "$SRC/ledger/messages" | head -0
echo "=== package tree ==="
find "$P" -type f | sed "s|$P/||" | sort
