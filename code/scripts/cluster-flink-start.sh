#!/bin/bash
# ========================================
# 启动 Flink 集群 - 在 Node 1 执行
# ========================================

echo "=== 启动 Flink 集群 ==="

/opt/flink/bin/start-cluster.sh

echo ""
echo "✓ Flink 集群已启动"
echo ""
echo "验证状态："
echo "  - Node 1: jps | grep StandaloneSessionClusterEntrypoint"
echo "  - Node 2/3: jps | grep TaskManagerRunner"
echo "  - Web UI: http://59.110.8.176:8081"
echo "  - 检查 Total Task Slots: 应为 4"
