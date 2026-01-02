#!/bin/bash
# ========================================
# 停止 Flink 集群 - 在 Node 1 执行
# ========================================

echo "=== 停止 Flink 集群 ==="

/opt/flink/bin/stop-cluster.sh

echo ""
echo "✓ Flink 集群已停止"
