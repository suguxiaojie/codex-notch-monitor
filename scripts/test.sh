#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_binary="$(mktemp /tmp/codex-notch-monitor-tests.XXXXXX)"
cost_test_binary="$(mktemp /tmp/codex-notch-cost-tests.XXXXXX)"
catalog_test_binary="$(mktemp /tmp/codex-notch-catalog-tests.XXXXXX)"
trap 'rm -f "$test_binary" "$cost_test_binary" "$catalog_test_binary"' EXIT

cd "$project_dir"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  Sources/CodexNotchMonitor/CoverAILinks.swift \
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
