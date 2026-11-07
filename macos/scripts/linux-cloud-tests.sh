#!/usr/bin/env bash
# Сборка и тесты облачной части (LeadCloud + ядро LeadGenCore) на Linux, без интерфейса и
# без модуля поиска (ему нужен CryptoKit). Запускается в контейнере swift:6.1 — в CI и локально.
# Нужен пакет libsqlcipher-dev: локальная база шифруется SQLCipher.
# Если заданы LG_STACK_URL и LG_STACK_ANON, дополнительно идут сквозные тесты на локальном
# стенде Supabase (supabase/tests/stack/up.sh).
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${LG_LINUX_BUILD:-/tmp/lg-linux-pkg}"
mkdir -p "$WORK/Sources" "$WORK/Tests"
rm -rf "$WORK/Sources/"* "$WORK/Tests/"*
cp -R "$SRC/Sources/LeadCloud" "$SRC/Sources/LeadGenCore" "$SRC/Sources/CSQLite" "$WORK/Sources/"
cp -R "$SRC/Tests/LeadCloudTests" "$SRC/Tests/LeadStoreEncryptionTests" "$WORK/Tests/"
cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "LeadCloudLinux",
    targets: [
        .target(name: "LeadCloud"),
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "LeadGenCore", dependencies: ["LeadCloud", "CSQLite"]),
        .testTarget(name: "LeadCloudTests", dependencies: ["LeadCloud", "LeadGenCore"]),
        .testTarget(name: "LeadStoreEncryptionTests", dependencies: ["LeadGenCore"]),
    ]
)
SWIFT
cd "$WORK"
swift test --build-path "$WORK/.build" "$@"
