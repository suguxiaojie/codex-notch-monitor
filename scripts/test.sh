#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_binary="$(mktemp /tmp/codex-notch-monitor-tests.XXXXXX)"
cost_test_binary="$(mktemp /tmp/codex-notch-cost-tests.XXXXXX)"
catalog_test_binary="$(mktemp /tmp/codex-notch-catalog-tests.XXXXXX)"
tibo_test_binary="$(mktemp /tmp/codex-notch-tibo-tests.XXXXXX)"
reset_test_binary="$(mktemp /tmp/codex-notch-reset-tests.XXXXXX)"
continuity_test_binary="$(mktemp /tmp/codex-notch-continuity-tests.XXXXXX)"
trap 'rm -f "$test_binary" "$cost_test_binary" "$catalog_test_binary" "$tibo_test_binary" "$reset_test_binary" "$continuity_test_binary"' EXIT

cd "$project_dir"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/CodexNotchMonitor/CoverAILinks.swift \
  Sources/CodexNotchMonitor/CodexProjectCatalog.swift \
  Sources/CodexNotchMonitor/CodexAppServerClient.swift \
  Sources/CodexNotchMonitor/Models.swift \
  Sources/CodexNotchMonitor/QuotaService.swift \
  Sources/CodexNotchMonitor/SessionActivityService.swift \
  Tests/ModelSmokeTests.swift \
  -o "$test_binary"
"$test_binary"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/CodexNotchMonitor/PricingCatalog.swift \
  Sources/CodexNotchMonitor/ModelPricing.swift \
  Sources/CodexNotchMonitor/CodexProjectCatalog.swift \
  Sources/CodexNotchMonitor/UsageAccountContext.swift \
  Sources/CodexNotchMonitor/CostService.swift \
  Tests/CostSmokeTests.swift \
  -o "$cost_test_binary"
"$cost_test_binary"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/CodexNotchMonitor/PricingCatalog.swift \
  Sources/CodexNotchMonitor/ModelPricing.swift \
  Tests/PricingCatalogTests.swift \
  -o "$catalog_test_binary"
"$catalog_test_binary"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/CodexNotchMonitor/AppPaths.swift \
  Sources/CodexNotchMonitor/TiboFeedService.swift \
  Tests/TiboFeedTests.swift \
  -o "$tibo_test_binary"
"$tibo_test_binary"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/CodexNotchMonitor/AppPaths.swift \
  Sources/CodexNotchMonitor/Models.swift \
  Sources/CodexNotchMonitor/TiboFeedService.swift \
  Sources/CodexNotchMonitor/QuotaResetMonitor.swift \
  Tests/QuotaResetMonitorTests.swift \
  -o "$reset_test_binary"
"$reset_test_binary"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/CodexNotchMonitor/AppPaths.swift \
  Sources/CodexNotchMonitor/CodexAppServerClient.swift \
  Sources/CodexNotchMonitor/CodexProjectCatalog.swift \
  Sources/CodexNotchMonitor/CodexAccountStateWatcher.swift \
  Sources/CodexNotchMonitor/UsageAccountContext.swift \
  Sources/CodexNotchMonitor/AccountContinuity.swift \
  Sources/CodexNotchMonitor/SessionContinuityService.swift \
  Sources/CodexNotchMonitor/SessionExportService.swift \
  Sources/CodexNotchMonitor/SessionImportService.swift \
  Sources/CodexNotchMonitor/SessionRecoveryService.swift \
  Tests/ContinuityTests.swift \
  -o "$continuity_test_binary"
"$continuity_test_binary"

python3 Tests/InstallHooksTests.py
