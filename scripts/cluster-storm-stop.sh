#!/bin/bash
# ========================================
# 停止 Storm 集群 - 在 Node 1 执行
# ========================================

echo "=== 停止 Storm 集群 ==="

# 在所有节点上杀死 Storm 进程
echo "停止 Node 1 上的 Storm 进程..."
ps -ef | grep storm | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null

echo "停止 Node 2 上的 Storm 进程..."
ssh node2 "ps -ef | grep storm | grep -v grep | awk '{print \$2}' | xargs kill -9" 2>/dev/null

echo "停止 Node 3 上的 Storm 进程..."
ssh node3 "ps -ef | grep storm | grep -v grep | awk '{print \$2}' | xargs kill -9" 2>/dev/null

echo ""
echo "✓ Storm 集群已停止"
