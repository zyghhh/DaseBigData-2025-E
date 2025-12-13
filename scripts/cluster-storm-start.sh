#!/bin/bash
# ========================================
# 启动 Storm 集群 - 在 Node 1 执行
# ========================================

echo "=== 启动 Storm 集群 ==="

# 1. 在 Node 1 启动 Nimbus 和 UI
echo "[1/2] 启动 Nimbus 和 UI（Node 1）..."
nohup /opt/storm/bin/storm nimbus > /opt/storm/logs/nimbus.out 2>&1 &
nohup /opt/storm/bin/storm ui > /opt/storm/logs/ui.out 2>&1 &
echo "✓ Nimbus 和 UI 已启动"

# 2. 在 Node 2 和 Node 3 启动 Supervisor
echo "[2/2] 启动 Supervisor（Node 2 & Node 3）..."
ssh node2 "nohup /opt/storm/bin/storm supervisor > /opt/storm/logs/supervisor.out 2>&1 &"
ssh node3 "nohup /opt/storm/bin/storm supervisor > /opt/storm/logs/supervisor.out 2>&1 &"
echo "✓ Supervisor 已启动"

sleep 3

echo ""
echo "=== Storm 集群已启动 ==="
echo ""
echo "验证状态："
echo "  - Node 1: jps | grep -E 'Nimbus|core'"
echo "  - Node 2/3: jps | grep Supervisor"
echo "  - Web UI: http://node1:8080"
echo "  - 检查 Supervisors: 应为 2"
