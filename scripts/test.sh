#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/build/tests"
mkdir -p "$TEST_BUILD_DIR" "$PROJECT_DIR/build/module-cache"

for TEST_SOURCE in "$PROJECT_DIR"/Tests/*Tests.swift "$PROJECT_DIR"/Prototypes/RadialPreview/*Tests.swift; do
  TEST_NAME="$(basename "$TEST_SOURCE" .swift)"
  TEST_SOURCES=()
  case "$TEST_NAME" in
    PressureCoreTests)
      TEST_SOURCES+=("$PROJECT_DIR/Sources/PressureCore.swift")
      ;;
    PressMenuGateTests)
      TEST_SOURCES+=("$PROJECT_DIR/Sources/PressMenuGate.swift")
      ;;
    PressureInputManagerTests)
      TEST_SOURCES+=("$PROJECT_DIR/Sources/PressureEventBuffer.swift")
      ;;
    ActionProviderTests)
      TEST_SOURCES+=("$PROJECT_DIR/Sources/ActionConfiguration.swift" "$PROJECT_DIR/Sources/ActionContext.swift" "$PROJECT_DIR/Sources/ActionProvider.swift")
      ;;
    ContextResolverTests)
      TEST_SOURCES+=("$PROJECT_DIR/Sources/ActionConfiguration.swift" "$PROJECT_DIR/Sources/ActionContext.swift" "$PROJECT_DIR/Sources/SelectionContextProvider.swift" "$PROJECT_DIR/Sources/ContextResolver.swift")
      ;;
    ActionConfigurationTests|ConfigurationMigrationTests)
      TEST_SOURCES+=("$PROJECT_DIR/Sources/ActionConfiguration.swift" "$PROJECT_DIR/Sources/ActionContext.swift")
      ;;
    ActionExecutorInputTests)
      TEST_SOURCES+=("$PROJECT_DIR/Sources/ActionConfiguration.swift" "$PROJECT_DIR/Sources/ActionContext.swift" "$PROJECT_DIR/Sources/ActionInputPayload.swift")
      ;;
    ActionExecutorProcessTests)
      TEST_SOURCES+=("$PROJECT_DIR/Sources/ActionConfiguration.swift" "$PROJECT_DIR/Sources/ActionContext.swift" "$PROJECT_DIR/Sources/ActionInputPayload.swift" "$PROJECT_DIR/Sources/ActionExecutor.swift")
      ;;
    RadialSelectionTests)
      TEST_SOURCES+=("$PROJECT_DIR/Prototypes/RadialPreview/RadialSelection.swift")
      ;;
    PressureFeedbackTests)
      TEST_SOURCES+=("$PROJECT_DIR/Prototypes/RadialPreview/PressureFeedback.swift")
      ;;
    *)
      printf 'Add source dependencies for %s in scripts/test.sh\n' "$TEST_NAME" >&2
      exit 2
      ;;
  esac
  xcrun swiftc \
    -target "$(uname -m)-apple-macosx14.0" -swift-version 5 \
    -module-cache-path "$PROJECT_DIR/build/module-cache" \
    "${TEST_SOURCES[@]}" "$TEST_SOURCE" \
    -o "$TEST_BUILD_DIR/$TEST_NAME"
  "$TEST_BUILD_DIR/$TEST_NAME"
done
